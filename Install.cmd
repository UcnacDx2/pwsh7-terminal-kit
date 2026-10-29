@echo off
setlocal
rem Double-click to run. Arguments are passed through, for example:
rem   Install.cmd -Verify
rem   Install.cmd -PowerShellPackage "D:\pkg\PowerShell-7.6.7.msixbundle"

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" goto :nops

"%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1" %*
exit /b %ERRORLEVEL%

:nops
echo.
echo Windows PowerShell 5.1 not found: %PS%
echo Run manually:  pwsh -File "%~dp0Install.ps1"
echo.
pause
exit /b 1
