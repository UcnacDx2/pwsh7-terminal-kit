# ============================================================
#  powershell.exe 转发器自检
#
#  会临时安装转发器（写 Program Files + 改系统 PATH），跑完自动卸载还原。
#  任何一步失败或中途 Ctrl-C，finally 里都会回滚，不留半装状态。
#
#  核心手法是「差分对照」：把同一份原始命令行分别喂给转发器和喂给它
#  应该转发到的那个真实 exe，比较 stdout / stderr / 退出码。与真实 exe
#  逐字节一致，才算转发是保真的 —— 只检查「跑起来了」会漏掉静默错误。
#
#  用法（必须用 Windows PowerShell 5.1 跑，管理员身份）：
#      powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Shim.ps1
# ============================================================
#Requires -Version 5.1

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

. (Join-Path $PSScriptRoot 'lib\Common.ps1')

if (-not (Test-IsAdministrator)) {
    Write-Host '需要管理员权限（要写 C:\Program Files 和系统 PATH）。' -ForegroundColor Red
    exit 1
}

$state = New-KitState
$legacy = Get-WindowsPowerShellPath
$directPwsh = (Get-Command pwsh -ErrorAction Stop).Source

function Invoke-Capture {
    # Arguments 原样作为命令行传给进程 —— .NET 不再加引号，
    # 所以两条路径拿到逐字节相同的命令行，差异只可能来自转发器本身。
    param([string]$Exe, [string]$Arguments, [string]$StdIn = $null)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = ($null -ne $StdIn)

    $process = [System.Diagnostics.Process]::Start($psi)
    if ($null -ne $StdIn) {
        $process.StandardInput.Write($StdIn)
        $process.StandardInput.Close()
    }
    $out = $process.StandardOutput.ReadToEnd()
    $err = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    return [PSCustomObject]@{
        ExitCode = $process.ExitCode
        StdOut   = $out
        StdErr   = $err
    }
}

$script:failures = 0

function Compare-Pair {
    # $ExpectExe 是「正确答案」：转发器本来就应该转发到的那个 exe
    param([string]$Label, [string]$ShimExe, [string]$ExpectExe, [string]$Arguments, [string]$StdIn = $null)

    $actual = Invoke-Capture -Exe $ShimExe -Arguments $Arguments -StdIn $StdIn
    $expect = Invoke-Capture -Exe $ExpectExe -Arguments $Arguments -StdIn $StdIn

    $ok = ($actual.ExitCode -eq $expect.ExitCode) -and
          ($actual.StdOut -eq $expect.StdOut) -and
          ($actual.StdErr -eq $expect.StdErr)

    Write-Host ("  [{0}] {1}" -f $(if ($ok) { '一致  ' } else { '不一致' }), $Label) `
        -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
    if (-not $ok) {
        Write-Host ('        转发器: exit=' + $actual.ExitCode + ' out=[' + ($actual.StdOut -replace "`r?`n", '\n') + '] err=[' + (($actual.StdErr -split "`r?`n")[0]) + ']')
        Write-Host ('        直接调: exit=' + $expect.ExitCode + ' out=[' + ($expect.StdOut -replace "`r?`n", '\n') + '] err=[' + (($expect.StdErr -split "`r?`n")[0]) + ']')
    }
    if (-not $ok) { $script:failures++ }
}

function Assert-Equal {
    param([string]$Label, $Actual, $Expected)

    $ok = ($Actual -eq $Expected)
    Write-Host ("  [{0}] {1}" -f $(if ($ok) { '通过  ' } else { '失败  ' }), $Label) `
        -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
    if (-not $ok) {
        Write-Host ('        实际=' + $Actual + '  期望=' + $Expected)
        $script:failures++
    }
}

$shimInstalled = $false
$spaceDir = Join-Path $env:TEMP 'pwsh-shim-test-dir'

