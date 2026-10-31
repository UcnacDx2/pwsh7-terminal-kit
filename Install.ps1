#Requires -Version 5.1
<#
.SYNOPSIS
    一键把 Windows Terminal + PowerShell 7 配置成系统的默认终端与默认 Shell。

.DESCRIPTION
    本脚本会做以下事情，每一项都可以由 Uninstall.ps1 精确回滚：

      1. 安装 PowerShell 7 (MSIX) 与 Windows Terminal (MSIX)。
         不带参数运行时优先使用脚本目录里已有的本地包（免联网），
         支持 OEM 预安装包（*PreinstallKit.zip，自动解压并先安装
         UI.Xaml / VCLibs 等依赖框架）；本地没有才联网下载。
      2. 把两个包预配给所有用户（新用户登录后自动拥有），
         并自动检查、修复 pwsh.exe / wt.exe 执行别名
      3. 开始菜单里的 "Windows PowerShell" / "Windows PowerShell (x86)"
         全部改指向 pwsh 7，原快捷方式备份为 .lnk.bak
      4. 隐藏 Shift + 右键菜单中的 "在此处打开 PowerShell 窗口"
      5. 把默认终端（控制台主机）设置为 Windows Terminal
      6. 从用户 PATH 与系统 PATH 中移除 WindowsPowerShell\v1.0
      7. 安装 powershell.exe 转发器：把 powershell 这个名字重新交回系统，
         但指向 pwsh 7，装在 Program Files 并置于机器 PATH 最前。
         这样 Node/Go 等直接 CreateProcess("powershell") 的调用方不会
         再拿到 ENOENT（System32 下并没有 powershell.exe）
      8. 把 .msix / .msixbundle / .appx / .appxbundle / .appinstaller
         关联到本套件自带的 Install-Appx.ps1

    系统自带的 powershell.exe 文件（System32 与 SysWOW64）不做任何改动。

.PARAMETER PowerShellPackage
    PowerShell 7 包（.msixbundle）的本地路径。省略则自动下载。

.PARAMETER TerminalPackage
    Windows Terminal 包的本地路径：.msix / .msixbundle，或 OEM 预安装包
    *PreinstallKit.zip（会自动解压）。省略则优先用脚本目录里已有的包。

.PARAMETER NoProvision
    不为所有用户预配，只给当前用户安装。

.PARAMETER NoAssociations
    不注册 .msix / .appx 文件关联。

.PARAMETER KeepWindowsPowerShellPath
    保留 PATH 中的 WindowsPowerShell\v1.0。
    同时会跳过 powershell.exe 转发器（因为转发器会把 powershell
    这个名字抢过来指向 pwsh 7，与"保留 5.1"的意图冲突）。

.PARAMETER NoPowerShellShim
    不安装 powershell.exe 转发器。安装后 powershell 这个名字将
    无法解析（和旧版套件的行为一致）。

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
    [switch]$NoPowerShellShim,
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

# 下载源按顺序尝试，前一个失败自动换下一个。
# github.com 在部分网络下直连不通，所以这里只放可用的镜像（实测见 README）。
$PowerShellUrls = @(
    'https://cdn.akaere.online/https://github.com/PowerShell/PowerShell/releases/download/v7.6.7/PowerShell-7.6.7.msixbundle',
    'https://ghfast.top/https://github.com/PowerShell/PowerShell/releases/download/v7.6.7/PowerShell-7.6.7.msixbundle'
)
$PowerShellFileName = 'PowerShell-7.6.7.msixbundle'
$TerminalUrls = @(
    'https://cdn.akaere.online/https://github.com/microsoft/terminal/releases/download/v1.25.2733.0/Microsoft.WindowsTerminal_1.25.2733.0_8wekyb3d8bbwe.msixbundle',
    'https://ghfast.top/https://github.com/microsoft/terminal/releases/download/v1.25.2733.0/Microsoft.WindowsTerminal_1.25.2733.0_8wekyb3d8bbwe.msixbundle'
)
$TerminalFileName = 'Microsoft.WindowsTerminal_1.25.2733.0_8wekyb3d8bbwe.msixbundle'

function Test-KitDownloadedPackage {
    param([string]$Path)

    # 下载完成的包必须能读出清单，否则视为断流产生的残缺文件。
    # 之前正是这种残缺文件留在缓存里，导致后续每次运行都在几秒内失败。
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    if ((Get-Item -LiteralPath $Path).Length -lt 1MB) { return $false }
    return ($null -ne (Get-AppxFileVersion -Path $Path))
}

