<#
.SYNOPSIS
    安装 .msix / .msixbundle / .appx / .appxbundle / .appinstaller 包，并可将这些扩展名关联到本脚本。

.DESCRIPTION
    双击包文件时由关联调用：读取清单 -> 在终端窗口里确认 -> Add-AppxPackage 安装。
    有控制台窗口时全部走终端文本（资源管理器双击时会分配一个），只有确实没有
    控制台时才退回弹窗。
    使用 -Register 参数注册文件关联（当前用户；管理员身份下同时注册给所有用户）。

.PARAMETER PackagePath
    要安装的包文件路径。由资源管理器关联调用时自动传入 %1。

.PARAMETER Register
    注册/修复文件关联，不安装任何包。

.PARAMETER AllUsers
    以管理员身份运行时，改为为所有用户预配（Add-AppxProvisionedPackage）。

.EXAMPLE
    Install-Appx.ps1 -Register
    Install-Appx.ps1 -Register -AllUsers
    Install-Appx.ps1 "D:\pkg\app.msixbundle"
#>
param(
    [Parameter(Position = 0)]
    [string]$PackagePath,

    [switch]$Register,

    [switch]$AllUsers
)

$ErrorActionPreference = 'Stop'

$ScriptPath = $PSCommandPath
if (-not $ScriptPath) { $ScriptPath = 'C:\ProgramData\AppxInstaller\Install-Appx.ps1' }
$Extensions = @('.msix', '.msixbundle', '.appx', '.appxbundle', '.appinstaller')
$ProgId = 'AppxInstaller.Package'
$ProgIdFriendly = 'Appx / MSIX 安装程序'

