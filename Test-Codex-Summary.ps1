#requires -Version 5.1
$ErrorActionPreference='Stop'
. "$PSScriptRoot\Codex-SelfHeal.ps1" -NoGui
$script:LogPath=Join-Path $env:TEMP ('codex-summary-'+[guid]::NewGuid().ToString('N')+'.jsonl')
$script:shown=[Collections.Generic.List[string]]::new()
function Write-Host($Object,$ForegroundColor) { $script:shown.Add([string]$Object) }
Write-Event 'runtime_check' @{complete=$false;badCount=3;sourceCount=100;currentStaging=1;missingExamples=@('secret-diagnostic-path')}
if ($script:shown.Count -ne 1 -or $script:shown[0] -notmatch '3 个文件缺失或不一致' -or $script:shown[0] -match 'secret-diagnostic-path|"event"') { throw 'Summary leaked raw details or lost counts' }
$raw=[IO.File]::ReadAllText($script:LogPath) | ConvertFrom-Json
if ($raw.event -ne 'runtime_check' -or $raw.missingExamples[0] -ne 'secret-diagnostic-path') { throw 'JSON diagnostic data lost' }
Write-Event 'launch_ok' @{window=$false;renderer=$true;logWindow=$false}
if ($script:shown[$script:shown.Count-1] -notmatch '尚未单独确认可见窗口') { throw 'Renderer incorrectly reported as visible window' }
Write-Event 'cleanup_removed' @{directory='.selfheal-12345678';bytes=228420012;files=796}
if ($script:shown[$script:shown.Count-1] -notmatch '217.8 MiB') { throw 'Space summary missing' }
$before=$script:shown.Count
Write-Event 'desktop_evidence' @{secret='detail-only'}
if ($script:shown.Count -ne $before) { throw 'Internal evidence printed' }
Write-Event 'error' @{message='Access denied';nativeErrorCode=5}
if ($script:shown[$script:shown.Count-1] -notmatch '权限不足') { throw 'No actionable error summary' }
$records=@(Get-Content -LiteralPath $script:LogPath -Encoding UTF8 | ForEach-Object {$_ | ConvertFrom-Json})
if ($records.Count -ne 5 -or $records[-1].nativeErrorCode -ne 5) { throw 'Detailed JSON logging broken' }
Microsoft.PowerShell.Utility\Write-Host 'PASS: Chinese summaries, accurate startup status, space totals, hidden raw diagnostics, actionable errors, and complete JSON logs'
