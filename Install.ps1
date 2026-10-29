#Requires -Version 5.1
<#
.SYNOPSIS
    一键把 Windows Terminal + PowerShell 7 配置成系统的默认终端与默认 Shell。

.DESCRIPTION
    本脚本会做以下事情，每一项都可以由 Uninstall.ps1 精确回滚：

      1. 安装 PowerShell 7 (MSIX) 与 Windows Terminal (MSIX)
      2. 把两个包预配给所有用户（新用户登录后自动拥有）
      3. 开始菜单里的 "Windows PowerShell" / "Windows PowerShell (x86)"
         全部改指向 pwsh 7，原快捷方式备份为 .lnk.bak
      4. 隐藏 Shift + 右键菜单中的 "在此处打开 PowerShell 窗口"
      5. 把默认终端（控制台主机）设置为 Windows Terminal
      6. 从用户 PATH 与系统 PATH 中移除 WindowsPowerShell\v1.0
      7. 把 .msix / .msixbundle / .appx / .appxbundle / .appinstaller
         关联到本套件自带的 Install-Appx.ps1

    系统自带的 powershell.exe 文件（System32 与 SysWOW64）不做任何改动。

.PARAMETER PowerShellPackage
    PowerShell 7 包（.msixbundle）的本地路径。省略则自动下载。

.PARAMETER TerminalPackage
    Windows Terminal 包（.msix / .msixbundle）的本地路径。省略则自动下载。

.PARAMETER NoProvision
    不为所有用户预配，只给当前用户安装。

.PARAMETER NoAssociations
    不注册 .msix / .appx 文件关联。

.PARAMETER KeepWindowsPowerShellPath
    保留 PATH 中的 WindowsPowerShell\v1.0。

.PARAMETER SkipSignatureCheck
    跳过 MSIX 包的 Authenticode 签名校验（不建议）。

.PARAMETER Verify
    只打印当前配置状态，不做任何修改。不需要管理员权限。

.PARAMETER NoPause
    结束后不等待按键（用于自动化）。

.PARAMETER StatePath
    状态文件路径，默认 C:\ProgramData\AppxInstaller\state.json。
    卸载时用同一个路径才能精确回滚。

.EXAMPLE
    .\Install.ps1
    .\Install.ps1 -PowerShellPackage D:\pkg\PowerShell-7.6.7.msixbundle
    .\Install.ps1 -Verify
