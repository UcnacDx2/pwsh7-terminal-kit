#Requires -Version 5.1
<#
.SYNOPSIS
    卸载 Install.ps1 所做的一切修改，并尽量恢复安装前的状态。

.DESCRIPTION
    回滚顺序与安装顺序相反：

      1. 移除 .msix / .appx 文件关联
      2. 移除 powershell.exe 转发器（机器 PATH 条目 + Program Files 下的目录）
      3. 把 WindowsPowerShell\v1.0 重新加回 PATH
      4. 恢复默认终端设置
      5. 恢复 Shift + 右键的 PowerShell 菜单项
      6. 从 .lnk.bak 恢复开始菜单快捷方式
      7. 移除预配包与已安装的 MSIX 应用（安装前就存在的版本会保留）
      8. 删除本套件在 ProgramData 下的安装副本与状态文件

    Install.ps1 会在 C:\ProgramData\AppxInstaller\state.json 记录每一项修改前的值，
    本脚本据此精确还原；状态文件不存在时，只清理“当前值等于本套件写入值”的项。

.PARAMETER KeepPackages
    不卸载 PowerShell 7 与 Windows Terminal，只还原配置。

.PARAMETER KeepProvisioned
    不撤销所有用户的预配，只还原当前用户的配置。

.PARAMETER StatePath
    状态文件路径，默认 C:\ProgramData\AppxInstaller\state.json。

.PARAMETER NoPause
    结束后不等待按键（用于自动化）。

.EXAMPLE
    .\Uninstall.ps1
    .\Uninstall.ps1 -KeepPackages
