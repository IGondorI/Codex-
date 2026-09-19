#requires -Version 5.1
$ErrorActionPreference='Stop'
. "$PSScriptRoot\Codex-Progress.ps1"
$script:records=[Collections.Generic.List[object]]::new()
function Write-Progress($Id,$Activity,$Status,$CurrentOperation,$PercentComplete,[switch]$Completed) {
    $script:records.Add([pscustomobject]@{Activity=$Activity;Status=$Status;Operation=$CurrentOperation;Percent=$PercentComplete;Completed=[bool]$Completed})
}
function Get-ProgressTextWidth { return 60 }
$progress=Start-RepairProgress
Update-RepairProgress $progress '复制' 42 'bin/node.exe' '42 / 100 个文件'
$record=$script:records[$script:records.Count-1]
if ($record.Percent -ne 42 -or $record.Status -notmatch '42%.*42 / 100' -or $record.Status -match '[█░]') { throw 'Missing native progress/counts or duplicate character bar' }
$longPath=('very-long-directory/'*20)+'文件/node.exe'
Update-RepairProgress $progress '复制' 43 $longPath '43 / 100 个文件'
$record=$script:records[$script:records.Count-1]
if ($record.Operation -notlike '...*node.exe' -or $record.Operation.Contains("`n")) { throw 'Long path must keep filename on one line' }
function Assert-DisplayWidth($Text,$Width) {
    $cells=0
    foreach ($character in $Text.ToCharArray()) { if ([int]$character -le 127) { $cells++ } else { $cells+=2 } }
    if ($cells -gt $Width) { throw 'Progress text can wrap' }
}
Assert-DisplayWidth $record.Operation 60
if ((Limit-ProgressText "folder`r`nfile`tname" 60) -ne 'folder file name') { throw 'Control characters must not add progress lines' }
foreach ($width in @(1,3,12,24,60)) {
    $text=Limit-ProgressText (('中文路径/'*30)+'file.txt') $width -KeepEnd
    Assert-DisplayWidth $text $width
}
$emoji=[char]::ConvertFromUtf32(0x1F600)
$trimmed=Limit-ProgressText ('prefix/'+$emoji+'/file') 10 -KeepEnd
$strictUtf8=[Text.UTF8Encoding]::new($false,$true)
$null=$strictUtf8.GetBytes($trimmed)
function Get-ProgressTextWidth { return 24 }
Update-RepairProgress $progress '正在复制文件' 44 $longPath '44444 / 99999 个文件'
$record=$script:records[$script:records.Count-1]
foreach ($text in @($record.Activity,$record.Status,$record.Operation)) { Assert-DisplayWidth $text 24 }
Update-RepairProgress $progress '校验' -1 'SHA-256'
if ($script:records[$script:records.Count-1].Percent -ne -1) { throw 'Invalid verification status' }
Stop-RepairProgress $progress $true
if (-not $script:records[$script:records.Count-1].Completed -or $progress.Clock.IsRunning) { throw 'Progress cleanup failed' }
$progress=Start-RepairProgress
Stop-RepairProgress $progress $false
if (-not $script:records[$script:records.Count-1].Completed) { throw 'Failure cleanup failed' }
Write-Host 'PASS: Native progress, bounded long/Unicode paths, narrow windows, control characters, status and cleanup'
