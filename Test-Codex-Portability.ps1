#requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Join-Path $env:TEMP ('codex-portable-'+[guid]::NewGuid().ToString('N'))
$portable=Join-Path $root '中文 portable folder'
$elsewhere=Join-Path $root 'other working directory'
$null=[IO.Directory]::CreateDirectory($portable)
$null=[IO.Directory]::CreateDirectory($elsewhere)
foreach ($name in @('Codex-SelfHeal.ps1','Codex-Progress.ps1','Codex-Cleanup.ps1')) {
    [IO.File]::Copy((Join-Path $PSScriptRoot $name),(Join-Path $portable $name))
}
$passed=0
function Assert($ok,$message) { if (-not $ok) { throw "FAIL: $message" }; $script:passed++; Write-Host "PASS: $message" }
Push-Location $elsewhere
try {
    . (Join-Path $portable 'Codex-SelfHeal.ps1') -NoGui
    Assert ($script:LogPath -eq (Join-Path $portable 'logs\self-heal.log')) 'Default log follows relocated script with Unicode and spaces'
    Assert ((Resolve-LauncherLogPath 'custom\output.log') -eq (Join-Path $portable 'custom\output.log')) 'Relative log path ignores current working directory'
    $absolute=Join-Path $root 'absolute.log'
    Assert ((Resolve-LauncherLogPath $absolute) -eq $absolute) 'Explicit absolute log remains unchanged'
    $script:Base=Join-Path $root 'app-data'
    $script:RuntimeRoot=Join-Path $script:Base 'runtimes\cua_node'
    # Execute the real entry/finally block with only environment and launch mocked.
    $code=[IO.File]::ReadAllText((Join-Path $portable 'Codex-SelfHeal.ps1'))
    $entry=$code.Substring($code.IndexOf('$lock=$null;')).Replace('exit $exitCode','return $exitCode')
    $entryBlock=[scriptblock]::Create($entry)
    function Assert-LauncherEnvironment { }
    function Invoke-Launcher { Write-Event 'diagnose_complete'; return 0 }
    $result=& $entryBlock
    Assert ($result -eq 0 -and (Test-Path -LiteralPath $script:LogPath)) 'Successful run writes portable log'
    Assert (-not (Test-Path -LiteralPath ($script:LogPath+'.lock'))) 'Log lock removed after success'
    Assert (-not (Test-Path -LiteralPath $script:Base)) 'Diagnostic fixture creates no user runtime directory'
    function Invoke-Launcher { throw 'Injected portable failure' }
    $result=& $entryBlock
    $last=Get-Content -LiteralPath $script:LogPath -Encoding UTF8 | Select-Object -Last 1 | ConvertFrom-Json
    Assert ($result -eq 1 -and $last.event -eq 'error') 'Failure writes diagnostic detail in portable log'
    Assert (-not (Test-Path -LiteralPath ($script:LogPath+'.lock'))) 'Log lock removed after failure'
    [IO.File]::WriteAllText($script:LogPath,('x'*(5MB+1)))
    function Invoke-Launcher { Write-Event 'diagnose_complete'; return 0 }
    $result=& $entryBlock
    Assert ($result -eq 0 -and (Get-Item -LiteralPath ($script:LogPath+'.1')).Length -gt 5MB) 'Log rotation stays beside portable log'
    $blocker=Join-Path $root 'not-a-directory'
    [IO.File]::WriteAllText($blocker,'fixture')
    $LogPath=Join-Path $blocker 'output.log'
    $result=& $entryBlock
    Assert ($result -eq 1 -and -not (Test-Path -LiteralPath $LogPath)) 'Unwritable log fails without fallback to another directory'
    # Confirm the mutex coordinates distinct processes, not just one log path.
    $mutex=Enter-RuntimeMutex $script:RuntimeRoot
    try {
        $probe=Join-Path $root 'mutex-probe.ps1'
        $probeCode=@'
param($Launcher,$Root)
. $Launcher
try { $mutex=Enter-RuntimeMutex $Root; $mutex.ReleaseMutex(); $mutex.Dispose(); exit 9 }
catch { if ($_.Exception.Message -match 'Another launcher') { exit 0 }; exit 8 }
'@
        [IO.File]::WriteAllText($probe,$probeCode,[Text.UTF8Encoding]::new($true))
        $start=[Diagnostics.ProcessStartInfo]::new()
        $start.FileName=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $start.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$probe+'" "'+(Join-Path $portable 'Codex-SelfHeal.ps1')+'" "'+$script:RuntimeRoot+'"'
        $start.UseShellExecute=$false; $start.CreateNoWindow=$true
        $process=[Diagnostics.Process]::Start($start)
        try { if (-not $process.WaitForExit(15000)) { $process.Kill(); throw 'Mutex probe timed out' }; Assert ($process.ExitCode -eq 0) 'Separate process cannot repair same runtime concurrently' }
        finally { $process.Dispose() }
    } finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
    $mutex=Enter-RuntimeMutex $script:RuntimeRoot
    $mutex.ReleaseMutex(); $mutex.Dispose()
    Assert $true 'Runtime mutex can be reacquired after release'
    $PackageName='Example.Codex'
    $script:observedPackage=$null
    $exe=Join-Path $root 'app\Codex.exe'
    $null=[IO.Directory]::CreateDirectory((Split-Path $exe))
    [IO.File]::WriteAllText($exe,'fixture')
    function Get-AppxPackage($Name) {
        $script:observedPackage=$Name
        [pscustomobject]@{IsResourcePackage=$false;Status='Ok';InstallLocation=$root;Version='1.0';PackageFullName='fixture';PackageFamilyName='Example.Codex_fixture'}
    }
    function Get-AppxPackageManifest($Package) {
        [pscustomobject]@{Package=[pscustomobject]@{Applications=[pscustomobject]@{Application=[pscustomobject]@{Executable='app\Codex.exe';Id='App'}}}}
    }
    $package=Find-Package
    Assert ($script:observedPackage -eq 'Example.Codex' -and $package.Exe -eq $exe) 'Explicit package selection uses registered install location'
} finally { Pop-Location }
Write-Host "TESTS PASSED: $passed"