#>
[CmdletBinding()]
param(
    [switch]$KeepPackages,
    [switch]$KeepProvisioned,
    [string]$StatePath = 'C:\ProgramData\AppxInstaller\state.json',
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

. (Join-Path $PSScriptRoot 'lib\Common.ps1')

if ($PSVersionTable.PSEdition -eq 'Core') {
    exit (Invoke-UnderWindowsPowerShell -ScriptPath (Join-Path $PSScriptRoot 'Uninstall.ps1') -BoundParameters $PSBoundParameters)
}

if (-not (Test-IsAdministrator)) {
    exit (Request-Administrator -ScriptPath (Join-Path $PSScriptRoot 'Uninstall.ps1') -BoundParameters $PSBoundParameters)
}

$state = Load-KitState -Path $StatePath
if ($state) {
    $state = Repair-KitState -State $state
    Write-Host ('已读取状态文件：' + $StatePath) -ForegroundColor DarkGray
} else {
    Write-Host '未找到状态文件，将按“当前值等于本套件写入值”的方式做尽力清理。' -ForegroundColor Yellow
}

$errorOccurred = $false

try {
    # ---------------------------------------------------------------
    Write-Step '1/8  移除 .msix / .appx 文件关联'
    # ---------------------------------------------------------------
    Unregister-KitAssociations -State $state
    Write-Host '文件关联已还原。' -ForegroundColor Green

    # ---------------------------------------------------------------
    Write-Step '2/8  移除 powershell.exe 转发器'
    # ---------------------------------------------------------------
    # 必须先于 PATH 还原：这里要从机器 PATH 摘掉转发器目录，
    # 再让下一步把 WindowsPowerShell\v1.0 加回来。
    Remove-PowerShellShim -State $state

    # ---------------------------------------------------------------
    Write-Step '3/8  还原 PATH'
    # ---------------------------------------------------------------
    $userEntries = @()
    $machineEntries = @()
    if ($state -and $state.Paths) {
        $userEntries = @($state.Paths.UserRemoved | Where-Object { $_ })
        $machineEntries = @($state.Paths.MachineRemoved | Where-Object { $_ })
    }
    if ($machineEntries.Count -eq 0 -and -not $state) {
        # 完全没有状态文件时，按系统默认位置补回
        $machineEntries = @('%SystemRoot%\System32\WindowsPowerShell\v1.0\')
    }

    $currentUserPath = Get-EnvironmentPathValue -Scope User
    if ($null -eq $currentUserPath) { $currentUserPath = '' }
    $newUserPath = Add-PathEntriesIfMissing -Value $currentUserPath -Entries $userEntries
    if ($newUserPath -ne $currentUserPath) {
        Set-EnvironmentPathValue -Scope User -Value $newUserPath
        Write-Host ('用户 PATH：已恢复 ' + ($userEntries -join '; ')) -ForegroundColor Green
    } else {
        Write-Host '用户 PATH：无需改动。'
    }

    $currentMachinePath = Get-EnvironmentPathValue -Scope Machine
    if ($null -eq $currentMachinePath) { $currentMachinePath = '' }
    $newMachinePath = Add-PathEntriesIfMissing -Value $currentMachinePath -Entries $machineEntries
    if ($newMachinePath -ne $currentMachinePath) {
        Set-EnvironmentPathValue -Scope Machine -Value $newMachinePath
        Write-Host ('系统 PATH：已恢复 ' + ($machineEntries -join '; ')) -ForegroundColor Green
    } else {
        Write-Host '系统 PATH：无需改动。'
    }

    # ---------------------------------------------------------------
    #  用户配置单元（当前用户 + 其他用户 + Default 模板）
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
        Write-Step '4/8  恢复默认终端'
        # -----------------------------------------------------------
        foreach ($root in $roots) {
            $startupPath = Join-Path $root.Root 'Console\%%Startup'
            $record = $null
            if ($state -and $state.DefaultTerminal.ContainsKey($root.Id)) { $record = $state.DefaultTerminal[$root.Id] }

            if ($record) {
                if ($record.Console) { Set-RegistryValue -Path $startupPath -Name 'DelegationConsole' -Value $record.Console }
                else { Remove-RegistryValue -Path $startupPath -Name 'DelegationConsole' }

                if ($record.Terminal) { Set-RegistryValue -Path $startupPath -Name 'DelegationTerminal' -Value $record.Terminal }
                else { Remove-RegistryValue -Path $startupPath -Name 'DelegationTerminal' }

                if (-not $record.KeyExisted) { Remove-RegistryKeyIfEmpty -Path $startupPath }
            } else {
                # 没有记录：只撤销指向 Windows Terminal 的值
                if ((Get-RegistryValue -Path $startupPath -Name 'DelegationConsole') -eq $Kit.ConsoleGuid) {
                    Remove-RegistryValue -Path $startupPath -Name 'DelegationConsole'
                }
                if ((Get-RegistryValue -Path $startupPath -Name 'DelegationTerminal') -eq $Kit.TerminalGuid) {
                    Remove-RegistryValue -Path $startupPath -Name 'DelegationTerminal'
                }
            }
        }
        Write-Host '默认终端已还原。' -ForegroundColor Green

        # -----------------------------------------------------------
        Write-Step '5/8  恢复 Shift + 右键的 PowerShell 菜单项'
        # -----------------------------------------------------------
        foreach ($root in $roots) {
            $map = $null
            if ($state -and $state.ContextMenu.ContainsKey($root.Id)) { $map = $state.ContextMenu[$root.Id] }

            foreach ($relative in $Kit.ContextMenuKeys) {
                $path = Join-Path $root.Root $relative
                $record = $null
                if ($map -and $map.ContainsKey($relative)) { $record = $map[$relative] }

                if ($record) {
                    if ($record.ValueExisted) {
                        Set-RegistryValue -Path $path -Name 'HideBasedOnVelocityId' -Value $record.Value -Type DWord
                    } else {
                        Remove-RegistryValue -Path $path -Name 'HideBasedOnVelocityId'
                    }
                    if (-not $record.KeyExisted) { Remove-RegistryKeyIfEmpty -Path $path }
                } else {
                    if ((Get-RegistryValue -Path $path -Name 'HideBasedOnVelocityId') -eq $Kit.HideValue) {
                        Remove-RegistryValue -Path $path -Name 'HideBasedOnVelocityId'
                    }
                }
            }
        }
        Write-Host '右键菜单已还原。' -ForegroundColor Green
    } finally {
        foreach ($hive in $openHives) { Close-UserHive -Hive $hive }
    }

    # ---------------------------------------------------------------
    Write-Step '6/8  恢复开始菜单快捷方式'
    # ---------------------------------------------------------------
    $restored = 0
    foreach ($directory in @(Get-ShortcutDirs)) {
        foreach ($name in $Kit.ShortcutNames) {
            $path = Join-Path $directory $name
            if (-not (Test-Path -LiteralPath $path)) { continue }

            $record = $null
            if ($state -and $state.Shortcuts.ContainsKey($path)) { $record = $state.Shortcuts[$path] }

            if ($record) {
                Restore-Shortcut -Path $path -Info $record
                $restored++
            } elseif (Test-Path -LiteralPath ($path + '.bak')) {
                Restore-Shortcut -Path $path -Info @{ Backup = ($path + '.bak') }
                $restored++
            }
        }
    }
    Write-Host ('已恢复快捷方式：{0} 个' -f $restored) -ForegroundColor Green

    # ---------------------------------------------------------------
    Write-Step '7/8  卸载预配包与 MSIX 应用'
    # ---------------------------------------------------------------
    if ($KeepPackages) {
        Write-Host '已跳过（-KeepPackages）。'
    } else {
        $provisionedBefore = @()
        if ($state -and $state.Packages.ContainsKey('ProvisionedBefore')) {
            $provisionedBefore = @(@($state.Packages['ProvisionedBefore']) | Where-Object { $_ })
        }

        $targets = @(
            @{ Name = 'Microsoft.PowerShell'; Label = 'PowerShell 7'; VersionBefore = $(if ($state) { $state.Packages['PowerShellVersionBefore'] } else { $null }) },
            @{ Name = 'Microsoft.WindowsTerminal'; Label = 'Windows Terminal'; VersionBefore = $(if ($state) { $state.Packages['TerminalVersionBefore'] } else { $null }) }
        )

        foreach ($target in $targets) {
            $package = Get-AppxPackage -Name $target.Name -ErrorAction SilentlyContinue | Select-Object -First 1

            if ($package) {
                if ($target.VersionBefore) {
                    Write-Host ('{0}：安装前已存在（{1}），保留当前版本 {2}。' -f $target.Label, $target.VersionBefore, $package.Version) -ForegroundColor Yellow
                } else {
                    try {
                        if ($target.Name -eq 'Microsoft.WindowsTerminal') {
                            Get-Process -Name 'WindowsTerminal' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                            Start-Sleep -Milliseconds 500
                        }
                        Remove-AppxPackage -Package $package.PackageFullName -ErrorAction Stop
                        Write-Host ('{0}：已卸载' -f $target.Label) -ForegroundColor Green
                    } catch {
                        Write-Warning ('{0} 卸载失败：{1}' -f $target.Label, $_.Exception.Message)
                    }
                }
            }

            if (-not $KeepProvisioned) {
                try {
                    $provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop |
                        Where-Object { $_.PackageName -like ($target.Name + '_*') })

                    foreach ($item in $provisioned) {
                        if ($provisionedBefore -contains $item.PackageName) {
                            Write-Host ('{0}：该预配包安装前已存在，保留。' -f $target.Label) -ForegroundColor Yellow
                            continue
                        }
                        try {
                            Remove-AppxProvisionedPackage -Online -PackageName $item.PackageName -ErrorAction Stop | Out-Null
                            Write-Host ('{0}：已取消所有用户预配' -f $target.Label) -ForegroundColor Green
                        } catch {
                            Write-Warning ('{0} 取消预配失败：{1}' -f $target.Label, $_.Exception.Message)
                        }
                    }
                } catch {
                    Write-Warning ('读取预配包列表失败：' + $_.Exception.Message)
                }
            }
        }
    }

    # ---------------------------------------------------------------
    Write-Step '8/8  清理安装副本与状态文件'
    # ---------------------------------------------------------------
    $handlerFile = Join-Path $env:ProgramData 'AppxInstaller\Install-Appx.ps1'
    if (Test-Path -LiteralPath $handlerFile) {
        try {
            Remove-Item -LiteralPath $handlerFile -Force -ErrorAction Stop
            Write-Host '已删除 Install-Appx.ps1 安装副本。'
        } catch {
            Write-Warning ('删除 Install-Appx.ps1 失败：' + $_.Exception.Message)
        }
    }

    if (Test-Path -LiteralPath $StatePath) {
        try {
            Remove-Item -LiteralPath $StatePath -Force -ErrorAction Stop
            Write-Host '已删除状态文件。'
        } catch {
            Write-Warning ('删除状态文件失败：' + $_.Exception.Message)
        }
    }

    $cacheRoot = Join-Path $env:ProgramData 'AppxInstaller\cache'
    if (Test-Path -LiteralPath $cacheRoot) {
        try {
            Remove-Item -LiteralPath $cacheRoot -Recurse -Force -ErrorAction Stop
            Write-Host '已删除下载缓存。'
        } catch {
            Write-Warning ('删除缓存失败：' + $_.Exception.Message)
        }
    }
} catch {
    $errorOccurred = $true
    Write-Host ''
    Write-Host ('卸载过程出错：' + $_.Exception.Message) -ForegroundColor Red
    Write-Host '已完成的还原步骤不会重复执行，可以修正问题后重新运行本脚本。' -ForegroundColor Yellow
}

if (-not $errorOccurred) {
    Write-Host ''
    Write-Host '卸载完成。重新登录后，新开的控制台会恢复为系统默认行为。' -ForegroundColor Green
}

if (-not $NoPause) { [void](Read-Host '按 Enter 退出') }

if ($errorOccurred) { exit 1 }