function Test-Admin {
    try {
        return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Test-ConsoleWindow {
    <#
      当前进程挂着一个控制台窗口吗？——决定用终端文本还是弹窗。

      为什么不用 [Console]::IsOutputRedirected：输出重定向到文件时它也是
      true，于是 `Install-Appx.ps1 pkg.msix > log.txt` 反而会弹窗，正好反过来。
      GetConsoleWindow() 只看有没有控制台，与重定向无关。

      双击文件时资源管理器会给控制台程序分配一个窗口，这里返回 true；
      万一被某种没有控制台的宿主拉起，就退回弹窗 —— 否则脚本会卡在
      Read-Host 上等人按键，而根本没人能按。
    #>
    if ($null -ne $script:HasConsoleWindow) { return $script:HasConsoleWindow }

    $script:HasConsoleWindow = $false
    try {
        if (-not ('Kit.ConsoleWindow' -as [type])) {
            Add-Type -Namespace Kit -Name ConsoleWindow -ErrorAction Stop -MemberDefinition @'
[DllImport("kernel32.dll")] private static extern IntPtr GetConsoleWindow();
public static bool Exists() { return GetConsoleWindow() != IntPtr.Zero; }
'@
        }
        $script:HasConsoleWindow = [Kit.ConsoleWindow]::Exists()
    } catch { }
    return $script:HasConsoleWindow
}

function Show-Message {
    param([string]$Text, [string]$Title = 'Appx 安装程序', [string]$Kind = 'Info')

    if (Test-ConsoleWindow) {
        $color = switch ($Kind) {
            'Error' { 'Red' }
            'Warning' { 'Yellow' }
            default { 'Gray' }
        }
        Write-Host ''
        Write-Host $Text -ForegroundColor $color
        [void](Read-Host '按 Enter 退出')
        return
    }

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $icon = switch ($Kind) {
            'Error' { [System.Windows.Forms.MessageBoxIcon]::Error }
            'Warning' { [System.Windows.Forms.MessageBoxIcon]::Warning }
            default { [System.Windows.Forms.MessageBoxIcon]::Information }
        }
        [void][System.Windows.Forms.MessageBox]::Show($Text, $Title, [System.Windows.Forms.MessageBoxButtons]::OK, $icon)
    } catch {
        Write-Host $Text
        Read-Host '按 Enter 继续'
    }
}

function Show-Confirm {
    param([string]$Text, [string]$Title = '确认安装')

    if (Test-ConsoleWindow) {
        Write-Host ''
        Write-Host $Text
        return ((Read-Host '是否安装？输入 Y 安装，直接回车取消') -match '^(?i)y$')
    }

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $r = [System.Windows.Forms.MessageBox]::Show(
            $Text, $Title,
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question,
            [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
        return ($r -eq [System.Windows.Forms.DialogResult]::Yes)
    } catch {
        Write-Host $Text
        return ((Read-Host '是否安装？输入 Y 安装，其他取消') -match '^(?i)y$')
    }
}

function Get-PackageInfo {
    param([System.IO.FileInfo]$File)

    $info = [ordered]@{
        Name        = $File.Name
        DisplayName = '未知'
        Version     = '未知'
        Publisher   = '未知'
        Architecture = '未知'
        SizeMB      = [math]::Round($File.Length / 1MB, 2)
        FullName    = $File.FullName
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $zip = [System.IO.Compression.ZipFile]::OpenRead($File.FullName)
    try {
        $entry = $zip.GetEntry('AppxManifest.xml')
        if (-not $entry) {
            $entry = $zip.Entries |
                Where-Object { $_.FullName -match '(?i)(^|/)AppxBundleManifest\.xml$' } |
                Select-Object -First 1
        }
        if ($entry) {
            $reader = New-Object System.IO.StreamReader($entry.Open())
            try { $xml = [xml]$reader.ReadToEnd() } finally { $reader.Dispose() }

            $identity = $xml.SelectSingleNode("//*[local-name()='Identity']")
            if ($identity) {
                if ($identity.Name) { $info.Name = $identity.Name }
                if ($identity.Version) { $info.Version = $identity.Version }
                if ($identity.Publisher) { $info.Publisher = $identity.Publisher }
                if ($identity.ProcessorArchitecture) { $info.Architecture = $identity.ProcessorArchitecture }
            }
            $displayNode = $xml.SelectSingleNode("//*[local-name()='Properties']/*[local-name()='DisplayName']")
            if ($displayNode -and $displayNode.'#text') { $info.DisplayName = $displayNode.'#text' }
        }
    } finally { $zip.Dispose() }

    return [PSCustomObject]$info
}

function New-AppxRegistryKey {
    <#
      确保注册表键存在（含所有父键）；已存在时只是打开它。

      不能用 New-Item -Force：实测在 HKLM 下，PowerShell registry provider
      的 -Force 路径对任意键都返回 ERROR_ACCESS_DENIED（连全新的键也一样），
      而同一个键改用 .NET 的 CreateSubKey 完全正常。本脚本用 -AllUsers
      注册关联时会写 HKEY_LOCAL_MACHINE，因此会整步失败。
    #>
    param([string]$Path)

    $match = [regex]::Match($Path, '^(?i)(?:Registry::)?HKEY_(LOCAL_MACHINE|CURRENT_USER)\\(.+)$')
    if ($match.Success) {
        $root = if ($match.Groups[1].Value -ieq 'LOCAL_MACHINE') {
            [Microsoft.Win32.Registry]::LocalMachine
        } else {
            [Microsoft.Win32.Registry]::CurrentUser
        }
        $key = $root.CreateSubKey($match.Groups[2].Value)
        if ($key) { $key.Close() }
        return
    }

    New-Item -Path $Path -Force | Out-Null
}

function Register-AppxAssociations {
    param([switch]$Machine)

    if ($Machine) {
        # 所有用户的关联不能用当前用户的 WindowsApps 别名，改用包本体路径（版本固定）。
        $pkg = Get-AppxPackage -Name Microsoft.PowerShell -ErrorAction SilentlyContinue
        $pwsh = if ($pkg) { Join-Path $pkg.InstallLocation 'pwsh.exe' } else { $null }
    } else {
        $pwsh = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'
        if (-not (Test-Path -LiteralPath $pwsh)) {
            $pwsh = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
        }
    }

    if ($pwsh -and (Test-Path -LiteralPath $pwsh)) {
        # PowerShell 7 的 LocalMachine 执行策略为 RemoteSigned，本地脚本可直接运行。
        $openCmd = '"{0}" -NoLogo -NoProfile -File "{1}" "%1"' -f $pwsh, $ScriptPath
    } else {
        # 回退到 Windows PowerShell 5.1（默认 Restricted，需显式放行本地脚本）。
        $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $openCmd = '"{0}" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "{1}" "%1"' -f $ps51, $ScriptPath
    }

    $base = if ($Machine) { 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Classes' } else { 'Registry::HKEY_CURRENT_USER\Software\Classes' }
    $prog = Join-Path $base $ProgId

    New-AppxRegistryKey -Path (Join-Path $prog 'shell\open\command')
    New-AppxRegistryKey -Path (Join-Path $prog 'DefaultIcon')
    Set-ItemProperty -Path $prog -Name '(default)' -Value $ProgIdFriendly
    Set-ItemProperty -Path (Join-Path $prog 'DefaultIcon') -Name '(default)' -Value "$env:SystemRoot\System32\shell32.dll,163"
    # 必须写成 REG_EXPAND_SZ：命令里的 %LOCALAPPDATA% 只有在 ExpandString 类型下
    # 才会被资源管理器展开。写成 REG_SZ 时 shell 会把 %LOCALAPPDATA% 当成字面量，
    # 双击包文件会直接失败（“拒绝访问”/找不到文件）。
    New-ItemProperty -Path (Join-Path $prog 'shell\open\command') -Name '(default)' `
        -Value $openCmd -PropertyType ExpandString -Force | Out-Null

    foreach ($ext in $Extensions) {
        $extKey = Join-Path $base $ext
        New-AppxRegistryKey -Path $extKey
        Set-ItemProperty -Path $extKey -Name '(default)' -Value $ProgId
        New-ItemProperty -Path $extKey -Name 'Content Type' -Value 'application/octet-stream' -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $extKey -Name 'PerceivedType' -Value 'document' -PropertyType String -Force | Out-Null
    }

    Write-Host ("已注册关联（{0}）：{1}" -f $(if ($Machine) { '所有用户' } else { '当前用户' }), ($Extensions -join ' ')) -ForegroundColor Green
    Write-Host "打开命令：$openCmd"
}

# 不写 FileExts\...\UserChoice：Windows 会校验其中的 Hash，而该算法在不同版本上
# 不一致，写入无效哈希反而会让系统重置默认应用。只注册 ProgId 与扩展名。

function Install-Package {
    param([string]$Path, [switch]$ProvisionAllUsers)

    $file = Get-Item -LiteralPath $Path
    $info = Get-PackageInfo -File $file

    $text = @"
========================================
          AppX / MSIX 安装确认
========================================
文件名   : $($info.Name)
显示名称 : $($info.DisplayName)
版本     : $($info.Version)
发布者   : $($info.Publisher)
架构     : $($info.Architecture)
文件大小 : $($info.SizeMB) MB
路径     : $($info.FullName)
========================================

是否安装？
"@

    if (-not (Show-Confirm -Text $text)) { return }

    Import-Module Appx -UseWindowsPowerShell -ErrorAction SilentlyContinue

    if ($ProvisionAllUsers -and (Test-Admin)) {
        Add-AppxProvisionedPackage -Online -PackagePath $file.FullName -SkipLicense | Out-Null
        Write-Host '已为所有用户预配。' -ForegroundColor Green
        return
    }

    Add-AppxPackage -Path $file.FullName
    Write-Host '安装完成。' -ForegroundColor Green
}

try {
    # 双击打开时先给窗口起个名字，否则标题栏是空的，看着像卡住了。
    try { $Host.UI.RawUI.WindowTitle = 'Appx / MSIX 安装程序' } catch { }

    if ($Register) {
        Register-AppxAssociations
        if (Test-Admin) { Register-AppxAssociations -Machine }
        Write-Host '文件关联已注册。' -ForegroundColor Green
        return
    }

    if (-not $PackagePath) {
        Show-Message -Text '请把一个 .msix / .msixbundle / .appx / .appxbundle 文件拖到本脚本上，或使用 -Register 参数注册关联。' -Kind Warning
        return
    }

    $resolved = [System.IO.Path]::GetFullPath($PackagePath.Trim('"'))
    Install-Package -Path $resolved -ProvisionAllUsers:$AllUsers
    Show-Message -Text ("安装完成：`n" + [System.IO.Path]::GetFileName($resolved))
}
catch {
    Show-Message -Text ("安装失败：`n" + $_.Exception.Message) -Kind Error
}
