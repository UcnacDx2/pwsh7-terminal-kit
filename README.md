---
AIGC:
  ContentProducer: '001191110102MAD55U9H0F10002'
  ContentPropagator: '001191110102MAD55U9H0F10002'
  Label: '1'
  ProduceID: '8db0d87d-f491-44fc-8b05-2de9c91e0d0f'
  PropagateID: '8db0d87d-f491-44fc-8b05-2de9c91e0d0f'
  ReservedCode1: '42003dcc-7383-41c4-a74e-f39f84f993e3'
  ReservedCode2: '42003dcc-7383-41c4-a74e-f39f84f993e3'
---

# PowerShell 7 + Windows Terminal 一键配置

把 Windows 的默认终端换成 **Windows Terminal**，把用户日常能点到的 "Windows PowerShell" 入口换成 **PowerShell 7**，并附带一键卸载。

系统自带的 `powershell.exe` 文件（System32 / SysWOW64）**不做任何改动**——只替换用户真正会接触到的入口。同时 `powershell` 这个名字交给一个自带的转发器接管，仍然可用，只是实际执行的是 PowerShell 7（见 [powershell.exe 转发器](#powershellexe-转发器)）。

---

## 安装后会发生什么

| 项目 | 安装前 | 安装后 |
| --- | --- | --- |
| 默认终端 | 控制台主机（conhost） | Windows Terminal |
| 开始菜单 "Windows PowerShell" | powershell.exe（5.1） | pwsh.exe（PowerShell 7） |
| 开始菜单 "Windows PowerShell (x86)" | SysWOW64 的 5.1 | pwsh.exe（PowerShell 7） |
| Shift + 右键 "在此处打开 PowerShell 窗口" | 显示 | 隐藏 |
| PATH 中的 `WindowsPowerShell\v1.0` | 存在 | 移除 |
| `powershell` 这个名字解析到 | 系统自带的 5.1 | 本套件的转发器 → pwsh 7 |
| 双击 `.msix` / `.appx` / `.msixbundle` / `.appxbundle` | 系统默认处理 | 用本套件的 `Install-Appx.ps1` 安装 |

安装的 MSIX 应用：

- **PowerShell 7.6.7**（`Microsoft.PowerShell_8wekyb3d8bbwe`）
- **Windows Terminal 1.25.2733.0**（`Microsoft.WindowsTerminal_8wekyb3d8bbwe`）

两者都会 `Add-AppxProvisionedPackage` 预配给所有用户，新用户首次登录即可使用。

---

## 快速开始

1. 下载本仓库（`Code` → `Download ZIP`，或 `git clone`）。
2. （可选，推荐）把两个安装包放进脚本同一目录：
   - `PowerShell-*.msixbundle`（PowerShell 7）
   - `Microsoft.WindowsTerminal_*.msixbundle` / `.msix`，或 OEM 预安装包
     `Microsoft.WindowsTerminal_*PreinstallKit.zip`（自动解压、自动装依赖）
3. 双击 **`Install.cmd`**。
4. 在 UAC 对话框点“是”，按提示等待完成。

安装脚本会优先使用脚本目录里已有的本地包（免联网）；本地没有才从镜像下载，并校验 Authenticode 签名（签名者必须是 Microsoft）。OEM 预安装包（`*PreinstallKit.zip`）会自动解压出主包，并先安装包内附带的 UI.Xaml / VCLibs 依赖框架，避免依赖缺失报错。

**下载源**（按顺序尝试，前一个失败自动换下一个；`github.com` 直连在部分网络下不通，因此都走镜像）：

| 包 | 下载源 |
| --- | --- |
| PowerShell 7.6.7 | `cdn.akaere.online` → `ghfast.top` |
| Windows Terminal 1.25.2733.0 | `cdn.akaere.online` → `ghfast.top` |

下载完成后会校验文件是完整可读的包；断流产生的残缺文件会被删除并换下一个源（不会留在缓存里当成有效包）。

已经手动下载好安装包？也可以显式指定路径：

```powershell
.\Install.cmd -PowerShellPackage "D:\pkg\PowerShell-7.6.7.msixbundle" -TerminalPackage "D:\pkg\Microsoft.WindowsTerminal_1.25.2733.0_8wekyb3d8bbwe.msix"
# 或直接给 OEM 预安装包 zip：
.\Install.cmd -TerminalPackage "D:\pkg\Microsoft.WindowsTerminal_*_Windows10_PreinstallKit.zip"
```

只想看看当前状态、不做任何修改：

```powershell
.\Install.cmd -Verify
```

---

## 参数

### Install.ps1

| 参数 | 说明 |
| --- | --- |
| `-PowerShellPackage <路径>` | 使用本地 PowerShell 7 的 `.msixbundle`，不下载 |
| `-TerminalPackage <路径>` | 使用本地 Windows Terminal 的 `.msix` / `.msixbundle`，或 OEM 预安装包 `*PreinstallKit.zip`，不下载 |
| `-NoProvision` | 不为所有用户预配，只安装给当前用户 |
| `-NoAssociations` | 不注册 `.msix` / `.appx` 文件关联 |
| `-KeepWindowsPowerShellPath` | 保留 PATH 中的 `WindowsPowerShell\v1.0`（会自动跳过转发器，因为二者意图冲突） |
| `-NoPowerShellShim` | 不安装 `powershell.exe` 转发器；那样 `powershell` 这个名字会解析不出来（旧版套件的行为） |
| `-SkipSignatureCheck` | 跳过签名校验（不建议） |
| `-Verify` | 只打印当前配置状态，不做修改，不需要管理员权限 |
| `-StatePath <路径>` | 状态文件位置，默认 `C:\ProgramData\AppxInstaller\state.json` |
| `-NoPause` | 结束后不等待按键（用于自动化） |

### Uninstall.ps1

| 参数 | 说明 |
| --- | --- |
| `-KeepPackages` | 不卸载 PowerShell 7 与 Windows Terminal，只还原配置 |
| `-KeepProvisioned` | 不撤销所有用户的预配，只还原当前用户配置 |
| `-StatePath <路径>` | 指定状态文件，默认 `C:\ProgramData\AppxInstaller\state.json` |
| `-NoPause` | 结束后不等待按键 |

---

## 会修改哪些位置

每一项修改前，脚本都会把原值记录到 `C:\ProgramData\AppxInstaller\state.json`，卸载时据此精确还原。

| 项目 | 位置 | 生效范围 |
| --- | --- | --- |
| 应用安装 | MSIX 包注册 | 当前用户（管理员） |
| 应用预配 | `Add-AppxProvisionedPackage` | 所有用户、新建用户 |
| 开始菜单快捷方式 | `ProgramData\...\Windows PowerShell\`、各用户 `AppData\Roaming\...\Windows PowerShell\`、`C:\Users\Default\...` | 所有用户、新建用户 |
| 快捷方式备份 | 同目录 `*.lnk.bak` | — |
| 右键菜单隐藏 | `Software\Classes\{Directory\Background,Directory,Drive}\shell\Powershell` 的 `HideBasedOnVelocityId = 0x639BC8` | 当前用户 + 其他用户 + Default |
| 默认终端 | `Console\%%Startup` 的 `DelegationConsole` / `DelegationTerminal` | 当前用户 + 其他用户 + Default |
| 用户 PATH | `HKCU\Environment` | 当前用户 |
| 系统 PATH | `HKLM\SYSTEM\...\Environment` | 所有用户 |
| `powershell` 转发器 | `C:\Program Files\AppxInstaller\bin\powershell.exe`（安装时编译生成） | 所有用户 |
| 系统 PATH 置顶 | 上述目录被加到 `HKLM\SYSTEM\...\Environment` 最前 | 所有用户 |
| 文件关联 | `HKCU\Software\Classes`、`HKLM\SOFTWARE\Classes` | 当前用户 + 所有用户 |

其他用户与 `C:\Users\Default` 的配置通过临时加载 `NTUSER.DAT` 完成，处理完立即卸载，不会影响正在登录的会话。

### 不会修改的内容

```
C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe
C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe
```

这两个文件保持原样：写全路径依然能用到真正的 5.1。

---

## powershell.exe 转发器

**为什么需要它。** 本套件把 `WindowsPowerShell\v1.0` 从 PATH 移除后，`powershell` 这个名字就彻底解析不出来了——注意 `C:\Windows\System32` 下**并没有** `powershell.exe`，它只存在于 `System32\WindowsPowerShell\v1.0\`。于是所有直接创建进程的调用方都会拿到 ENOENT：

- Node 的 `execFileSync` / `spawn`（典型报错 `spawnSync powershell ENOENT`）
- Go 的 `exec.Command`、Rust 的 `Command`、Python 的 `subprocess`
- 计划任务、Windows 服务、各类安装程序里的 `powershell -File ...`

`cmd.exe` 也救不了：它同样按 PATH 找 `powershell.exe`。

而 `.cmd` / `.bat` 垫片对上面这些调用方**完全无效**——`CreateProcess` 不查 `PATHEXT`（只有 `cmd.exe` 自己查），文件名里没写扩展名时它们根本不会去找 `powershell.cmd`。所以必须是一个真正的 `.exe`。

**它怎么做。** `Install.ps1` 用 `Add-Type` 把 `lib/PowerShellShim.cs`（约 10 KB 的 C# 程序）编译成 `powershell.exe`，装到：

```
C:\Program Files\AppxInstaller\bin\powershell.exe
```

并把这个目录加到**系统 PATH 的最前面**。转发器本身不做任何解析：

- 从 `GetCommandLineW()` 取原始命令行，只剥掉 argv[0]，**其余一个字符都不动**——自己重新拼参数是引号事故的常见来源。stdout / stderr / stdin / 退出码全部原样继承。
- 按顺序找 pwsh 7：`PWSH_SHIM_TARGET` 环境变量 → `%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe` → PATH 里的 `pwsh.exe` → `%ProgramFiles%\PowerShell\7\pwsh.exe` → MSIX 包目录兜底（服务 / SYSTEM 上下文里没有用户别名，只有这一条能命中）。
- 一个都找不到时回退到真正的 5.1；两者都没有才以 9009 退出。

**已经在运行的进程看不到它。** PATH 是每个进程**启动时**快照下来的环境副本；改注册表再广播 `WM_SETTINGCHANGE`，只对**之后**新起的进程生效。于是：

- 从开始菜单 / 资源管理器**新开**的程序，立刻就能按名字解析到 `powershell`；
- 安装前就在跑的程序——常驻服务、GUI 宿主，以及**打开 `Install.ps1` 的那个窗口**——仍拿着旧 PATH，会继续报 `spawnSync powershell ENOENT`，直到该进程自己重启，或注销重新登录一次。

所以装完立刻在当前窗口敲 `powershell` 报找不到，是正常现象，不是没装好。第 7 步会专门把这件事测出来告诉你：

```
新进程里按名字解析：通过（powershell -> pwsh 7，Core）
提示：已经在运行的进程仍持有旧的 PATH 快照（包括打开本脚本的这个窗口），
      要等重启该程序、或注销重新登录一次，它才能看到这个名字。
```

注意这个检查与 `Test-PowerShellShim` 不是一回事：后者是拿**完整路径**调转发器的，当前进程的名字解析坏掉时它照样报通过。

**为什么编译而不是做快捷方式。** 指向 MSIX 包内 `pwsh.exe` 的符号链接 / 硬链接 / 联接会被包目录 ACL 拒绝（EPERM / EACCES）；只复制 `pwsh.exe` 又会缺 `pwsh.dll` 和运行时。编译一个几 KB 的转发器是唯一干净的做法。

**为什么放在 `Program Files`。** `C:\ProgramData\AppxInstaller` 给 `BUILTIN\Users` 的是可写权限，把 PATH 最前的可执行文件放那儿等于给任何普通用户留了一个替换点。`Program Files` 只给 Users `ReadAndExecute`，这才是正确的位置。

**`-Version 5.1` 会被拦下来。** 传 `-Version 5.1`（或 `2.0`）的调用方要的是 Windows PowerShell，转发器交回的是真正的 5.1，**不是** pwsh 7——因为 pwsh 收到 `-Version` 只会打印一行版本号然后 `exit 0`，命令根本不执行。这是最容易被忽略的静默失败：调用方以为跑过了，其实什么都没发生。

> `-Version` 只有放在**第一个参数位置**才被 `powershell.exe` 识别（用法行 `[-PSConsoleFile <file> | -Version <version>]` 就在最前）。放在后面会被折进命令文本，5.1 自己也会报错；转发器在这种情况下保持原样，与直接调用 5.1 的行为逐字节一致。

**三个逃逸口。**

| 环境变量 | 作用 |
| --- | --- |
| `PWSH_SHIM_TARGET=<路径>` | 指定转发到哪个可执行文件，优先于所有自动探测 |
| `PWSH_SHIM_LEGACY=1` | 不走 pwsh，直接转给 Windows PowerShell 5.1 |
| `PWSH_SHIM_DEBUG=1` | 把最终选中的目标打印到 stderr |

**不想要它？** 安装时加 `-NoPowerShellShim`（`powershell` 这个名字会像旧版套件一样解析不出来），或者用 `-KeepWindowsPowerShellPath` 保留 `WindowsPowerShell\v1.0`（此时转发器自动跳过，`powershell` 仍指向 5.1）。

**想自己验证。** 管理员身份运行 `.\Test-Shim.ps1`：它会临时装一次转发器、做完整对照、再自动卸掉并把 PATH 还原，中途出错或 Ctrl-C 也会在 `finally` 里回滚。已经装过转发器的机器要先 `Uninstall.ps1` 再跑（脚本会拒绝覆盖真实安装）。

**卸载。** `Uninstall.ps1` 会先把该目录从系统 PATH 摘掉、再删除目录，然后才把 `WindowsPowerShell\v1.0` 加回 PATH——顺序不能反。PATH 逐字节还原到安装前的值。

---

## 卸载

双击 **`Uninstall.cmd`**，UAC 点"是"。

- 有状态文件时：逐项还原安装前的原始值（包括原来的 PATH、原来的快捷方式、原来的右键菜单与默认终端）。
- 没有状态文件时：只清理"当前值等于本套件写入值"的项，做到尽力而为。
- **安装前就存在的应用不会被卸载**：脚本记录了安装前的版本，如果检测到之前已有 PowerShell 7 / Windows Terminal，只还原配置并保留应用（避免把用户原有的东西删掉）。

卸载后重新打开终端即可生效；已经打开着的窗口不受影响。

---

## 文件关联：Install-Appx.ps1

套件自带一个包安装器，`Install.ps1` 会把它复制到 `C:\ProgramData\AppxInstaller\Install-Appx.ps1` 并注册关联。

- 双击任意 `.msix` / `.msixbundle` / `.appx` / `.appxbundle` / `.appinstaller`
- 资源管理器给它分配一个终端窗口（本套件把默认终端设成了 Windows Terminal），标题是 `Appx / MSIX 安装程序`
- 窗口里打印包名、版本、发布者、架构、大小，输入 `Y` 确认
- 确认后调用 `Add-AppxPackage` 安装；过程和结果都在同一个窗口里，读完按回车关闭

> **为什么是终端而不是弹窗。** 双击拉起的本来就是控制台程序，窗口一直都在，信息塞进 MessageBox 只会把它空着。脚本用 `GetConsoleWindow()` 判断有没有控制台——**不能用 `[Console]::IsOutputRedirected`**，输出重定向到文件时它也是 `true`，`Install-Appx.ps1 pkg.msix > log.txt` 会被误判成没控制台而弹窗。确实没有控制台时（极端宿主）仍退回弹窗，否则会卡在 `Read-Host` 上等人按键而根本没人能按。

单独使用（不装整套配置）时：

```powershell
.\Install-Appx.ps1 -Register          # 注册当前用户的关联
.\Install-Appx.ps1 -Register -AllUsers # 管理员身份下另行注册所有用户
```

> Windows 不允许程序静默改写"默认应用"（`UserChoice` 带系统校验哈希，且算法随版本变化）。
> 本套件只注册 ProgId 与扩展名的默认处理程序；在没有 `UserChoice` 的情况下，资源管理器会使用这份注册，双击 `.msix` 依然由 `Install-Appx.ps1` 接手。
> 如果某个扩展名之前被你手动指定过其他程序，需要在"打开方式 → 选择其他应用"里选一次"始终使用"。若系统后来重置了关联，重新运行 `-Register` 即可。

---

## 系统要求

- Windows 10 21H2（build 19044）及以上，或 Windows 11（19044 已实测可用）
- 管理员权限（安装与卸载）
- 系统自带的 Windows PowerShell 5.1
- 首次安装需要能访问镜像站（见上文"下载源"），或手动提供 MSIX 包

### 已验证环境

- Windows 10 IoT Enterprise LTSC 2021（10.0.19044）
- Windows Server 2022（10.0.20348），x64
- PowerShell 7.6.7（MSIX，x64）
- Windows Terminal 1.25.2733.0
- 安装、状态检查、卸载回滚（临时状态文件）均已实际跑通
- `powershell` 转发器用「差分对照」验证：把同一份原始命令行分别喂给转发器和它应该转发到的真实 exe，比较 stdout / stderr / 退出码；覆盖退出码透传、stdin 管道、`-File` 带空格路径、命令里的 `&` `^` `%`、`-Version 5.1` 拦截等

---

## 注意事项

**PowerShell 7 是 MSIX 版，没有 `C:\Program Files\PowerShell\7`。**
这是刻意的：MSIX 包可以预配给所有用户，并随系统更新。终端配置、快捷方式都指向：

```
%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe
```

**移除 PATH 中的 `WindowsPowerShell\v1.0` 后，`powershell` 这个名字由转发器接管。**
所以 `powershell -Command ...`、`execFileSync("powershell", ...)`、`exec.Command("powershell", ...)` 这些调用照常可用，只是实际跑的是 PowerShell 7。想要真正的 5.1 见 [powershell.exe 转发器](#powershellexe-转发器) 一节；想彻底不要转发器，用 `-NoPowerShellShim`。

**默认终端在 Windows 10 上是"转交给 Windows Terminal 打开"。**
如果 Terminal 进程未运行，系统会先启动它；刚装完的第一个控制台可能仍由 conhost 打开，之后再打开就稳定了。Windows Terminal 设置里的"默认终端应用程序"会显示为 Windows Terminal。

**公司/域环境可能拦截。**
`Add-AppxProvisionedPackage` 需要 `AppXSvc`、`ClipSVC`、`StateRepository` 正常；组策略可能禁止预配或脚本执行。被拦截时脚本会给出具体错误并保存进度，修正后重跑即可（已完成的步骤不会重复备份）。

**安装后会自动检查 `pwsh.exe` / `wt.exe` 执行别名。**
为所有用户预配（`Add-AppxProvisionedPackage`）会把当前用户的应用状态打回“已暂存”，
在一些机器上导致执行别名报“找不到可用的应用程序证书”而无法启动。
脚本安装完会实测别名，坏了就通过重注册包与触发一次应用激活来自动修复。

**之前装过 MSI 版 PowerShell 7 的话**，两者会并存（不同的安装位置和 AppID）。建议先卸载 MSI 版，避免开始菜单里出现两个 PowerShell。

**首次运行前建议先 `-Verify`**，确认脚本判断的状态符合你的预期。

**为什么脚本坚持用 Windows PowerShell 5.1 执行？**

本套件的安装、检查和卸载都依赖 `Appx` 模块。该模块的清单虽然声明 `CompatiblePSEditions = @('Desktop','Core')`，但它实际加载的 `ModuleToProcess` 是 GAC 中的 .NET Framework 程序集 `Microsoft.Windows.Appx.PackageManager.Commands`。在 PowerShell 7（.NET Core 运行时）下导入时，PowerShell 反射程序集导出类型就会抛出：

```
System.PlatformNotSupportedException (0x80131539)
   at System.Reflection.RuntimeAssembly.GetExportedTypes()
   at System.Management.Automation.Runspaces.PSSnapInHelpers.GetAssemblyTypes(...)
```

`Import-Module Appx -SkipEditionCheck` 同样失败；`-UseWindowsPowerShell` 可以绕过，但拿到的是反序列化对象，行为和错误信息都会走样。因此 `Install.cmd` / `Uninstall.cmd` 直接调用 5.1，直接用 pwsh 7 运行 `.ps1` 时脚本也会自动切换到 5.1 并提示。新版本 Windows 上的 Appx 模块可能已经能在 Core 下工作，但脚本不依赖这一点。

**在已经手工配置过的机器上安装时**，状态文件记录的是"运行 Install.ps1 那一刻"的值，而不是出厂值。想验证完整回滚，建议在干净的虚拟机或新用户配置里测试。

---

## 目录结构

```
pwsh7-terminal-kit/
├─ Install.cmd            双击安装入口
├─ Install.ps1            安装逻辑（支持参数、自动提权）
├─ Uninstall.cmd          双击卸载入口
├─ Uninstall.ps1          回滚逻辑（按状态文件精确还原）
├─ Install-Appx.ps1       .msix/.appx 安装器 + 文件关联
├─ Test-Shim.ps1          转发器自检（临时安装→差分对照→自动回滚）
├─ lib/
│  ├─ Common.ps1          公共函数（提权、注册表、配置单元、快捷方式、状态、转发器）
│  └─ PowerShellShim.cs   powershell.exe 转发器源码（安装时由 Add-Type 编译）
├─ README.md
└─ LICENSE
```

---

## 许可

MIT

> AI生成