function Resolve-KitPackage {
    param([string]$Path, [string[]]$Urls, [string]$FileName, [string]$Label, [string[]]$LocalPatterns)

    if ($Path) {
        # zip（OEM 预安装包）原样返回，由调用方解压处理
        if (-not (Test-Path -LiteralPath $Path)) { throw ($Label + ' 包不存在：' + $Path) }
        return (Resolve-Path -LiteralPath $Path).Path
    }

    # 1) 优先使用脚本目录里已有的本地包（免联网）
    if ($LocalPatterns) {
        foreach ($pattern in $LocalPatterns) {
            $local = Find-KitLocalPackage -Pattern $pattern
            if ($local) {
                Write-Host ('使用本地 ' + $Label + ' 包：' + (Split-Path -Leaf $local)) -ForegroundColor DarkGray
                return $local
            }
        }
    }

    # 2) 之前下载过的缓存（残缺的一律丢弃重下）
    $cached = Join-Path $CacheRoot $FileName
    if (Test-Path -LiteralPath $cached) {
        if (Test-KitDownloadedPackage -Path $cached) { return $cached }
        Write-Host ('缓存中的 ' + $Label + ' 包不完整，已删除并重新下载。') -ForegroundColor Yellow
        Remove-Item -LiteralPath $cached -Force
    }

    # 3) 依次尝试各个下载源
    New-Item -ItemType Directory -Force -Path $CacheRoot | Out-Null
    foreach ($url in $Urls) {
        Write-Host ('正在下载 ' + $Label + ' ...')
        try {
            Invoke-WebRequest -Uri $url -OutFile $cached -UseBasicParsing -ErrorAction Stop
        } catch {
            if (Test-Path -LiteralPath $cached) { Remove-Item -LiteralPath $cached -Force }
            Write-Host '  HTTP 下载中断，改用 curl 重试...' -ForegroundColor Yellow
            & curl.exe -L --retry 5 --retry-delay 3 --fail --silent --show-error -o $cached $url
            if ($LASTEXITCODE -ne 0) {
                # 失败时必须删掉半截文件，否则下次会被当成有效缓存直接用
                if (Test-Path -LiteralPath $cached) { Remove-Item -LiteralPath $cached -Force }
                Write-Host ('  该下载源不可用，换下一个。') -ForegroundColor Yellow
                continue
            }
        }

        if (Test-KitDownloadedPackage -Path $cached) { return $cached }

        Write-Host '  下载的文件不完整，换下一个下载源。' -ForegroundColor Yellow
        Remove-Item -LiteralPath $cached -Force
    }

    throw ('下载 ' + $Label + ' 失败，已尝试 ' + $Urls.Count + ' 个下载源。请把安装包放到脚本目录后重试，或用对应的本地文件参数。')
}

function Find-KitLocalPackages {
    param([string]$Pattern)

    return @(Get-ChildItem -LiteralPath $PSScriptRoot -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $Pattern } |
        Sort-Object LastWriteTime -Descending |
        ForEach-Object { $_.FullName })
}

function Find-KitLocalPackage {
    param([string]$Pattern)

    $found = @(Find-KitLocalPackages -Pattern $Pattern)
    if ($found.Count -gt 0) { return $found[0] }
    return $null
}

function Expand-KitPreinstallZip {
    param([string]$ZipPath)

    # 解压到缓存目录（卸载时会随 cache 一并清理）
    $target = Join-Path $CacheRoot ('expanded_' + [IO.Path]::GetFileNameWithoutExtension($ZipPath))
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $target -Force

    # 主包 = 解压出的最大的包文件（预安装包里主包远大于依赖框架包）
    $packages = @(Get-ChildItem -LiteralPath $target -Recurse -File |
        Where-Object { $_.Extension -match '(?i)^\.(msixbundle|appxbundle|msix|appx)$' })
    $bundle = @($packages |
        Where-Object { $_.Name -notmatch '(?i)(UI\.Xaml|VCLibs)' } |
        Sort-Object Length -Descending |
        Select-Object -First 1)[0]

    return @{
        Bundle        = $(if ($bundle) { $bundle.FullName } else { $null })
        DependencyDir = $target
    }
}

