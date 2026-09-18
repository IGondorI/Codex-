@echo off
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Codex-SelfHeal.ps1" %*
set "heal_result=%errorlevel%"
pause
exit /b %heal_result%