#>
[CmdletBinding()]
param(
    [string]$PowerShellPackage,
    [string]$TerminalPackage,
    [switch]$NoProvision,
    [switch]$NoAssociations,
    [switch]$KeepWindowsPowerShellPath,
    [switch]$SkipSignatureCheck,
    [switch]$Verify,
    [switch]$NoPause,
    [string]$StatePath = 'C:\ProgramData\AppxInstaller\state.json'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

. (Join-Path $PSScriptRoot 'lib\Common.ps1')

if ($PSVersionTable.PSEdition -eq 'Core') {
    exit (Invoke-UnderWindowsPowerShell -ScriptPath (Join-Path $PSScriptRoot 'Install.ps1') -BoundParameters $PSBoundParameters)
}

if (-not $Verify -and -not (Test-IsAdministrator)) {
    exit (Request-Administrator -ScriptPath (Join-Path $PSScriptRoot 'Install.ps1') -BoundParameters $PSBoundParameters)
}

$StateRoot = Join-Path $env:ProgramData 'AppxInstaller'
$CacheRoot = Join-Path $StateRoot 'cache'
$HandlerFile = Join-Path $StateRoot 'Install-Appx.ps1'

$PowerShellUrl = 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.7/PowerShell-7.6.7.msixbundle'
$PowerShellFileName = 'PowerShell-7.6.7.msixbundle'
$TerminalUrl = 'https://github.com/microsoft/terminal/releases/download/v1.25.2733.0/Microsoft.WindowsTerminal_1.25.2733.0_8wekyb3d8bbwe.msix'
$TerminalFileName = 'Microsoft.WindowsTerminal_1.25.2733.0_8wekyb3d8bbwe.msix'

function Resolve-KitPackage {
    param([string]$Path, [string]$Url, [string]$FileName, [string]$Label)

    if ($Path) {
        if (-not (Test-Path -LiteralPath $Path)) { throw ($Label + ' 包不存在：' + $Path) }
        return (Resolve-Path -LiteralPath $Path).Path
    }

    $cached = Join-Path $CacheRoot $FileName
    if (Test-Path -LiteralPath $cached) { return $cached }

    New-Item -ItemType Directory -Force -Path $CacheRoot | Out-Null
    Write-Host ('正在下载 ' + $Label + ' ...')
    try {
        Invoke-WebRequest -Uri $Url -OutFile $cached -UseBasicParsing -ErrorAction Stop
    } catch {
        if (Test-Path -LiteralPath $cached) { Remove-Item -LiteralPath $cached -Force }
        Write-Host '  HTTP 下载中断，改用 curl 重试...' -ForegroundColor Yellow
        & curl.exe -L --retry 5 --retry-delay 3 --fail --silent --show-error -o $cached $Url
        if ($LASTEXITCODE -ne 0) {
            throw ('下载 ' + $Label + ' 失败。请手动下载后使用对应的本地文件参数。')
        }
    }
    return $cached
}

function Assert-KitSignature {
    param([string]$Path, [string]$Label)

    $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    if ($signature.Status -ne 'Valid') {
        throw ('{0} 签名无效（{1}）。如确认来源可信，可加 -SkipSignatureCheck。' -f $Label, $signature.Status)
    }
    $subject = ''
    if ($signature.SignerCertificate) { $subject = $signature.SignerCertificate.Subject }
    if ($subject -notmatch 'Microsoft') {
        throw ('{0} 的签名者为「{1}」，不是 Microsoft，已停止。' -f $Label, $subject)
    }
    Write-Host ('{0} 签名校验通过：Microsoft' -f $Label) -ForegroundColor DarkGray
}

function Install-KitAppx {
    param(
        [string]$Path,
        [string]$PackageName,
        [string]$Label
    )

    $leaf = Split-Path -Leaf $Path
    $installed = Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue | Select-Object -First 1
    $targetVersion = Get-AppxFileVersion -Path $Path

    if ($installed -and $targetVersion -and ([version]$installed.Version -ge $targetVersion)) {
        Write-Host ('{0}：已安装 {1}，无需重装。' -f $Label, $installed.Version) -ForegroundColor DarkGray
        return
    }

    try {
        Write-Host ('正在安装 {0} ...' -f $leaf)

        # 正在运行的 pwsh / Windows Terminal 会阻止包更新（0x80073D02），
        # 这种情况需要用 -ForceApplicationShutdown 正常关闭它们。
        $inUse = $false
        if ($PackageName -eq 'Microsoft.PowerShell') {
            $inUse = $null -ne (Get-Process -Name 'pwsh' -ErrorAction SilentlyContinue)
        } elseif ($PackageName -eq 'Microsoft.WindowsTerminal') {
            $inUse = $null -ne (Get-Process -Name 'WindowsTerminal' -ErrorAction SilentlyContinue)
        }
        if ($inUse) {
            Write-Host ('  {0} 正在运行，安装期间会被关闭。' -f $Label) -ForegroundColor DarkYellow
            Add-AppxPackage -Path $Path -ForceApplicationShutdown -ErrorAction Stop
        } else {
            Add-AppxPackage -Path $Path -ErrorAction Stop
        }
    } catch {
        $message = $_.Exception.Message
        if ($message -match '0x80073D06|already installed') {
            Write-Host '  已安装相同或更高版本，跳过。' -ForegroundColor DarkGray
            return
        }
        throw ("安装 {0} 失败：`n{1}" -f $leaf, $message)
    }
}

if ($Verify) {
    Show-KitStatus
    if (-not $NoPause) { [void](Read-Host '按 Enter 退出') }
    return
}

New-Item -ItemType Directory -Force -Path $StateRoot, $CacheRoot | Out-Null

$state = Load-KitState -Path $StatePath
if ($state) {
    Write-Host '检测到已有的状态文件，将保留最初记录的原始配置。' -ForegroundColor Yellow
    $state = Repair-KitState -State $state
} else {
    $state = New-KitState
}

$errorOccurred = $false

try {
    # ---------------------------------------------------------------
    Write-Step '1/7  安装 PowerShell 7 与 Windows Terminal'
    # ---------------------------------------------------------------
    $psPackagePath = Resolve-KitPackage -Path $PowerShellPackage -Url $PowerShellUrl -FileName $PowerShellFileName -Label 'PowerShell 7'
    $wtPackagePath = Resolve-KitPackage -Path $TerminalPackage -Url $TerminalUrl -FileName $TerminalFileName -Label 'Windows Terminal'

    if (-not $SkipSignatureCheck) {
        Assert-KitSignature -Path $psPackagePath -Label 'PowerShell 7'
        Assert-KitSignature -Path $wtPackagePath -Label 'Windows Terminal'
    }

    $psBefore = Get-AppxPackage -Name 'Microsoft.PowerShell' -ErrorAction SilentlyContinue | Select-Object -First 1
    $wtBefore = Get-AppxPackage -Name 'Microsoft.WindowsTerminal' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $state.Packages.ContainsKey('PowerShellVersionBefore')) {
        $state.Packages['PowerShellVersionBefore'] = $(if ($psBefore) { $psBefore.Version.ToString() } else { $null })
    }
    if (-not $state.Packages.ContainsKey('TerminalVersionBefore')) {
        $state.Packages['TerminalVersionBefore'] = $(if ($wtBefore) { $wtBefore.Version.ToString() } else { $null })
    }

    Install-KitAppx -Path $psPackagePath -PackageName 'Microsoft.PowerShell' -Label 'PowerShell 7'
    Install-KitAppx -Path $wtPackagePath -PackageName 'Microsoft.WindowsTerminal' -Label 'Windows Terminal'

    $psNow = Get-AppxPackage -Name 'Microsoft.PowerShell' -ErrorAction SilentlyContinue | Select-Object -First 1
    $wtNow = Get-AppxPackage -Name 'Microsoft.WindowsTerminal' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $psNow) { throw 'PowerShell 7 安装后仍未检出，请检查系统日志。' }
    if (-not $wtNow) { throw 'Windows Terminal 安装后仍未检出，请检查系统日志。' }
    Write-Host ('PowerShell 7      : ' + $psNow.Version) -ForegroundColor Green
    Write-Host ('Windows Terminal  : ' + $wtNow.Version) -ForegroundColor Green

    # ---------------------------------------------------------------
    Write-Step '2/7  预配给所有用户'
    # ---------------------------------------------------------------
    if ($NoProvision) {
        Write-Host '已跳过（-NoProvision）。'
    } else {
        try {
            $provisionedBefore = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop |
                ForEach-Object { $_.PackageName })
            if (-not $state.Packages.ContainsKey('ProvisionedBefore')) {
                $state.Packages['ProvisionedBefore'] = $provisionedBefore
            }
        } catch {
            Write-Warning ('读取已预配包列表失败：' + $_.Exception.Message)
        }

        foreach ($package in @(
                @{ Path = $psPackagePath; Label = 'PowerShell 7' },
                @{ Path = $wtPackagePath; Label = 'Windows Terminal' })) {
            try {
                Add-AppxProvisionedPackage -Online -PackagePath $package.Path -SkipLicense -ErrorAction Stop | Out-Null
                Write-Host ($package.Label + ' : 已预配') -ForegroundColor Green
            } catch {
                Write-Warning ($package.Label + ' 预配失败（已安装给当前用户）：' + $_.Exception.Message)
            }
        }
    }

    # ---------------------------------------------------------------
    Write-Step '3/7  重定向开始菜单的 Windows PowerShell 快捷方式'
    # ---------------------------------------------------------------
    $shortcutCount = 0
    foreach ($directory in @(Get-ShortcutDirs)) {
        foreach ($name in $Kit.ShortcutNames) {
            $path = Join-Path $directory $name
            if (-not (Test-Path -LiteralPath $path)) { continue }

            if (-not $state.Shortcuts.ContainsKey($path)) {
                $info = Get-ShortcutInfo -Path $path
                $backup = $path + '.bak'
                if (-not (Test-Path -LiteralPath $backup)) {
                    Copy-Item -LiteralPath $path -Destination $backup -Force
                }
                $state.Shortcuts[$path] = @{
                    TargetPath       = $info.TargetPath
                    Arguments        = $info.Arguments
                    WorkingDirectory = $info.WorkingDirectory
                    IconLocation     = $info.IconLocation
                    Description      = $info.Description
                    Backup           = $backup
                }
            }

            Set-ShortcutPowerShell7 -Path $path
            $shortcutCount++
        }
    }
    Write-Host ('已处理快捷方式：{0} 个' -f $shortcutCount) -ForegroundColor Green

    # ---------------------------------------------------------------
    #  所有用户配置单元（当前用户 + 其他用户 + Default 模板）
    # ---------------------------------------------------------------
    $openHives = New-Object System.Collections.ArrayList
    $roots = New-Object System.Collections.ArrayList
    try {
        $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        [void]$roots.Add(@{ Id = 'HKCU'; Root = 'HKCU:' })

        foreach ($profile in @(Get-UserProfileList)) {
            if ($profile.Sid -eq $currentSid) { continue }
            try {
                $hive = Open-UserHive -Sid $profile.Sid -ProfilePath $profile.Path
                [void]$openHives.Add($hive)
                [void]$roots.Add(@{ Id = $profile.Sid; Root = $hive.Root })
            } catch {
                Write-Warning ('跳过用户 {0}：{1}' -f $profile.Path, $_.Exception.Message)
            }
        }

        try {
            $defaultHive = Open-DefaultHive
            [void]$openHives.Add($defaultHive)
            [void]$roots.Add(@{ Id = 'Default'; Root = $defaultHive.Root })
        } catch {
            Write-Warning ('跳过默认用户模板：' + $_.Exception.Message)
        }

        # -----------------------------------------------------------
        Write-Step '4/7  隐藏 Shift + 右键的 PowerShell 菜单项'
        # -----------------------------------------------------------
        $hiddenCount = 0
        foreach ($root in $roots) {
            if (-not $state.ContextMenu.ContainsKey($root.Id)) { $state.ContextMenu[$root.Id] = @{} }
            foreach ($relative in $Kit.ContextMenuKeys) {
                $path = Join-Path $root.Root $relative
                $keyExisted = Test-RegistryKey -Path $path
                New-RegistryKey -Path $path

                if (-not $state.ContextMenu[$root.Id].ContainsKey($relative)) {
                    $existing = Get-RegistryValue -Path $path -Name 'HideBasedOnVelocityId'
                    $state.ContextMenu[$root.Id][$relative] = @{
                        KeyExisted   = $keyExisted
                        ValueExisted = ($null -ne $existing)
                        Value        = $existing
                    }
                }

                try {
                    Set-RegistryValue -Path $path -Name 'HideBasedOnVelocityId' -Value $Kit.HideValue -Type DWord
                } catch {
                    Write-Host ('  写入失败：{0}  ({1})' -f $path, $_.Exception.Message) -ForegroundColor Red
                    throw
                }
                $hiddenCount++
            }
        }
        Write-Host ('已应用隐藏值：{0} 处（当前用户 / 其他用户 / 新建用户模板）' -f $hiddenCount) -ForegroundColor Green

        # -----------------------------------------------------------
        Write-Step '5/7  设置 Windows Terminal 为默认终端'
        # -----------------------------------------------------------
        $terminalCount = 0
        foreach ($root in $roots) {
            $startupPath = Join-Path $root.Root 'Console\%%Startup'
            if (-not $state.DefaultTerminal.ContainsKey($root.Id)) {
                $state.DefaultTerminal[$root.Id] = @{
                    KeyExisted = (Test-RegistryKey -Path $startupPath)
                    Console    = (Get-RegistryValue -Path $startupPath -Name 'DelegationConsole')
                    Terminal   = (Get-RegistryValue -Path $startupPath -Name 'DelegationTerminal')
                }
            }
            try {
                Set-RegistryValue -Path $startupPath -Name 'DelegationConsole' -Value $Kit.ConsoleGuid
                Set-RegistryValue -Path $startupPath -Name 'DelegationTerminal' -Value $Kit.TerminalGuid
            } catch {
                Write-Host ('  写入失败：{0}  ({1})' -f $startupPath, $_.Exception.Message) -ForegroundColor Red
                throw
            }
            $terminalCount++
        }
        Write-Host ('已设置默认终端：{0} 处' -f $terminalCount) -ForegroundColor Green
    } finally {
        foreach ($hive in $openHives) { Close-UserHive -Hive $hive }
    }

    # ---------------------------------------------------------------
    Write-Step '6/7  从 PATH 中移除 WindowsPowerShell\v1.0'
    # ---------------------------------------------------------------
    if ($KeepWindowsPowerShellPath) {
        Write-Host '已跳过（-KeepWindowsPowerShellPath）。'
    } else {
        if (-not $state.Paths.UserOriginal) {
            $state.Paths.UserOriginal = Get-EnvironmentPathValue -Scope User
        }
        if (-not $state.Paths.MachineOriginal) {
            $state.Paths.MachineOriginal = Get-EnvironmentPathValue -Scope Machine
        }

        $userPath = Get-EnvironmentPathValue -Scope User
        if ($null -eq $userPath) { $userPath = '' }
        $userResult = Remove-LegacyPowerShellPathEntry -Value $userPath
        if ($userResult.Removed.Count -gt 0) {
            Set-EnvironmentPathValue -Scope User -Value $userResult.Value
            $state.Paths.UserRemoved = @(@($state.Paths.UserRemoved) + @($userResult.Removed) | Select-Object -Unique)
            $state.Paths.Modified = $true
            Write-Host ('用户 PATH：移除 ' + ($userResult.Removed -join '; ')) -ForegroundColor Green
        } else {
            Write-Host '用户 PATH：没有需要移除的条目。'
        }

        $machinePath = Get-EnvironmentPathValue -Scope Machine
        if ($null -eq $machinePath) { $machinePath = '' }
        $machineResult = Remove-LegacyPowerShellPathEntry -Value $machinePath
        if ($machineResult.Removed.Count -gt 0) {
            Set-EnvironmentPathValue -Scope Machine -Value $machineResult.Value
            $state.Paths.MachineRemoved = @(@($state.Paths.MachineRemoved) + @($machineResult.Removed) | Select-Object -Unique)
            $state.Paths.Modified = $true
            Write-Host ('系统 PATH：移除 ' + ($machineResult.Removed -join '; ')) -ForegroundColor Green
        } else {
            Write-Host '系统 PATH：没有需要移除的条目。'
        }
    }

    # ---------------------------------------------------------------
    Write-Step '7/7  注册 .msix / .appx 文件关联'
    # ---------------------------------------------------------------
    if ($NoAssociations) {
        Write-Host '已跳过（-NoAssociations）。'
    } else {
        $sourceHandler = Join-Path $PSScriptRoot 'Install-Appx.ps1'
        if (Test-Path -LiteralPath $sourceHandler) {
            Copy-Item -LiteralPath $sourceHandler -Destination $HandlerFile -Force
            Register-KitAssociations -State $state -HandlerPath $HandlerFile
            Write-Host ('已关联：' + ($Kit.Extensions -join ' ')) -ForegroundColor Green
        } else {
            Write-Warning ('找不到 ' + $sourceHandler + '，已跳过文件关联。')
        }
    }

    Save-KitState -State $state -Path $StatePath
} catch {
    $errorOccurred = $true
    Save-KitState -State $state -Path $StatePath
    Write-Host ''
    Write-Host ('安装过程出错：' + $_.Exception.Message) -ForegroundColor Red
    Write-Host ('位置：' + $_.InvocationInfo.PositionMessage) -ForegroundColor DarkGray
    Write-Host ('调用栈：' + $_.ScriptStackTrace) -ForegroundColor DarkGray
    Write-Host '当前进度已保存，修正问题后可以重新运行本脚本，已完成的步骤不会重复备份。' -ForegroundColor Yellow
}

if (-not $errorOccurred) {
    Show-KitStatus
    Write-Host '安装完成。' -ForegroundColor Green
    Write-Host ('状态文件：' + $StatePath)
    Write-Host '如需还原，运行 Uninstall.cmd（或 Uninstall.ps1）。'
}

if (-not $NoPause) { [void](Read-Host '按 Enter 退出') }

if ($errorOccurred) { exit 1 }
