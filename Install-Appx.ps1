<#
.SYNOPSIS
    安装 .msix / .msixbundle / .appx / .appxbundle / .appinstaller 包，并可将这些扩展名关联到本脚本。

.DESCRIPTION
    双击包文件时由关联调用：读取清单 -> 弹窗确认 -> Add-AppxPackage 安装。
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

function Show-Message {
    param([string]$Text, [string]$Title = 'Appx 安装程序', [string]$Kind = 'Info')
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

    New-Item -Path (Join-Path $prog 'shell\open\command') -Force | Out-Null
    New-Item -Path (Join-Path $prog 'DefaultIcon') -Force | Out-Null
    Set-ItemProperty -Path $prog -Name '(default)' -Value $ProgIdFriendly
    Set-ItemProperty -Path (Join-Path $prog 'DefaultIcon') -Name '(default)' -Value "$env:SystemRoot\System32\shell32.dll,163"
    Set-ItemProperty -Path (Join-Path $prog 'shell\open\command') -Name '(default)' -Value $openCmd

    foreach ($ext in $Extensions) {
        $extKey = Join-Path $base $ext
        New-Item -Path $extKey -Force | Out-Null
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
