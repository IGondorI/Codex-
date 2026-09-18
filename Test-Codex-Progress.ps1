#requires -Version 5.1
$ErrorActionPreference='Stop'
. "$PSScriptRoot\Codex-Progress.ps1"
$script:records=[Collections.Generic.List[object]]::new()
function Write-Progress($Id,$Activity,$Status,$CurrentOperation,$PercentComplete,[switch]$Completed) {
    $script:records.Add([pscustomobject]@{Status=$Status;Percent=$PercentComplete;Completed=[bool]$Completed})
}
$progress=Start-RepairProgress
Update-RepairProgress $progress '复制' 42 'bin/node.exe' '42 / 100 个文件'
$record=$script:records[$script:records.Count-1]
if ($record.Percent -ne 42 -or $record.Status -notmatch '42%.*42 / 100' -or $record.Status -notmatch '█+░+') { throw 'Missing terminal bar or counts' }
Update-RepairProgress $progress '校验' -1 'SHA-256'
if ($script:records[$script:records.Count-1].Percent -ne -1) { throw 'Invalid verification status' }
Stop-RepairProgress $progress $true
if (-not $script:records[$script:records.Count-1].Completed -or $progress.Clock.IsRunning) { throw 'Progress cleanup failed' }
$progress=Start-RepairProgress
Stop-RepairProgress $progress $false
if (-not $script:records[$script:records.Count-1].Completed) { throw 'Failure cleanup failed' }
Write-Host 'PASS: Terminal bar, counts, verification status, success and failure cleanup'