function Get-KitPackageDependencies {
    param([string]$Path)

    # 读取包清单声明的依赖框架（名称 + 最低版本）
    $result = New-Object System.Collections.Generic.List[object]
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try {
            $manifestEntries = @($zip.Entries |
                Where-Object { $_.FullName -match '(?i)(^|/)(AppxManifest|AppxBundleManifest)\.xml$' })
            foreach ($entry in $manifestEntries) {
                $reader = New-Object System.IO.StreamReader($entry.Open())
                try { $xml = [xml]$reader.ReadToEnd() } finally { $reader.Dispose() }
                foreach ($node in @($xml.SelectNodes("//*[local-name()='PackageDependency']"))) {
                    $name = $node.GetAttribute('Name')
                    $minVersion = $node.GetAttribute('MinVersion')
                    if ($name) {
                        $result.Add([PSCustomObject]@{ Name = $name; MinVersion = $minVersion })
                    }
                }
            }
        } finally { $zip.Dispose() }
    } catch { }

    return @($result | Sort-Object Name, MinVersion -Unique)
}

function Install-KitDependencyPackages {
    param([string]$PackagePath, [string[]]$SearchDirs)

    # 主包安装前先装缺失的依赖框架，避免 “依赖项无法满足” (0x80073CF3)
    $dependencies = Get-KitPackageDependencies -Path $PackagePath
    if (-not $dependencies -or $dependencies.Count -eq 0) { return }

    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($arch -eq 'AMD64') { $arch = 'x64' }
    if ($arch -eq 'ARM64') { $arch = 'arm64' }
    if ($arch -eq 'x86') { $arch = 'x86' }

    foreach ($dep in $dependencies) {
        $installed = Get-AppxPackage -Name $dep.Name -ErrorAction SilentlyContinue |
            Where-Object {
                -not $dep.MinVersion -or
                -not $_.Version -or
                ([version]$_.Version -ge [version]$dep.MinVersion)
            } | Select-Object -First 1
        if ($installed) { continue }

        $file = $null
        foreach ($dir in $SearchDirs) {
            if (-not (Test-Path -LiteralPath $dir)) { continue }
            $candidates = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -match '(?i)^\.(appx|msix)$' -and $_.Name -match ('^' + [regex]::Escape($dep.Name) + '_') })
            if ($candidates.Count -eq 0) { continue }
            $file = @($candidates |
                Where-Object { $_.Name -match ('_' + $arch + '__') } |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1)[0]
            if (-not $file) {
                $file = @($candidates |
                    Sort-Object LastWriteTime -Descending |
                    Select-Object -First 1)[0]
            }
            if ($file) { break }
        }

        if (-not $file) {
            Write-Warning ('依赖 ' + $dep.Name + ' 未安装且本地未找到其框架包，主包安装可能失败。')
            continue
        }

        Write-Host ('安装依赖框架：' + $file.Name)
        try {
            Add-AppxPackage -Path $file.FullName -ErrorAction Stop
        } catch {
            $message = $_.Exception.Message
            if ($message -notmatch '0x80073D06|already installed') {
                Write-Warning ('依赖 ' + $file.Name + ' 安装失败：' + $message)
            }
        }
    }
}

