// ---------------------------------------------------------------
//  powershell.exe 转发器（shim）
//
//  由 Install.ps1 用 Add-Type 编译成 powershell.exe，装到
//  C:\Program Files\AppxInstaller\bin 并置于机器 PATH 最前。
//
//  目的：本套件把 WindowsPowerShell\v1.0 从 PATH 移除后，任何
//  直接 CreateProcess("powershell", ...) 的调用方（Node 的
//  execFile/spawn、Go 的 exec.Command、计划任务、服务等）都会
//  拿到 ENOENT —— 哪怕 cmd.exe 里手敲 powershell 也不行，因为
//  System32 下并没有 powershell.exe。这个转发器让 powershell
//  这个名字重新可用，并指向 PowerShell 7。
//
//  保真度：命令行原样透传（不做重新拼接，避免引号被改写），
//  退出码、stdout、stderr、stdin 全部继承。
// ---------------------------------------------------------------

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;

internal static class PwshShim
{
    private const int ExitNotFound = 9009;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr GetCommandLineW();

    private static int Main()
    {
        string tail = StripProgramName(Marshal.PtrToStringUni(GetCommandLineW()));

        bool debug = IsTruthy(Environment.GetEnvironmentVariable("PWSH_SHIM_DEBUG"));
        bool forceLegacy = IsTruthy(Environment.GetEnvironmentVariable("PWSH_SHIM_LEGACY"));

        string target = null;

        if (forceLegacy || RequestsLegacy(tail))
        {
            // 调用方明确要 5.1（-Version 2.0/5.1 或环境变量）。
            // 此时不能交给 pwsh：pwsh 会打印版本号然后 exit 0，
            // 根本不执行命令 —— 这是最容易被忽略的静默错误。
            target = LegacyPowerShell();
            if (target == null)
            {
                Console.Error.WriteLine("powershell shim: Windows PowerShell 5.1 not found at " + LegacyPowerShellPath());
                return ExitNotFound;
            }
        }
        else
        {
            target = ResolvePwsh() ?? LegacyPowerShell();
            if (target == null)
            {
                Console.Error.WriteLine("powershell shim: neither pwsh.exe nor Windows PowerShell 5.1 could be found.");
                return ExitNotFound;
            }
        }

        if (debug)
        {
            Console.Error.WriteLine("powershell shim: -> " + target);
        }

        var psi = new ProcessStartInfo
        {
            FileName = target,
            Arguments = tail,
            UseShellExecute = false,
        };

        try
        {
            using (Process p = Process.Start(psi))
            {
                if (p == null)
                {
                    Console.Error.WriteLine("powershell shim: failed to start " + target);
                    return ExitNotFound;
                }
                p.WaitForExit();
                return p.ExitCode;
            }
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("powershell shim: " + ex.Message);
            return ExitNotFound;
        }
    }

    // 取原始命令行，剥掉 argv[0]，其余一个字符都不动。
    // 自己重新拼参数是引号事故的常见来源，这里刻意避免。
    private static string StripProgramName(string raw)
    {
        if (string.IsNullOrEmpty(raw)) return string.Empty;

        int i = 0;
        if (raw[0] == '"')
        {
            i = raw.IndexOf('"', 1);
            if (i < 0) return string.Empty;
            i++;
        }
        else
        {
            i = raw.IndexOf(' ');
            if (i < 0) return string.Empty;
        }

        while (i < raw.Length && raw[i] == ' ') i++;
        return raw.Substring(i);
    }

    private static bool RequestsLegacy(string tail)
    {
        if (string.IsNullOrEmpty(tail)) return false;

        // 匹配 -Version 5.1 / -Version:5.1 / -version "2.0"
        Match m = Regex.Match(tail, @"(?i)(?:^|\s)-version(?::|\s+)\s*""?([^\s""]+)");
        if (!m.Success) return false;

        string value = m.Groups[1].Value.Trim('"');
        // 5.1 的 -Version 只接受 2.0 与 5.1；其余（如 7）交给 pwsh 自己判断。
        return value.StartsWith("2", StringComparison.Ordinal)
            || value.StartsWith("5", StringComparison.Ordinal);
    }

