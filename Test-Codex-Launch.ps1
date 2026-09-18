#requires -Version 5.1
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Codex-SelfHeal.ps1')
$script:LogPath=$null
$passed=0
function Assert($Condition,[string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:passed++; Write-Host "PASS: $Message"
}
$root=Join-Path $env:TEMP ('codex-launch-test-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($root)
$fixture=Join-Path $root 'test program.exe'
Add-Type -TypeDefinition @'
using System;
using System.IO;
public class LaunchProbe {
  public static void Main() {
    File.WriteAllText("child-evidence.txt", (Environment.GetEnvironmentVariable("CODEX_CLI_PATH") ?? "<null>") + "\n" + Environment.CurrentDirectory);
  }
}
'@ -OutputAssembly $fixture -OutputType ConsoleApplication
$pkg=[pscustomobject]@{Exe=$fixture;Version='fixture';Aumid='OpenAI.Codex_2p2nqsd0c76g0!App'}
$before=[Environment]::GetEnvironmentVariable('CODEX_CLI_PATH','Process')
$sentinel='C:\fixture\temporary-cli.exe'
$childPid=Start-DirectApp $pkg $sentinel
$evidence=Join-Path $root 'child-evidence.txt'
for($i=0;$i -lt 50 -and -not (Test-Path -LiteralPath $evidence);$i++) {Start-Sleep -Milliseconds 100}
Assert ($childPid -gt 0 -and (Test-Path -LiteralPath $evidence)) 'Real subprocess started from a path containing spaces'
$lines=[IO.File]::ReadAllLines($evidence)
Assert ($lines[0] -eq $sentinel -and (Test-Path -LiteralPath (Join-Path $root 'child-evidence.txt'))) 'Child receives isolated CLI override and writes its relative output in the requested directory'
Assert ([Environment]::GetEnvironmentVariable('CODEX_CLI_PATH','Process') -eq $before) 'Parent environment is unchanged'

# Compile the actual native interface without activating any installed app.
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Codex-SelfHeal.ps1'),[ref]$tokens,[ref]$errors)
Assert ($errors.Count -eq 0) 'Launcher parses in Windows PowerShell 5.1'
$definition=$ast.FindAll({param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value -match 'namespace CodexSelfHeal'},$true) | Select-Object -First 1
Add-Type -TypeDefinition $definition.Value
Assert ($null -ne ('CodexSelfHeal.AppActivation' -as [type])) 'Windows activation interface compiles'

$script:events=[Collections.Generic.List[object]]::new()
function Write-Event($Event,$Data=@{}) {$script:events.Add([pscustomobject]@{Event=$Event;Data=$Data})}
$script:activationCalls=0
function Start-DirectApp {throw [ComponentModel.Win32Exception]::new(5)}
function Start-RegisteredApp($Aumid) {
    if ($Aumid -ne $pkg.Aumid) {throw 'Wrong registered application'}
    $script:activationCalls++; return 12345
}
Start-App $pkg
$failed=@($script:events | Where-Object Event -eq 'launch_attempt_failed')
Assert ($script:activationCalls -eq 1 -and $failed[0].Data.nativeErrorCode -eq 5) 'Access denied logs Win32 code and tries registered activation exactly once'
Assert (@($script:events | Where-Object Event -eq 'launch_requested').Count -eq 1) 'Successful request is logged once; readiness is not assumed'
$script:events.Clear()
$blocked=$false
try {Start-App $pkg $sentinel} catch {$blocked=$true}
Assert ($blocked -and $script:activationCalls -eq 1) 'CLI override failure does not use a broker that loses its environment'

function Start-DirectApp {return 23456}
function Start-RegisteredApp {throw 'Unexpected broker fallback'}
Start-App $pkg
Assert (@($script:events | Where-Object {$_.Event -eq 'launch_requested' -and $_.Data.method -eq 'direct_process'}).Count -eq 1) 'Direct launch success never invokes fallback'
$script:events.Clear()
function Start-DirectApp {throw [ComponentModel.Win32Exception]::new(5)}
function Start-RegisteredApp {throw [Runtime.InteropServices.COMException]::new('Activation denied',-2147024891)}
$failedBoth=$false
try {Start-App $pkg} catch {$failedBoth=$true}
Assert ($failedBoth -and @($script:events | Where-Object Event -eq 'launch_attempt_failed').Count -eq 2 -and @($script:events | Where-Object Event -eq 'launch_requested').Count -eq 0) 'Both failures retain detailed errors and never report launch success'
Write-Host "LAUNCH TESTS PASSED: $passed"