function Test-KitExecutionAlias {
    param(
        [string]$AliasName,
        [int]$TimeoutMs = 15000
    )

    # 实际启动一次别名，验证其可用（而非只看文件是否存在）
    $alias = Join-Path $env:LOCALAPPDATA ('Microsoft\WindowsApps\' + $AliasName)
    if (-not (Test-Path -LiteralPath $alias)) { return $false }

    $arguments = $null
    if ($AliasName -match '^(?i)pwsh') {
        $arguments = @('-NoProfile', '-Command', 'exit 0')
    } elseif ($AliasName -match '^(?i)wt') {
        $arguments = @('--version')
    }

    try {
        # 这里不能用 -Wait：wt.exe --version 在部分机器上会转而激活 Windows
        # Terminal 应用本体，而那个进程长期不退出，-Wait 会把整个安装永久卡死
        # （实测踩到过，日志停在“pwsh.exe 执行别名：正常”之后再无输出）。
        $process = Start-Process -FilePath $alias -ArgumentList $arguments `
            -WindowStyle Hidden -PassThru -ErrorAction Stop
    } catch {
        return $false
    }

    if (-not $process.WaitForExit($TimeoutMs)) {
        try { $process.Kill() } catch { }
        # 进程确实被拉起来了，说明别名本身解析成功、能启动；只是它不肯主动退出。
        Write-Host ('  {0} 在 {1} 秒内没有退出，已停止等待（不视为故障）。' -f $AliasName, [int]($TimeoutMs / 1000)) -ForegroundColor DarkYellow
        return $true
    }

    return ($process.ExitCode -eq 0)
}

function Repair-KitExecutionAlias {
    param([string]$PackageName, [string]$AliasName, [string]$ProcessName)

    $package = Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $package) { return $false }

    # 重注册当前用户包：重建执行别名与 AppX 运行时状态
    $manifest = Join-Path $package.InstallLocation 'AppxManifest.xml'
    try {
        Add-AppxPackage -Register $manifest -DisableDevelopmentMode -ErrorAction Stop
    } catch {
        Write-Host ('  重注册失败：' + $_.Exception.Message) -ForegroundColor DarkYellow
    }

    if (Test-KitExecutionAlias -AliasName $AliasName) { return $true }

    # 触发一次应用激活（部分机器首次需要完成状态转换），随后只关闭新出现的进程
    $appId = $package.PackageFamilyName + '!App'
    $existing = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    try {
        [void](Start-Process ('shell:appsFolder\' + $appId) -ErrorAction SilentlyContinue)
        for ($i = 0; $i -lt 10; $i++) {
            Start-Sleep -Milliseconds 500
            $newProcess = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
                Where-Object { $existing -notcontains $_.Id }
            if ($newProcess) { break }
        }
        Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
            Where-Object { $existing -notcontains $_.Id } |
            Stop-Process -Force -ErrorAction SilentlyContinue
    } catch { }

    return (Test-KitExecutionAlias -AliasName $AliasName)
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
    Write-Step '1/8  安装 PowerShell 7 与 Windows Terminal'
    # ---------------------------------------------------------------
    $psPackagePath = Resolve-KitPackage -Path $PowerShellPackage -Urls $PowerShellUrls -FileName $PowerShellFileName -Label 'PowerShell 7' `
        -LocalPatterns @('(?i)^PowerShell-[\d\.]+\.msixbundle$')
    $wtPackagePath = Resolve-KitPackage -Path $TerminalPackage -Urls $TerminalUrls -FileName $TerminalFileName -Label 'Windows Terminal' `
        -LocalPatterns @(
            '(?i)^Microsoft\.WindowsTerminal[_0-9].*\.(msixbundle|msix)$',
            '(?i)^Microsoft\.WindowsTerminal[_0-9].*PreinstallKit\.zip$'
        )

    # OEM 预安装包（*PreinstallKit.zip）：主包是 zip 时解压出主包；
    # 否则也解压目录里的 zip，作为依赖框架的来源。
    $wtFromZip = $false
    $dependencyDirs = New-Object System.Collections.Generic.List[string]
    [void]$dependencyDirs.Add($PSScriptRoot)
    $zipToExpand = $null
    if ($wtPackagePath -match '(?i)\.zip$') {
        $zipToExpand = $wtPackagePath
    } else {
        $zipToExpand = Find-KitLocalPackage -Pattern '(?i)^Microsoft\.WindowsTerminal[_0-9].*PreinstallKit\.zip$'
    }
    if ($zipToExpand) {
        Write-Host ('解压 OEM 预安装包：' + (Split-Path -Leaf $zipToExpand))
        $expanded = Expand-KitPreinstallZip -ZipPath $zipToExpand
        if ($expanded.DependencyDir) { [void]$dependencyDirs.Add($expanded.DependencyDir) }
        if ($wtPackagePath -match '(?i)\.zip$') {
            if (-not $expanded.Bundle) { throw ('预安装包内未找到 Windows Terminal 主包：' + $zipToExpand) }
            $wtPackagePath = $expanded.Bundle
            $wtFromZip = $true
        }
    }

    if (-not $SkipSignatureCheck) {
        Assert-KitSignature -Path $psPackagePath -Label 'PowerShell 7'
        if ($wtFromZip) {
            Write-Host 'Windows Terminal 来自 OEM 预安装包：跳过本地签名预检（Add-AppxPackage 安装时会强制验证包签名）。' -ForegroundColor DarkGray
        } else {
            Assert-KitSignature -Path $wtPackagePath -Label 'Windows Terminal'
        }
    }

    # 先装主包依赖的框架包（UI.Xaml / VCLibs 等），避免主包安装报依赖缺失
    Install-KitDependencyPackages -PackagePath $wtPackagePath -SearchDirs ($dependencyDirs.ToArray())
    Install-KitDependencyPackages -PackagePath $psPackagePath -SearchDirs ($dependencyDirs.ToArray())

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
    Write-Step '2/8  预配给所有用户'
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

    # 预配会把当前用户的应用状态打回“已暂存”，导致 pwsh.exe / wt.exe
    # 执行别名报“找不到可用的应用程序证书”。主动检查，坏了就修复。
    foreach ($aliasTarget in @(
            @{ PackageName = 'Microsoft.PowerShell'; Alias = 'pwsh.exe'; ProcessName = 'pwsh'; Label = 'pwsh.exe' },
            @{ PackageName = 'Microsoft.WindowsTerminal'; Alias = 'wt.exe'; ProcessName = 'WindowsTerminal'; Label = 'wt.exe' })) {
        if (Test-KitExecutionAlias -AliasName $aliasTarget.Alias) {
            Write-Host ($aliasTarget.Label + ' 执行别名：正常') -ForegroundColor DarkGray
        } elseif (Repair-KitExecutionAlias -PackageName $aliasTarget.PackageName -AliasName $aliasTarget.Alias -ProcessName $aliasTarget.ProcessName) {
            Write-Host ($aliasTarget.Label + ' 执行别名：已修复') -ForegroundColor Green
        } else {
            Write-Warning ($aliasTarget.Label + ' 执行别名仍无法启动，可重启系统后再试。')
        }
    }

    # ---------------------------------------------------------------
    Write-Step '3/8  重定向开始菜单的 Windows PowerShell 快捷方式'
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
        Write-Step '4/8  隐藏 Shift + 右键的 PowerShell 菜单项'
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
        Write-Step '5/8  设置 Windows Terminal 为默认终端'
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
    Write-Step '6/8  从 PATH 中移除 WindowsPowerShell\v1.0'
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
    Write-Step '7/8  安装 powershell.exe 转发器（指向 pwsh 7）'
    # ---------------------------------------------------------------
    # 第 6 步把 WindowsPowerShell\v1.0 从 PATH 移除后，powershell 这个名字
    # 就彻底解析不出来了 —— System32 下并没有 powershell.exe。凡是直接
    # CreateProcess("powershell", ...) 的调用方都会拿到 ENOENT：
    # Node 的 execFileSync/spawn、Go 的 exec.Command、计划任务、服务等等。
    # 这里用一个真正的 .exe 转发器把名字还回去，但指向 pwsh 7。
    if ($NoPowerShellShim) {
        Write-Host '已跳过（-NoPowerShellShim）。'
    } elseif ($KeepWindowsPowerShellPath) {
        Write-Host '已跳过：保留了 WindowsPowerShell\v1.0，powershell 仍指向 5.1。' -ForegroundColor DarkGray
    } else {
        $shimExe = Install-PowerShellShim -State $state
        $check = Test-PowerShellShim
        if ($check.Ok) {
            Write-Host ('转发器自检通过：powershell ' + $check.Detail) -ForegroundColor Green
        } else {
            Write-Warning ('转发器自检未通过：' + $check.Detail)
            Write-Warning 'powershell 这个名字可能仍然不可用；如不需要可加 -NoPowerShellShim 跳过。'
        }

        # 这一条才是调用方真正走的路：Node 的 execFileSync、Go 的 exec.Command
        # 都不查 PATHEXT，只按名字找 exe。上面那个自检是拿完整路径调的，
        # 名字解析不出来它也照样报通过，所以必须单独测一次。
        $resolve = Test-ShimNameResolution
        if ($resolve.Ok) {
            Write-Host ('新进程里按名字解析：通过（powershell -> pwsh 7，' + $resolve.Detail + '）') -ForegroundColor Green
        } else {
            Write-Warning ('新进程里按名字解析失败：' + $resolve.Detail)
        }

        # 必须提前说清楚，否则会被当成「没装好」：PATH 是进程启动时的一份
        # 快照，改注册表 + 广播 WM_SETTINGCHANGE 只对之后新起的进程有效。
        Write-Host '提示：已经在运行的进程仍持有旧的 PATH 快照（包括打开本脚本的这个窗口），' -ForegroundColor DarkYellow
        Write-Host '      要等重启该程序、或注销重新登录一次，它才能看到这个名字。' -ForegroundColor DarkYellow
    }

    # ---------------------------------------------------------------
    Write-Step '8/8  注册 .msix / .appx 文件关联'
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