    private static string ResolvePwsh()
    {
        string self = SafeAssemblyPath();

        // 1) 管理员显式指定
        string overridePath = Environment.GetEnvironmentVariable("PWSH_SHIM_TARGET");
        if (IsUsableExe(overridePath, self)) return overridePath;

        // 2) 当前用户的执行别名（标准用户最常用的一条）
        string alias = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Microsoft", "WindowsApps", "pwsh.exe");
        if (IsUsableExe(alias, self)) return alias;

        // 3) PATH 里找 pwsh.exe（MSI 安装、自定义安装都能命中）
        string pathVar = Environment.GetEnvironmentVariable("PATH");
        if (!string.IsNullOrEmpty(pathVar))
        {
            foreach (string dir in pathVar.Split(';'))
            {
                if (string.IsNullOrWhiteSpace(dir)) continue;
                string candidate = null;
                try
                {
                    candidate = Path.Combine(Path.GetFullPath(dir.Trim().Trim('"')), "pwsh.exe");
                }
                catch { continue; }
                if (IsUsableExe(candidate, self)) return candidate;
            }
        }

        // 4) MSI 默认位置
        foreach (string root in ProgramFilesRoots())
        {
            string msi = Path.Combine(root, "PowerShell", "7", "pwsh.exe");
            if (IsUsableExe(msi, self)) return msi;
        }

        // 5) MSIX 包目录兜底：服务/SYSTEM 上下文里没有 per-user 别名，
        //    这一条是它们唯一能命中的路径。目录枚举对标准用户可能被拒，
        //    失败就安静跳过，交给 5.1 兜底。
        return ResolveFromPackageDirectory(self);
    }

    private static string ResolveFromPackageDirectory(string self)
    {
        foreach (string root in ProgramFilesRoots())
        {
            string apps = Path.Combine(root, "WindowsApps");
            string[] dirs;
            try
            {
                if (!Directory.Exists(apps)) continue;
                dirs = Directory.GetDirectories(apps, "Microsoft.PowerShell_*_x64__8wekyb3d8bbwe");
            }
            catch { continue; }

            string best = null;
            Version bestVersion = new Version(0, 0);

            foreach (string dir in dirs)
            {
                string exe = Path.Combine(dir, "pwsh.exe");
                if (!IsUsableExe(exe, self)) continue;

                Version v = ParsePackageVersion(Path.GetFileName(dir));
                if (best == null || v > bestVersion)
                {
                    best = exe;
                    bestVersion = v;
                }
            }

            if (best != null) return best;
        }
        return null;
    }

    // Microsoft.PowerShell_7.6.7.0_x64__8wekyb3d8bbwe -> 7.6.7.0
    private static Version ParsePackageVersion(string dirName)
    {
        Match m = Regex.Match(dirName ?? string.Empty, @"^Microsoft\.PowerShell_(\d+(?:\.\d+)*)_");
        if (!m.Success) return new Version(0, 0);

        string[] parts = m.Groups[1].Value.Split('.');
        while (parts.Length < 2)
        {
            Array.Resize(ref parts, parts.Length + 1);
            parts[parts.Length - 1] = "0";
        }
        if (parts.Length > 4) Array.Resize(ref parts, 4);

        Version parsed;
        return Version.TryParse(string.Join(".", parts), out parsed) ? parsed : new Version(0, 0);
    }

    private static IEnumerable<string> ProgramFilesRoots()
    {
        // 32 位进程下 SpecialFolder.ProgramFiles 会被 WOW64 重定向到
        // Program Files (x86)，所以先取 64 位变量。
        string native = Environment.GetEnvironmentVariable("ProgramW6432");
        if (!string.IsNullOrEmpty(native)) yield return native;

        string fallback = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        if (!string.IsNullOrEmpty(fallback) && !string.Equals(fallback, native, StringComparison.OrdinalIgnoreCase))
            yield return fallback;
    }

    private static bool IsUsableExe(string path, string self)
    {
        if (string.IsNullOrWhiteSpace(path)) return false;
        try
        {
            if (!File.Exists(path)) return false;
            // 绝不解析回自己，否则无限递归。
            if (!string.IsNullOrEmpty(self) &&
                string.Equals(Path.GetFullPath(path), self, StringComparison.OrdinalIgnoreCase))
                return false;
        }
        catch { return false; }
        return true;
    }

    private static string SafeAssemblyPath()
    {
        try { return Path.GetFullPath(typeof(PwshShim).Assembly.Location); }
        catch { return null; }
    }

    private static string LegacyPowerShellPath()
    {
        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.Windows),
            "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
    }

    private static string LegacyPowerShell()
    {
        string p = LegacyPowerShellPath();
        return File.Exists(p) ? p : null;
    }

    private static bool IsTruthy(string value)
    {
        if (string.IsNullOrWhiteSpace(value)) return false;
        string v = value.Trim();
        return v == "1"
            || v.Equals("true", StringComparison.OrdinalIgnoreCase)
            || v.Equals("yes", StringComparison.OrdinalIgnoreCase)
            || v.Equals("on", StringComparison.OrdinalIgnoreCase);
    }
}
