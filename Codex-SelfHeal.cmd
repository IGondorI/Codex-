@echo off
setlocal
set "heal_powershell=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "heal_powershell=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%heal_powershell%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Codex-SelfHeal.ps1" %*
set "heal_result=%errorlevel%"
pause
exit /b %heal_result%
