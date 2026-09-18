$ErrorActionPreference='Stop'
. "$PSScriptRoot\Codex-SelfHeal.ps1" -NoGui
$script:LogPath=$null
$passed=0
function Assert($Condition,[string]$Message) { if (-not $Condition) { throw "FAIL: $Message" }; $script:passed++; Write-Host "PASS: $Message" }
$scratchRoot=Join-Path $env:TEMP 'codex-selfheal-tests'
$null=[IO.Directory]::CreateDirectory($scratchRoot)
$root=Join-Path $scratchRoot ('test-'+[guid]::NewGuid().ToString('N'))
$source=Join-Path $root 'source'; $dest=Join-Path $root 'destination'
$null=[IO.Directory]::CreateDirectory((Join-Path $source 'bin\node_modules'))
$null=[IO.Directory]::CreateDirectory($dest)
[IO.File]::WriteAllText((Join-Path $source 'manifest.json'),'{"platform":"windows","node_path":"bin/node.exe","node_repl_path":"bin/node_repl.exe"}')
[IO.File]::WriteAllText((Join-Path $source 'bin\node.exe'),'node-test-bytes')
[IO.File]::WriteAllText((Join-Path $source 'bin\node_repl.exe'),'repl-test-bytes')
$id=Get-RuntimeIdentity $source
Assert ($id -match '^[0-9a-f]{16}$') 'Runtime identity is bounded hexadecimal'
$check=Compare-Runtime $source $dest
Assert (-not $check.Complete -and $check.Bad.Count -eq 3) 'Missing destination is incomplete'
& "$env:SystemRoot\System32\xcopy.exe" ($source+'\*') ($dest+'\') /E /I /H /K /R /Y /G /Q | Out-Null
Assert ($LASTEXITCODE -eq 0) 'Native xcopy /G invocation succeeds'
Assert ((Compare-Runtime $source $dest -AllHashes).Complete) 'Copied files pass SHA256'
[IO.File]::WriteAllText((Join-Path $dest 'bin\node.exe'),'xxxx-test-bytes')
Assert (-not (Compare-Runtime $source $dest).Complete) 'Same-size key-file corruption detected'
$deep=('a'*80)+'\'+('b'*80)+'\'+('c'*80)
$null=[IO.Directory]::CreateDirectory((LongPath (Join-Path $source $deep)))
[IO.File]::WriteAllText((LongPath (Join-Path $source ($deep+'\deep.txt'))),'deep-file')
Assert ((Get-Inventory $source).Count -eq 4) 'Inventory includes paths longer than MAX_PATH'
$escaped=$false
try {$null=Assert-SafePath (Join-Path $root '..\outside') $root} catch {$escaped=$true}
Assert $escaped 'Traversal outside allowed root rejected'
$script:RuntimeRoot=Join-Path $root 'runtimes'
$null=[IO.Directory]::CreateDirectory((Join-Path $script:RuntimeRoot ('.staging-'+$id+'-ABC123')))
$null=[IO.Directory]::CreateDirectory((Join-Path $script:RuntimeRoot '.staging-0000000000000000-old'))
$null=[IO.Directory]::CreateDirectory((Join-Path $script:RuntimeRoot '.staging-not-a-runtime-id'))
$staging=@(Get-Staging $id)
Assert ($staging.Count -eq 2 -and @($staging | Where-Object Current).Count -eq 1) 'Old and malformed staging not selected'
$logs=Join-Path $root 'logs'; $null=[IO.Directory]::CreateDirectory($logs)
$logFile=Join-Path $logs 'codex-desktop-test-42-t0-i1.log'
$now=[datetime]::UtcNow
[IO.File]::WriteAllLines($logFile,@(
  ($now.AddHours(-2).ToString('o')+' error [AppServerConnection] spawn EPERM OpenAI\Codex\bin\1234567890abcdef\codex.exe'),
  ($now.ToString('o')+' warning [Plugin] spawn EPERM'),
  ($now.ToString('o')+' info [AppServerConnection] Codex CLI initialized'),
  ($now.ToString('o')+' info [window-manager] window ready-to-show appearance=primary')
))
function Get-LogFiles { @(Get-Item -LiteralPath $logFile) }
$ev=Read-StartupEvidence $now.AddMinutes(-1) @(42)
Assert ($ev.Window -and $ev.Handshake -and -not $ev.Eperm) 'Old EPERM and unrelated plugin EPERM do not trigger CLI fallback'
$ev=Read-StartupEvidence $now.AddMinutes(-1) @(99)
Assert (-not $ev.Window -and -not $ev.Handshake) 'Other process log is excluded'
$blocked=$false
try {Stop-ProvenStall $null ([pscustomobject]@{Window=$false;Renderer=$false;Backend=$false;OwnHost=$true}) ([pscustomobject]@{Window=$false;Handshake=$false})} catch {$blocked=$true}
Assert $blocked 'Launcher refuses to terminate its own Codex host'
$script:Base=Join-Path $root 'repair-base'
$script:RuntimeRoot=Join-Path $script:Base 'runtimes\cua_node'
$fakePackage=[pscustomobject]@{FullName='fixture-package';Version='1.0';Source=$source}
function Find-Package { return $fakePackage }
function Get-AppState { return [pscustomobject]@{Processes=@()} }
$script:progressRecords=[Collections.Generic.List[object]]::new()
function Write-Progress($Id,$Activity,$Status,$CurrentOperation,$PercentComplete,[switch]$Completed) {
    $script:progressRecords.Add([pscustomobject]@{Percent=$PercentComplete;File=$CurrentOperation;Completed=[bool]$Completed})
}
Repair-Runtime $fakePackage $id
Assert (@($script:progressRecords | Where-Object {$_.File -and $_.Percent -gt 0}).Count -gt 0) 'Real xcopy output updates file progress'
Assert ($script:progressRecords[$script:progressRecords.Count-1].Completed) 'Copy progress closes after xcopy'
$repaired=Join-Path $script:RuntimeRoot $id
Assert ((Compare-Runtime $source $repaired -AllHashes).Complete) 'Transactional repair includes the path silently skipped by xcopy'
[IO.File]::WriteAllText((Join-Path $repaired 'bin\node.exe'),'old-corrupt-node')
Repair-Runtime $fakePackage $id
Assert ((Compare-Runtime $source $repaired -AllHashes).Complete) 'Incomplete existing runtime replaced after verification'
Assert (@(Get-ChildItem -LiteralPath $script:RuntimeRoot -Directory -Filter '*.backup-*').Count -eq 1) 'Previous runtime is preserved for rollback'
# Inject a verification failure after copying: published runtime must survive.
$previousHash=Hash-File (Join-Path $repaired 'bin\node.exe')
$originalCompare=${function:Compare-Runtime}
function Compare-Runtime($Source,$Destination,[switch]$AllHashes) {
    if ($AllHashes) { return [pscustomobject]@{Complete=$false;ExtraCount=0;SourceCount=4;DestinationCount=4;Bad=@('injected')} }
    & $originalCompare $Source $Destination
}
$failed=$false
try { Repair-Runtime $fakePackage $id } catch { $failed=$true }
Assert ($failed -and (Hash-File (Join-Path $repaired 'bin\node.exe')) -eq $previousHash) 'Failed verification never overwrites the existing runtime'
Set-Item -LiteralPath Function:\Compare-Runtime -Value $originalCompare
# Exercise high-level idempotence with mocked process observation, not real processes.
$fakePackage | Add-Member Install $root
$fakePackage | Add-Member Exe (Join-Path $root 'app.exe')
function Get-AppState { return [pscustomobject]@{Processes=@([pscustomobject]@{ProcessId=42});Ids=@(42);Window=$true;Renderer=$true;Backend=$true;OwnHost=$false} }
function Start-App { throw 'Unexpected app launch in healthy path' }
function Repair-Runtime { throw 'Unexpected repair in healthy path' }
$Diagnose=$false
Assert ((Invoke-Launcher) -eq 0) 'Healthy app is not copied, restarted or terminated'
$Diagnose=$true
Assert ((Invoke-Launcher) -eq 0) 'Diagnose path never launches or repairs'
# A new version with no staging first gets an ordinary launch, not an eager copy.
$Diagnose=$false; $fakePackage.Source=Join-Path $root 'new-source'
$null=[IO.Directory]::CreateDirectory((Join-Path $fakePackage.Source 'bin\node_modules'))
foreach($rel in $script:Required) {[IO.File]::Copy((Join-Path $source $rel),(Join-Path $fakePackage.Source $rel))}
[IO.File]::AppendAllText((Join-Path $fakePackage.Source 'bin\node.exe'),'new-version')
function Get-AppState { return [pscustomobject]@{Processes=@();Ids=@();Window=$false;Renderer=$false;Backend=$false;OwnHost=$false} }
$script:launches=0
function Start-App { $script:launches++ }
function Wait-App { return [pscustomobject]@{Healthy=$true;State=[pscustomobject]@{Window=$true;Renderer=$true};Evidence=[pscustomobject]@{Window=$true}} }
Assert ((Invoke-Launcher) -eq 0 -and $script:launches -eq 1) 'New version without staging is launched normally with no repair'
function Get-AppState { return [pscustomobject]@{Processes=@();Ids=@(99);Window=$false;Renderer=$false;Backend=$true;OwnHost=$false} }
Assert ((Invoke-Launcher) -eq 2 -and $script:launches -eq 1) 'Backend without window is protected but not reported as successful startup'
Write-Host "TESTS PASSED: $passed"
