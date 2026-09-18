#requires -Version 5.1
$ErrorActionPreference='Stop'
. "$PSScriptRoot\Codex-SelfHeal.ps1" -NoGui
$script:LogPath=$null
$passed=0
function Assert($ok,$message) { if (-not $ok) { throw "FAIL: $message" }; $script:passed++; Write-Host "PASS: $message" }
$fixture=Join-Path $env:TEMP ('codex-cleanup-'+[guid]::NewGuid().ToString('N'))
$script:Base=$fixture
$script:RuntimeRoot=Join-Path $fixture 'runtimes\cua_node'
$source=Join-Path $fixture 'source'
$null=[IO.Directory]::CreateDirectory((Join-Path $source 'bin'))
[IO.File]::WriteAllText((Join-Path $source 'manifest.json'),'{"platform":"windows","node_path":"bin/node.exe","node_repl_path":"bin/node_repl.exe"}')
[IO.File]::WriteAllText((Join-Path $source 'bin\node.exe'),'node')
[IO.File]::WriteAllText((Join-Path $source 'bin\node_repl.exe'),'repl')
$id=Get-RuntimeIdentity $source
$current=Join-Path $script:RuntimeRoot $id
$null=[IO.Directory]::CreateDirectory((Join-Path $current 'bin'))
foreach ($rel in $script:Required) { [IO.File]::Copy((Join-Path $source $rel),(Join-Path $current $rel)) }
$pkg=[pscustomobject]@{FullName='fixture';Source=$source}
function Find-Package { $pkg }
$script:busy=$false
function Get-CleanupBlockers { if ($script:busy) { [pscustomobject]@{ProcessId=42} } }
function FixtureDirectory($name,$days) {
    $path=Join-Path $script:RuntimeRoot $name
    $null=[IO.Directory]::CreateDirectory($path)
    [IO.File]::WriteAllText((Join-Path $path 'fixture.txt'),'test bytes')
    [IO.Directory]::SetLastWriteTimeUtc($path,[datetime]::UtcNow.AddDays(-$days))
    return $path
}
$temp=FixtureDirectory '.selfheal-1234abcd' 5
$stage=FixtureDirectory '.staging-1111111111111111-ABC123' 5
$old=FixtureDirectory '1111111111111111' 10
$recent=FixtureDirectory '2222222222222222' 1
$backupOld=FixtureDirectory ('1111111111111111.backup-'+('a'*32)) 10
$backupNew=FixtureDirectory ($id+'.backup-'+('b'*32)) 1
$unknown=FixtureDirectory 'personal-files' 20
$script:busy=$true
Invoke-RuntimeCleanup $pkg $id
Assert (Test-Path -LiteralPath $temp) 'Running app prevents all cleanup'
$script:busy=$false
$Diagnose=$true
Invoke-RuntimeCleanup $pkg $id
Assert (Test-Path -LiteralPath $temp) 'Diagnose never deletes'
$Diagnose=$false
[IO.File]::WriteAllText((Join-Path $current 'bin\node.exe'),'bad!')
Invoke-RuntimeCleanup $pkg $id
Assert ((Test-Path -LiteralPath $temp) -and (Test-Path -LiteralPath $old)) 'Full hash mismatch prevents all cleanup'
[IO.File]::Copy((Join-Path $source 'bin\node.exe'),(Join-Path $current 'bin\node.exe'),$true)
# Exercise long paths and read-only files in a removable temporary directory.
$deep=Join-Path $temp (('x'*90)+'\'+('y'*90)+'\'+('z'*90))
$null=[IO.Directory]::CreateDirectory((LongPath $deep))
[IO.File]::WriteAllText((LongPath (Join-Path $deep 'deep.txt')),'deep')
[IO.File]::SetAttributes((Join-Path $temp 'fixture.txt'),[IO.FileAttributes]::ReadOnly)
Invoke-RuntimeCleanup $pkg $id
Assert (-not [IO.Directory]::Exists((LongPath $temp)) -and -not (Test-Path -LiteralPath $stage)) 'Stale temporary trees including long/read-only files removed'
Assert ((Test-Path -LiteralPath $current) -and (Test-Path -LiteralPath $recent) -and -not (Test-Path -LiteralPath $old)) 'Current and newest previous runtime retained'
Assert ((Test-Path -LiteralPath $backupNew) -and -not (Test-Path -LiteralPath $backupOld)) 'Only newest backup retained'
Assert (Test-Path -LiteralPath $unknown) 'Unrecognized folders untouched'
Invoke-RuntimeCleanup $pkg $id
Assert ((Compare-Runtime $source $current -AllHashes).Complete) 'Repeated cleanup preserves verified runtime'
$temp=FixtureDirectory '.selfheal-9999abcd' 5
function Get-CleanupBlockers { throw 'Process query denied' }
Invoke-RuntimeCleanup $pkg $id
Assert (Test-Path -LiteralPath $temp) 'Process query failure defers cleanup'
function Get-CleanupBlockers { @() }
$outside=Join-Path $fixture 'protected'
$null=[IO.Directory]::CreateDirectory($outside)
[IO.File]::WriteAllText((Join-Path $outside 'keep.txt'),'protected')
$null=New-Item -ItemType Junction -Path (Join-Path $temp 'link') -Target $outside
Invoke-RuntimeCleanup $pkg $id
Assert ((Test-Path -LiteralPath $temp) -and (Test-Path -LiteralPath (Join-Path $outside 'keep.txt'))) 'Nested junction blocks deletion and protects its target'
Write-Host "TESTS PASSED: $passed"
