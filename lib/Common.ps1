# ============================================================
#  AppxKit 公共函数库
#  由 Install.ps1 / Uninstall.ps1 点源（dot-source）加载
# ============================================================

$Kit = @{
    TerminalGuid    = '{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}'
    ConsoleGuid     = '{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}'
    HideValue       = 0x639BC8
    ProgId          = 'AppxInstaller.Package'
    Extensions      = @('.msix', '.msixbundle', '.appx', '.appxbundle', '.appinstaller')
    ShortcutNames   = @('Windows PowerShell.lnk', 'Windows PowerShell (x86).lnk')
    ContextMenuKeys = @(
        'Software\Classes\Directory\Background\shell\Powershell',
        'Software\Classes\Directory\shell\Powershell',
        'Software\Classes\Drive\shell\Powershell'
    )
}

# ---------------------------------------------------------
#  基础
# ---------------------------------------------------------

function Test-IsAdministrator {
    try {
        return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Get-KitArgumentList {
    param([string]$ScriptPath, $BoundParameters)

    $arguments = New-Object System.Collections.ArrayList
    foreach ($a in @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File')) { [void]$arguments.Add($a) }
    [void]$arguments.Add($ScriptPath)

    if ($BoundParameters) {
        foreach ($name in $BoundParameters.Keys) {
            $value = $BoundParameters[$name]
            if ($value -is [System.Management.Automation.SwitchParameter]) {
                if ($value.IsPresent) { [void]$arguments.Add('-' + $name) }
            } else {
                [void]$arguments.Add('-' + $name)
                [void]$arguments.Add([string]$value)
            }
        }
    }

    return [string[]]$arguments.ToArray()
}

function Invoke-UnderWindowsPowerShell {
    param([string]$ScriptPath, $BoundParameters)

    # 本套件依赖 Appx 模块。该模块的 ModuleToProcess 是 GAC 中的 .NET Framework
    # 程序集（Microsoft.Windows.Appx.PackageManager.Commands），虽然清单声明
    # CompatiblePSEditions = Desktop, Core，但在 .NET Core 运行时下加载时会在
    # GetExportedTypes() 抛出 PlatformNotSupportedException (0x80131539)。
    # 因此统一改由系统自带的 Windows PowerShell 5.1 执行。
    Write-Host '检测到 PowerShell 7：本机的 Appx 模块无法在 .NET Core 下加载，正在改用 Windows PowerShell 5.1 执行...' -ForegroundColor DarkGray

    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    # 输出直接送到控制台，返回值只保留退出码
    & $exe @(Get-KitArgumentList -ScriptPath $ScriptPath -BoundParameters $BoundParameters) | Out-Host
    return $LASTEXITCODE
}

function Request-Administrator {
    param(
        [string]$ScriptPath,
        $BoundParameters
    )

    # 必须用 Windows PowerShell 5.1 启动提权进程：
    # MSIX 版 pwsh 走 AppX 激活，不会继承管理员令牌。
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw '找不到 Windows PowerShell：' + $exe }

    $arguments = Get-KitArgumentList -ScriptPath $ScriptPath -BoundParameters $BoundParameters

    # Start-Process 会把参数拼成命令行，含空格的项需要显式加引号
    $quoted = @($arguments | ForEach-Object {
            if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ }
        })

    Write-Host '需要管理员权限，正在请求提权（请在 UAC 对话框中选择“是”）...' -ForegroundColor Yellow
    try {
        $process = Start-Process -FilePath $exe -ArgumentList $quoted `
            -Verb RunAs -PassThru -Wait -ErrorAction Stop
        if ($process.ExitCode -eq 0) {
            Write-Host '管理员窗口中的操作已完成。' -ForegroundColor Green
        } else {
            Write-Host ('管理员窗口返回代码：' + $process.ExitCode) -ForegroundColor Yellow
        }
        return $process.ExitCode
    } catch {
        Write-Host '提权被取消。' -ForegroundColor Red
        return 1223
    }
}

function Write-Step {
    param([string]$Text)
    Write-Host ''
    Write-Host ('=== ' + $Text + ' ===') -ForegroundColor Cyan
}

# ---------------------------------------------------------
#  状态文件
# ---------------------------------------------------------

function New-KitState {
    return @{
        SchemaVersion   = 1
        Created         = (Get-Date).ToString('o')
        LastUpdated     = $null
        Paths           = @{
            UserOriginal    = $null
            MachineOriginal = $null
            UserRemoved     = @()
            MachineRemoved  = @()
            Modified        = $false
        }
        Shortcuts       = @{}
        ContextMenu     = @{}
        DefaultTerminal = @{}
        Associations    = @{
            HKCU       = @{}
            HKLM       = @{}
            UserChoice = @{}
            Registered = $false
        }
        Packages        = @{}
    }
}

function Repair-KitState {
    param($State)

    $defaults = New-KitState
    foreach ($key in $defaults.Keys) {
        if (-not $State.ContainsKey($key)) { $State[$key] = $defaults[$key] }
    }
    foreach ($sub in @('Paths', 'Associations', 'Packages')) {
        if ($State[$sub] -isnot [System.Collections.IDictionary]) { $State[$sub] = $defaults[$sub] }
    }
    foreach ($sub in @('HKCU', 'HKLM', 'UserChoice')) {
        if (-not $State.Associations.ContainsKey($sub)) { $State.Associations[$sub] = @{} }
    }
    foreach ($sub in @('UserOriginal', 'MachineOriginal', 'UserRemoved', 'MachineRemoved', 'Modified')) {
        if (-not $State.Paths.ContainsKey($sub)) { $State.Paths[$sub] = $defaults.Paths[$sub] }
    }
    return $State
}

function ConvertTo-HashtableDeep {
    param($InputObject)

    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $result = @{}
        foreach ($key in $InputObject.Keys) {
            $result[$key] = ConvertTo-HashtableDeep $InputObject[$key]
        }
        return $result
    }

    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $result = @{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $result[$property.Name] = ConvertTo-HashtableDeep $property.Value
        }
        return $result
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        $list = New-Object System.Collections.ArrayList
        foreach ($item in $InputObject) { [void]$list.Add((ConvertTo-HashtableDeep $item)) }
        return , $list.ToArray()
    }

    return $InputObject
}

function Load-KitState {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        return ConvertTo-HashtableDeep ($raw | ConvertFrom-Json)
    } catch {
        Write-Warning ('状态文件无法解析，将按首次安装处理：' + $_.Exception.Message)
        return $null
    }
}

function Save-KitState {
    param($State, [string]$Path)

    $State.LastUpdated = (Get-Date).ToString('o')
    $json = $State | ConvertTo-Json -Depth 12
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
    [IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

# ---------------------------------------------------------
#  注册表
# ---------------------------------------------------------

function Get-RegistryKeyObject {
    param([string]$Path)
    return (Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue)
}

function Test-TempHivePath {
    param([string]$Path)
    return ($Path -like 'Registry::HKEY_USERS\AppxKit_*')
}

function ConvertTo-RegExePath {
    param([string]$Path)
    if ($Path -like 'Registry::HKEY_USERS\*') {
        return ('HKU\' + $Path.Substring('Registry::HKEY_USERS\'.Length))
    }
    if ($Path -like 'HKCU:*') { return ('HKCU\' + $Path.Substring('HKCU:'.Length).TrimStart('\')) }
    if ($Path -like 'HKLM:*') { return ('HKLM\' + $Path.Substring('HKLM:'.Length).TrimStart('\')) }
    return $Path
}

function Test-RegistryKey {
    param([string]$Path)

    if (Test-TempHivePath -Path $Path) {
        # 临时配置单元只用 reg.exe 访问：PowerShell 注册表 provider 会持有句柄，
        # 导致随后 reg unload 失败（“拒绝访问”）。
        $result = Invoke-RegExe -Arguments @('query', (ConvertTo-RegExePath -Path $Path))
        return ($result.ExitCode -eq 0)
    }

    return (Test-Path -LiteralPath $Path)
}

function New-RegistryKey {
    param([string]$Path)

    if (Test-TempHivePath -Path $Path) {
        [void](Invoke-RegExe -Arguments @('add', (ConvertTo-RegExePath -Path $Path), '/f'))
        return
    }
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
}

function Get-RegistryValue {
    param([string]$Path, [string]$Name)

    if (Test-TempHivePath -Path $Path) {
        $arguments = @('query', (ConvertTo-RegExePath -Path $Path))
        if ([string]::IsNullOrEmpty($Name)) { $arguments += '/ve' } else { $arguments += @('/v', $Name) }
        $result = Invoke-RegExe -Arguments $arguments
        if ($result.ExitCode -ne 0) { return $null }

        $match = [regex]::Match($result.Output, 'REG_(SZ|EXPAND_SZ|DWORD|QWORD|MULTI_SZ|BINARY)\s+(.+)$')
        if (-not $match.Success) { return $null }

        $value = $match.Groups[2].Value.Trim()
        switch ($match.Groups[1].Value) {
            'DWORD' { return [Convert]::ToInt64(($value -replace '^0x', ''), 16) }
            'QWORD' { return [Convert]::ToInt64(($value -replace '^0x', ''), 16) }
            default { return $value }
        }
    }

    $key = Get-RegistryKeyObject -Path $Path
    if (-not $key) { return $null }
    if ($key.GetValueNames() -contains $Name) {
        return $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    }
    return $null
}

function Set-RegistryValue {
    param(
        [string]$Path,
        [string]$Name,
        $Value,
        [string]$Type = 'String'
    )

    if ($null -eq $Value) {
        Remove-RegistryValue -Path $Path -Name $Name
        return
    }

    if (Test-TempHivePath -Path $Path) {
        $typeName = 'REG_SZ'
        switch ($Type) {
            'DWord' { $typeName = 'REG_DWORD' }
            'QWord' { $typeName = 'REG_QWORD' }
            'ExpandString' { $typeName = 'REG_EXPAND_SZ' }
            'Binary' { $typeName = 'REG_BINARY' }
        }

        $arguments = @('add', (ConvertTo-RegExePath -Path $Path))
        if ([string]::IsNullOrEmpty($Name)) { $arguments += '/ve' } else { $arguments += @('/v', $Name) }
        $arguments += @('/t', $typeName, '/d', [string]$Value, '/f')

        $result = Invoke-RegExe -Arguments $arguments
        if ($result.ExitCode -ne 0) { throw ('写入注册表失败：{0} ({1})' -f $Path, $result.Output) }
        return
    }

    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }

    # 注意：Get-Item 返回的 RegistryKey 句柄是只读的，调用 .SetValue() 会抛
    # “无法写入到注册表”，所以统一走 New-ItemProperty。
    $valueName = if ([string]::IsNullOrEmpty($Name)) { '(default)' } else { $Name }

    $propertyType = 'String'
    switch ($Type) {
        'DWord' { $propertyType = 'DWord' }
        'QWord' { $propertyType = 'QWord' }
        'ExpandString' { $propertyType = 'ExpandString' }
        'Binary' { $propertyType = 'Binary' }
    }

    New-ItemProperty -LiteralPath $Path -Name $valueName -Value $Value -PropertyType $propertyType -Force | Out-Null
}

function Remove-RegistryValue {
    param([string]$Path, [string]$Name)

    if (Test-TempHivePath -Path $Path) {
        $arguments = @('delete', (ConvertTo-RegExePath -Path $Path))
        if ([string]::IsNullOrEmpty($Name)) { $arguments += '/ve' } else { $arguments += @('/v', $Name) }
        $arguments += '/f'
        [void](Invoke-RegExe -Arguments $arguments)
        return
    }

    if (-not (Test-Path -LiteralPath $Path)) { return }
    $valueName = if ([string]::IsNullOrEmpty($Name)) { '(default)' } else { $Name }
    Remove-ItemProperty -LiteralPath $Path -Name $valueName -ErrorAction SilentlyContinue
}

function Get-RegistryDefaultValue {
    param([string]$Path)
    return (Get-RegistryValue -Path $Path -Name '')
}

function Set-RegistryDefaultValue {
    param([string]$Path, $Value)
    Set-RegistryValue -Path $Path -Name '' -Value $Value
}

function Remove-RegistryDefaultValue {
    param([string]$Path)
    Remove-RegistryValue -Path $Path -Name ''
}

function Remove-RegistryKeyIfEmpty {
    param([string]$Path)

    if (Test-TempHivePath -Path $Path) {
        $regPath = ConvertTo-RegExePath -Path $Path
        $result = Invoke-RegExe -Arguments @('query', $regPath)
        if ($result.ExitCode -ne 0) { return }

        # reg query 输出：第一行是键名，之后的值行含 REG_，子键行以键路径开头
        $lines = @($result.Output -split "`r?`n" | Where-Object { $_.Trim() })
        $hasValue = ($lines | Where-Object { $_ -match 'REG_(SZ|EXPAND_SZ|DWORD|QWORD|MULTI_SZ|BINARY)' }).Count -gt 0
        $hasSubKey = ($lines | Where-Object { $_ -match '^HKEY_' -and $_ -notmatch ('^' + [regex]::Escape($regPath) + '$') }).Count -gt 0
        if (-not $hasValue -and -not $hasSubKey) {
            [void](Invoke-RegExe -Arguments @('delete', $regPath, '/f'))
        }
        return
    }

    $key = Get-RegistryKeyObject -Path $Path
    if (-not $key) { return }
    if ($key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------
#  用户配置单元（NTUSER.DAT）
# ---------------------------------------------------------

function Get-UserProfileList {
    Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue |
        Where-Object {
            -not $_.Special -and
            $_.LocalPath -and
            (Test-Path -LiteralPath (Join-Path $_.LocalPath 'NTUSER.DAT'))
        } |
        ForEach-Object {
            [PSCustomObject]@{
                Sid  = $_.SID
                Path = $_.LocalPath
            }
        }
}

function Invoke-RegExe {
    param([string[]]$Arguments)

    # $ErrorActionPreference = 'Stop' 时，原生命令的 stderr 重定向会产生
    # NativeCommandError 并直接抛出，因此这里临时放宽策略。
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & reg.exe @Arguments 2>&1
        return [PSCustomObject]@{
            ExitCode = $LASTEXITCODE
            Output   = (($output | ForEach-Object { $_.ToString() }) -join ' ').Trim()
        }
    } finally {
        $ErrorActionPreference = $previous
    }
}

function Open-UserHive {
    param([string]$Sid, [string]$ProfilePath)

    # 使用 Registry::HKEY_USERS\... 而不是 HKU:\...：
    # Windows PowerShell 5.1 默认没有 HKU: 驱动器。
    $loadedRoot = 'Registry::HKEY_USERS\' + $Sid
    if (Test-RegistryKey -Path $loadedRoot) {
        return @{ Root = $loadedRoot; Temporary = $false; Name = $Sid }
    }

    $tempName = 'AppxKit_' + ($Sid -replace '[^0-9A-Za-z]', '_')
    $tempRoot = 'Registry::HKEY_USERS\' + $tempName
    if (Test-RegistryKey -Path $tempRoot) {
        [void](Invoke-RegExe -Arguments @('unload', ('HKU\' + $tempName)))
    }

    $datFile = Join-Path $ProfilePath 'NTUSER.DAT'
    $result = Invoke-RegExe -Arguments @('load', ('HKU\' + $tempName), $datFile)
    if ($result.ExitCode -ne 0) {
        throw ('无法加载用户配置单元 {0}：{1}' -f $datFile, $result.Output)
    }
    return @{ Root = $tempRoot; Temporary = $true; Name = $tempName }
}

function Open-DefaultHive {
    $tempName = 'AppxKit_Default'
    $root = 'Registry::HKEY_USERS\' + $tempName
    if (Test-RegistryKey -Path $root) {
        [void](Invoke-RegExe -Arguments @('unload', ('HKU\' + $tempName)))
    }

    $datFile = Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT'
    if (-not (Test-Path -LiteralPath $datFile)) { throw ('找不到默认用户配置单元：' + $datFile) }

    $result = Invoke-RegExe -Arguments @('load', ('HKU\' + $tempName), $datFile)
    if ($result.ExitCode -ne 0) {
        throw ('无法加载默认用户配置单元：' + $result.Output)
    }
    return @{ Root = $root; Temporary = $true; Name = $tempName }
}

function Close-UserHive {
    param($Hive)

    if (-not $Hive) { return }
    if (-not $Hive.Temporary) { return }

    # PowerShell 的注册表 provider 可能还持有句柄，重试几次再放弃。
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        $result = Invoke-RegExe -Arguments @('unload', ('HKU\' + $Hive.Name))
        if ($result.ExitCode -eq 0) { return }
        Start-Sleep -Milliseconds 300
    }
    Write-Warning ('配置单元 {0} 暂时无法卸载，重启后会自行释放：{1}' -f $Hive.Name, $result.Output)
}

# ---------------------------------------------------------
#  开始菜单快捷方式
# ---------------------------------------------------------

function Get-ShortcutDirs {
    $result = New-Object System.Collections.Generic.List[string]
    $result.Add((Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Windows PowerShell'))

    Get-ChildItem -LiteralPath (Join-Path $env:SystemDrive 'Users') -Directory -Force -ErrorAction SilentlyContinue |
        ForEach-Object {
            # C:\Users\Default User 是指向 Default 的联接，跳过以免重复处理
            if ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) { return }
            $result.Add((Join-Path $_.FullName 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Windows PowerShell'))
        }

    return ($result | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -Unique)
}

function Get-ShortcutInfo {
    param([string]$Path)

    $shell = New-Object -ComObject WScript.Shell
    try {
        $shortcut = $shell.CreateShortcut($Path)
        return [PSCustomObject]@{
            TargetPath       = $shortcut.TargetPath
            Arguments        = $shortcut.Arguments
            WorkingDirectory = $shortcut.WorkingDirectory
            IconLocation     = $shortcut.IconLocation
            Description      = $shortcut.Description
        }
    } finally {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
}

function Set-ShortcutPowerShell7 {
    param([string]$Path)

    $shell = New-Object -ComObject WScript.Shell
    try {
        $shortcut = $shell.CreateShortcut($Path)
        # 用环境变量而不是绝对路径：Default 模板会被每个新用户使用，
        # 而 WindowsApps 别名是随用户创建的，包升级后也保持不变。
        $shortcut.TargetPath = '%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe'
        $shortcut.Arguments = ''
        $shortcut.WorkingDirectory = '%USERPROFILE%'
        $shortcut.Save()
    } finally {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
}

function Restore-Shortcut {
    param([string]$Path, $Info, [switch]$KeepBackup)

    if ($Info -and $Info.Backup -and (Test-Path -LiteralPath $Info.Backup)) {
        Copy-Item -LiteralPath $Info.Backup -Destination $Path -Force
        if (-not $KeepBackup) { Remove-Item -LiteralPath $Info.Backup -Force -ErrorAction SilentlyContinue }
        return
    }

    if (-not $Info) { return }

    $shell = New-Object -ComObject WScript.Shell
    try {
        $shortcut = $shell.CreateShortcut($Path)
        if ($Info.TargetPath) { $shortcut.TargetPath = $Info.TargetPath }
        $shortcut.Arguments = [string]$Info.Arguments
        $shortcut.WorkingDirectory = [string]$Info.WorkingDirectory
        if ($Info.IconLocation) { $shortcut.IconLocation = $Info.IconLocation }
        if ($Info.Description) { $shortcut.Description = $Info.Description }
        $shortcut.Save()
    } finally {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
}

# ---------------------------------------------------------
#  PATH
# ---------------------------------------------------------

function Remove-LegacyPowerShellPathEntry {
    param([string]$Value)

    $removed = New-Object System.Collections.Generic.List[string]
    $kept = New-Object System.Collections.Generic.List[string]

    foreach ($entry in ($Value -split ';')) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        if ($entry -match '(?i)WindowsPowerShell\\v1\.0') {
            $removed.Add($entry)
        } else {
            $kept.Add($entry)
        }
    }

    return [PSCustomObject]@{
        Value   = ($kept -join ';')
        Removed = $removed.ToArray()
    }
}

function Add-PathEntriesIfMissing {
    param([string]$Value, [string[]]$Entries)

    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($entry in ($Value -split ';')) {
        if (-not [string]::IsNullOrWhiteSpace($entry)) { $parts.Add($entry) }
    }

    foreach ($entry in $Entries) {
        if (-not $entry) { continue }
        $exists = $false
        foreach ($part in $parts) {
            if ($part -ieq $entry) { $exists = $true; break }
        }
        if (-not $exists) { $parts.Add($entry) }
    }

    return ($parts -join ';')
}

function Get-EnvironmentPathValue {
    param([ValidateSet('User', 'Machine')][string]$Scope)

    # 直接读注册表原值：GetEnvironmentVariable 会展开 %SystemRoot% 等变量，
    # 写回时就把它们变成了绝对路径。
    $keyPath = if ($Scope -eq 'Machine') {
        'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
    } else {
        'HKCU:\Environment'
    }

    $key = Get-RegistryKeyObject -Path $keyPath
    if (-not $key) { return $null }
    if ($key.GetValueNames() -notcontains 'Path') { return $null }
    return $key.GetValue('Path', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
}

function Set-EnvironmentPathValue {
    param([ValidateSet('User', 'Machine')][string]$Scope, [string]$Value)

    $keyPath = if ($Scope -eq 'Machine') {
        'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
    } else {
        'HKCU:\Environment'
    }

    if (-not (Test-Path -LiteralPath $keyPath)) { New-Item -Path $keyPath -Force | Out-Null }
    New-ItemProperty -LiteralPath $keyPath -Name 'Path' -Value $Value -PropertyType ExpandString -Force | Out-Null
    Update-EnvironmentBroadcast
}

function Update-EnvironmentBroadcast {
    # 通知资源管理器等已运行的程序环境变量变了
    try {
        if (-not ('KitWin32.NativeMethods' -as [type])) {
            Add-Type -Namespace KitWin32 -Name NativeMethods -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Auto)]
public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint Msg, System.UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out System.UIntPtr lpdwResult);
'@ -ErrorAction Stop
        }
        $result = [UIntPtr]::Zero
        [void][KitWin32.NativeMethods]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result)
    } catch { }
}

# ---------------------------------------------------------
#  文件关联
# ---------------------------------------------------------

function Register-KitAssociations {
    param(
        $State,
        [string]$HandlerPath
    )

    $command = '"{0}" -NoLogo -NoProfile -File "{1}" "%1"' -f '%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe', $HandlerPath

    $hives = @(
        @{ Id = 'HKCU'; Base = 'HKCU:\Software\Classes'; Machine = $false },
        @{ Id = 'HKLM'; Base = 'HKLM:\SOFTWARE\Classes'; Machine = $true }
    )

    foreach ($hive in $hives) {
        if ($hive.Machine -and -not (Test-IsAdministrator)) { continue }

        if (-not $State.Associations.ContainsKey($hive.Id) -or $State.Associations[$hive.Id] -isnot [System.Collections.IDictionary]) {
            $State.Associations[$hive.Id] = @{}
        }
        $hiveState = $State.Associations[$hive.Id]

        $progPath = Join-Path $hive.Base $Kit.ProgId
        if (-not $hiveState.ContainsKey('__progid')) {
            $hiveState['__progid'] = @{ Existed = (Test-RegistryKey -Path $progPath) }
        }

        New-Item -Path (Join-Path $progPath 'shell\open\command') -Force | Out-Null
        New-Item -Path (Join-Path $progPath 'DefaultIcon') -Force | Out-Null
        Set-RegistryDefaultValue -Path $progPath -Value 'Appx / MSIX 安装程序'
        Set-RegistryDefaultValue -Path (Join-Path $progPath 'DefaultIcon') -Value "$env:SystemRoot\System32\shell32.dll,163"
        Set-RegistryDefaultValue -Path (Join-Path $progPath 'shell\open\command') -Value $command

        foreach ($ext in $Kit.Extensions) {
            $extPath = Join-Path $hive.Base $ext
            if (-not $hiveState.ContainsKey($ext)) {
                $hiveState[$ext] = @{
                    Existed       = (Test-RegistryKey -Path $extPath)
                    Default       = (Get-RegistryDefaultValue -Path $extPath)
                    ContentType   = (Get-RegistryValue -Path $extPath -Name 'Content Type')
                    PerceivedType = (Get-RegistryValue -Path $extPath -Name 'PerceivedType')
                }
            }
            New-Item -Path $extPath -Force | Out-Null
            Set-RegistryDefaultValue -Path $extPath -Value $Kit.ProgId
            Set-RegistryValue -Path $extPath -Name 'Content Type' -Value 'application/octet-stream'
            Set-RegistryValue -Path $extPath -Name 'PerceivedType' -Value 'document'
        }
    }

    # 不写 FileExts\...\UserChoice：Windows 会校验其中的 Hash，而该算法在不同
    # Windows 版本上并不一致，写入无效哈希反而会让系统把默认应用重置掉。
    # 只写 ProgId 与扩展名的默认处理程序；没有 UserChoice 时，资源管理器会使用
    # 这里的关联，效果相同（详见 README）。

    $State.Associations.Registered = $true
}

function Unregister-KitAssociations {
    param($State)

    # 安装时用了 -NoAssociations 的话，状态文件里 Registered = false，这里不应动系统里的关联
    if ($State -and $State.Associations -and $State.Associations.ContainsKey('Registered') -and -not $State.Associations.Registered) {
        Write-Host '状态文件显示安装时未注册文件关联，跳过。'
        return
    }

    $hives = @(
        @{ Id = 'HKCU'; Base = 'HKCU:\Software\Classes'; Machine = $false },
        @{ Id = 'HKLM'; Base = 'HKLM:\SOFTWARE\Classes'; Machine = $true }
    )

    foreach ($hive in $hives) {
        if ($hive.Machine -and -not (Test-IsAdministrator)) { continue }

        $hiveState = $null
        if ($State -and $State.Associations -and $State.Associations[$hive.Id]) {
            $hiveState = $State.Associations[$hive.Id]
        }

        $progPath = Join-Path $hive.Base $Kit.ProgId
        $progRecord = $null
        if ($hiveState -and $hiveState.ContainsKey('__progid')) {
            $progRecord = $hiveState['__progid']
        }

        if ($progRecord -and $progRecord.Existed) {
            # 安装前就存在的 ProgId：只清掉我们写的内容
            Remove-RegistryDefaultValue -Path $progPath
            Remove-RegistryValue -Path (Join-Path $progPath 'DefaultIcon') -Name ''
            Remove-RegistryValue -Path (Join-Path $progPath 'shell\open\command') -Name ''
        } else {
            if (Test-Path -LiteralPath $progPath) { Remove-Item -LiteralPath $progPath -Recurse -Force -ErrorAction SilentlyContinue }
        }

        foreach ($ext in $Kit.Extensions) {
            $extPath = Join-Path $hive.Base $ext
            $record = $null
            if ($hiveState -and $hiveState.ContainsKey($ext)) {
                $record = $hiveState[$ext]
            }

            if ($record) {
                if ($record.Existed) {
                    if ($record.Default) { Set-RegistryDefaultValue -Path $extPath -Value $record.Default }
                    else { Remove-RegistryDefaultValue -Path $extPath }

                    if ($record.ContentType) { Set-RegistryValue -Path $extPath -Name 'Content Type' -Value $record.ContentType }
                    else { Remove-RegistryValue -Path $extPath -Name 'Content Type' }

                    if ($record.PerceivedType) { Set-RegistryValue -Path $extPath -Name 'PerceivedType' -Value $record.PerceivedType }
                    else { Remove-RegistryValue -Path $extPath -Name 'PerceivedType' }
                } else {
                    if (Test-Path -LiteralPath $extPath) { Remove-Item -LiteralPath $extPath -Recurse -Force -ErrorAction SilentlyContinue }
                }
            } else {
                # 没有状态文件时按值判断：只清掉指向本套件的设置
                if ((Get-RegistryDefaultValue -Path $extPath) -eq $Kit.ProgId) { Remove-RegistryDefaultValue -Path $extPath }
                if ((Get-RegistryValue -Path $extPath -Name 'Content Type') -eq 'application/octet-stream') {
                    Remove-RegistryValue -Path $extPath -Name 'Content Type'
                }
                if ((Get-RegistryValue -Path $extPath -Name 'PerceivedType') -eq 'document') {
                    Remove-RegistryValue -Path $extPath -Name 'PerceivedType'
                }
            }
        }
    }

    foreach ($ext in $Kit.Extensions) {
        $userChoicePath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\' + $ext + '\UserChoice'
        $current = Get-RegistryValue -Path $userChoicePath -Name 'ProgId'
        if ($current -ne $Kit.ProgId) { continue }

        $record = $null
        if ($State -and $State.Associations -and $State.Associations.UserChoice -and $State.Associations.UserChoice.ContainsKey($ext)) {
            $record = $State.Associations.UserChoice[$ext]
        }

        if ($record -and $record.Existed -and $record.ProgId) {
            Set-RegistryValue -Path $userChoicePath -Name 'ProgId' -Value $record.ProgId
            if ($record.Hash) { Set-RegistryValue -Path $userChoicePath -Name 'Hash' -Value $record.Hash }
        } else {
            Remove-Item -LiteralPath $userChoicePath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-AppxFileVersion {
    param([string]$Path)

    # 从清单里读版本号，用于和已安装版本比较。
    # 注意：bundle 的 Identity/@Version 是“包捆绑版本”（例如 2026.1010.44.0），
    # 不是应用版本；必须取 bundle 内 Type="application" 的 Package/@Version。
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try {
            $singleEntry = $zip.GetEntry('AppxManifest.xml')
            if ($singleEntry) {
                $reader = New-Object System.IO.StreamReader($singleEntry.Open())
                try { $xml = [xml]$reader.ReadToEnd() } finally { $reader.Dispose() }
                $identity = $xml.SelectSingleNode("//*[local-name()='Identity']")
                if ($identity -and $identity.Version) { return [version]$identity.Version }
                return $null
            }

            $bundleEntry = $zip.Entries |
                Where-Object { $_.FullName -match '(?i)(^|/)AppxBundleManifest\.xml$' } |
                Select-Object -First 1
            if (-not $bundleEntry) { return $null }

            $reader = New-Object System.IO.StreamReader($bundleEntry.Open())
            try { $xml = [xml]$reader.ReadToEnd() } finally { $reader.Dispose() }

            $arch = $env:PROCESSOR_ARCHITECTURE
            if ($arch -eq 'AMD64') { $arch = 'x64' }
            if ($arch -eq 'ARM64') { $arch = 'arm64' }
            if ($arch -eq 'x86') { $arch = 'x86' }

            $candidates = @($xml.SelectNodes("//*[local-name()='Package' and @Type='application']"))
            $match = $candidates | Where-Object { $_.Architecture -eq $arch } | Select-Object -First 1
            if (-not $match) { $match = $candidates | Where-Object { $_.Architecture -eq 'neutral' } | Select-Object -First 1 }
            if (-not $match) { $match = $candidates | Select-Object -First 1 }
            if ($match -and $match.Version) { return [version]$match.Version }
            return $null
        } finally { $zip.Dispose() }
    } catch { }
    return $null
}

# ---------------------------------------------------------
#  状态报告
# ---------------------------------------------------------

function Show-KitStatus {
    Write-Host ''
    Write-Host '================= 当前状态 =================' -ForegroundColor Cyan

    $admin = Test-IsAdministrator
    Write-Host ('管理员权限        : ' + $(if ($admin) { '是' } else { '否' }))

    $ps = Get-AppxPackage -Name 'Microsoft.PowerShell' -ErrorAction SilentlyContinue | Select-Object -First 1
    $wt = Get-AppxPackage -Name 'Microsoft.WindowsTerminal' -ErrorAction SilentlyContinue | Select-Object -First 1
    Write-Host ('PowerShell 7      : ' + $(if ($ps) { $ps.Version.ToString() } else { '未安装' }))
    Write-Host ('Windows Terminal  : ' + $(if ($wt) { $wt.Version.ToString() } else { '未安装' }))

    if ($admin) {
        try {
            $provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop |
                Where-Object { $_.DisplayName -match 'PowerShell|WindowsTerminal' })
            $text = '否'
            if ($provisioned.Count -gt 0) {
                $text = ($provisioned | ForEach-Object { $_.DisplayName + ' ' + $_.Version }) -join '; '
            }
            Write-Host ('已预配给所有用户  : ' + $text)
        } catch { }
    }

    $total = 0
    $toPwsh = 0
    foreach ($dir in @(Get-ShortcutDirs)) {
        foreach ($name in $Kit.ShortcutNames) {
            $path = Join-Path $dir $name
            if (Test-Path -LiteralPath $path) {
                $total++
                if ((Get-ShortcutInfo -Path $path).TargetPath -match 'pwsh\.exe') { $toPwsh++ }
            }
        }
    }
    Write-Host ('开始菜单快捷方式  : {0}/{1} 指向 pwsh' -f $toPwsh, $total)

    $hidden = 0
    foreach ($rel in $Kit.ContextMenuKeys) {
        if ((Get-RegistryValue -Path ('HKCU:\' + $rel) -Name 'HideBasedOnVelocityId') -eq $Kit.HideValue) { $hidden++ }
    }
    Write-Host ('右键菜单已隐藏    : {0}/{1}' -f $hidden, $Kit.ContextMenuKeys.Count)

    $console = Get-RegistryValue -Path 'HKCU:\Console\%%Startup' -Name 'DelegationConsole'
    $terminal = Get-RegistryValue -Path 'HKCU:\Console\%%Startup' -Name 'DelegationTerminal'
    $isTerminal = ($console -eq $Kit.ConsoleGuid -and $terminal -eq $Kit.TerminalGuid)
    Write-Host ('默认终端          : ' + $(if ($isTerminal) { 'Windows Terminal' } else { '未设置 / 其他' }))

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    Write-Host ('用户 PATH 含 v1.0 : ' + $(if ($userPath -match '(?i)WindowsPowerShell\\v1\.0') { '是' } else { '否' }))
    Write-Host ('系统 PATH 含 v1.0 : ' + $(if ($machinePath -match '(?i)WindowsPowerShell\\v1\.0') { '是' } else { '否' }))

    $assoc = Get-RegistryDefaultValue -Path 'HKCU:\Software\Classes\.msix'
    $userChoice = Get-RegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.msix\UserChoice' -Name 'ProgId'
    $assocOk = ($assoc -eq $Kit.ProgId -or $userChoice -eq $Kit.ProgId)
    Write-Host ('包文件关联        : ' + $(if ($assocOk) { '已关联到 Install-Appx.ps1' } else { '未关联' }))

    Write-Host '============================================' -ForegroundColor Cyan
    Write-Host ''
}