try {
    Write-Host '=== 0. 前置状态 ==='
    Write-Host ('转发器目录 : ' + $Kit.ShimDir)
    Write-Host ('已存在     : ' + (Test-ShimPresent))
    Write-Host ('直接 pwsh  : ' + $directPwsh)
    Write-Host ('旧版 5.1   : ' + $legacy)
    if (Test-ShimPresent) { throw '转发器已安装。请先运行 Uninstall.ps1，避免自检覆盖掉真实安装。' }

    $machineBefore = Get-EnvironmentPathValue -Scope Machine

    # ---------------------------------------------------------------
    Write-Host ''
    Write-Host '=== 1. 安装转发器 ==='
    $shim = Install-PowerShellShim -State $state
    $shimInstalled = $true
    Write-Host ('产物: ' + $shim + '（' + (Get-Item $shim).Length + ' 字节）')

    Write-Host ''
    Write-Host '--- 1b. 系统 PATH 是否把转发器目录排在第一位 ---'
    $machineAfter = Get-EnvironmentPathValue -Scope Machine
    $firstEntry = ($machineAfter -split ';')[0].Trim().TrimEnd('\')
    $expectedEntry = $Kit.ShimDir.Trim().TrimEnd('\')
    Assert-Equal -Label '转发器目录置顶' -Actual ($firstEntry -ieq $expectedEntry) -Expected $true

    Write-Host ''
    Write-Host '--- 1c. 同一会话内重复安装（会踩 Add-Type 类型重名的那条路）---'
    try {
        $null = Install-PowerShellShim -State $state
        $machineAgain = Get-EnvironmentPathValue -Scope Machine
        $duplicates = @(($machineAgain -split ';') |
            Where-Object { $_.Trim().TrimEnd('\') -ieq $expectedEntry })
        Assert-Equal -Label '重复安装幂等，PATH 中只出现一次' -Actual $duplicates.Count -Expected 1
    } catch {
        Write-Host ('  重复安装失败：' + $_.Exception.Message) -ForegroundColor Red
        $script:failures++
    }

    # ---------------------------------------------------------------
    Write-Host ''
    Write-Host '=== 2. 自检 Test-PowerShellShim ==='
    $check = Test-PowerShellShim
    Write-Host ('  Ok=' + $check.Ok + '  Detail=' + $check.Detail)
    Assert-Equal -Label '转发到 pwsh 7' -Actual $check.Ok -Expected $true

    # ---------------------------------------------------------------
    Write-Host ''
    Write-Host '=== 2b. 只写名字能否解析（Node / Go 调用方实际走的路）==='
    # 前面几条都用完整路径调用，测不到「名字能不能解析」——而那才是
    # spawnSync powershell ENOENT 的真正失败点。这个函数会从注册表取一份
    # 合并后的 PATH 交给子进程，模拟真实调用方；Install.ps1 第 7 步用的
    # 也是同一个函数，在这里顺便把它一起测了。
    $resolve = Test-ShimNameResolution
    Assert-Equal -Label '只用名字 powershell 就解析到 pwsh 7' -Actual $resolve.Detail -Expected 'Core'
    if (-not $resolve.Ok) { Write-Host ('        ' + $resolve.Detail) -ForegroundColor DarkGray }

    # ---------------------------------------------------------------
    Write-Host ''
    Write-Host '=== 3. 保真度对照：转发器 vs 直接调用 pwsh 7 ==='
    $pwshVectors = @(
        @{ Name = 'PSEdition（最常用的那种）'; Args = @'
-NoLogo -NoProfile -NonInteractive -Command "$PSVersionTable.PSEdition"
'@ }
        @{ Name = '算术输出'; Args = @'
-NoLogo -NoProfile -NonInteractive -Command "1+1"
'@ }
        @{ Name = '命令里带空格与单引号'; Args = @'
-NoLogo -NoProfile -NonInteractive -Command "Write-Output 'a b c'"
'@ }
        @{ Name = '退出码透传 exit 42'; Args = @'
-NoLogo -NoProfile -NonInteractive -Command "exit 42"
'@ }
        @{ Name = 'stderr（Write-Error）'; Args = @'
-NoLogo -NoProfile -NonInteractive -Command "Write-Error boom"
'@ }
        @{ Name = '命令里带 & ^ % 特殊字符'; Args = @'
-NoLogo -NoProfile -NonInteractive -Command "Write-Output 'a&b^c%d'"
'@ }
        @{ Name = 'stdin 管道'; Args = @'
-NoLogo -NoProfile -NonInteractive -Command "$input | ForEach-Object { 'got:' + $_ }"
'@ ; StdIn = "hello`r`nworld`r`n" }
    )
    foreach ($vector in $pwshVectors) {
        Compare-Pair -Label $vector.Name -ShimExe $shim -ExpectExe $directPwsh `
            -Arguments $vector.Args.Trim() -StdIn $vector.StdIn
    }

    New-Item -ItemType Directory -Force -Path $spaceDir | Out-Null
    $spaceScript = Join-Path $spaceDir 'probe file.ps1'
    Set-Content -LiteralPath $spaceScript -Value 'Write-Output ("file args=" + $args.Count)' -Encoding UTF8
    Compare-Pair -Label '-File 指向带空格的路径' -ShimExe $shim -ExpectExe $directPwsh `
        -Arguments ('-NoLogo -NoProfile -NonInteractive -File "{0}" one two' -f $spaceScript)

    # ---------------------------------------------------------------
    Write-Host ''
    Write-Host '=== 4. 保真度对照：转发器 vs 直接调用 Windows PowerShell 5.1 ==='
    $legacyVectors = @(
        @{ Name = '-Version 5.1 放最前（唯一合法位置）'; Args = @'
-Version 5.1 -NoLogo -NoProfile -NonInteractive -Command "$PSVersionTable.PSEdition"
'@ }
        @{ Name = '-Version 2.0 放最前'; Args = @'
-Version 2.0 -NoLogo -NoProfile -NonInteractive -Command "$PSVersionTable.PSVersion.Major"
'@ }
        @{ Name = 'PWSH_SHIM_LEGACY=1 强制走旧版'; Args = @'
-NoLogo -NoProfile -NonInteractive -Command "$PSVersionTable.PSEdition"
'@ ; ForceLegacy = $true }
    )
    foreach ($vector in $legacyVectors) {
        if ($vector.ForceLegacy) { $env:PWSH_SHIM_LEGACY = '1' }
        try {
            Compare-Pair -Label $vector.Name -ShimExe $shim -ExpectExe $legacy -Arguments $vector.Args.Trim()
        } finally {
            Remove-Item Env:PWSH_SHIM_LEGACY -ErrorAction SilentlyContinue
        }
    }

    Write-Host ''
    Write-Host '--- 4b. 关键回归：-Version 5.1 不能被吞成「打印版本号 + exit 0」---'
    $probe = Invoke-Capture -Exe $shim -Arguments '-Version 5.1 -NoLogo -NoProfile -NonInteractive -Command "exit 7"'
    Assert-Equal -Label '退出码 7 被完整透传（不是 0）' -Actual $probe.ExitCode -Expected 7

    Write-Host ''
    Write-Host '--- 4c. -Version 5.1 放中间：5.1 自己会报错，转发器应原样保持 ---'
    Compare-Pair -Label '-Version 5.1 放中间' -ShimExe $shim -ExpectExe $legacy `
        -Arguments '-NoLogo -NoProfile -NonInteractive -Version 5.1 -Command "exit 7"'

    # ---------------------------------------------------------------
    Write-Host ''
    Write-Host '=== 5. 逃逸口 PWSH_SHIM_TARGET ==='
    $env:PWSH_SHIM_TARGET = $legacy
    try {
        $probe = Invoke-Capture -Exe $shim -Arguments '-NoLogo -NoProfile -NonInteractive -Command "$PSVersionTable.PSEdition"'
    } finally {
        Remove-Item Env:PWSH_SHIM_TARGET -ErrorAction SilentlyContinue
    }
    Assert-Equal -Label '指向 5.1 时实际跑的是 Desktop' -Actual $probe.StdOut.Trim() -Expected 'Desktop'

    # ---------------------------------------------------------------
    Write-Host ''
    Write-Host '=== 6. 卸载与还原 ==='
    Remove-PowerShellShim -State $state
    $shimInstalled = $false

    $machineRestored = Get-EnvironmentPathValue -Scope Machine
    Assert-Equal -Label '系统 PATH 逐字节还原' -Actual ($machineRestored -eq $machineBefore) -Expected $true
    Assert-Equal -Label '转发器目录已删除' -Actual (-not (Test-Path -LiteralPath $Kit.ShimDir)) -Expected $true
    Assert-Equal -Label '源码保留' -Actual (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'lib\PowerShellShim.cs')) -Expected $true
} finally {
    Remove-Item -LiteralPath $spaceDir -Recurse -Force -ErrorAction SilentlyContinue

    if ($shimInstalled) {
        Write-Host ''
        Write-Host '异常中止：正在回滚转发器...' -ForegroundColor Yellow
        try {
            Remove-PowerShellShim -State $state
        } catch {
            Write-Host ('  回滚失败：' + $_.Exception.Message) -ForegroundColor Red
            Write-Host ('  请手工运行 Uninstall.ps1，或删除 ' + $Kit.ShimDir + ' 并把它从系统 PATH 移除。') -ForegroundColor Yellow
        }
    }
}

Write-Host ''
if ($script:failures -eq 0) {
    Write-Host '全部通过。' -ForegroundColor Green
    exit 0
}

Write-Host ('失败项：' + $script:failures) -ForegroundColor Red
exit 1
