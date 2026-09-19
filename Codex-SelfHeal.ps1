#requires -Version 5.1
<# Portable launcher. No administrator rights, registry writes, scheduled tasks or downloads.
   Normal invocation writes only its own log and repairs a proven stalled relocation.
   -Diagnose never launches/stops/repairs. -RepairIncomplete repairs a verified existing
   runtime with missing content, only while the app is fully closed.
   Run with Windows PowerShell 5.1 (the .cmd does this for reliable AppX discovery).
#>
[CmdletBinding()]
param(
    [switch]$Diagnose,
    # Retained for compatibility; progress now always stays in the terminal.
    [switch]$NoGui,
    [switch]$RepairIncomplete,
    [switch]$TryCliFallback,
    [ValidatePattern('^[A-Za-z0-9._-]+$')][string]$PackageName = 'OpenAI.Codex',
    [ValidateRange(30,300)][int]$TimeoutSeconds = 90,
    [string]$LogPath = 'logs\self-heal.log'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:LauncherRoot = $PSScriptRoot
$script:LogPath = if ([IO.Path]::IsPathRooted($LogPath)) { $LogPath } else { Join-Path $script:LauncherRoot $LogPath }
$script:Base = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex'
$script:RuntimeRoot = Join-Path $script:Base 'runtimes\cua_node'
$script:Required = @('manifest.json','bin/node.exe','bin/node_repl.exe')
$script:LauncherVersion = '1.2.0'
. (Join-Path $PSScriptRoot 'Codex-Progress.ps1')
. (Join-Path $PSScriptRoot 'Codex-Cleanup.ps1')

function LongPath([string]$Path) {
    $p = [IO.Path]::GetFullPath($Path)
    if ($p.StartsWith('\\?\')) { return $p }
    if ($p.StartsWith('\\')) { return '\\?\UNC\' + $p.Substring(2) }
    return '\\?\' + $p
}
function Assert-SafePath([string]$Path,[string]$Root) {
    $p = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $r = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    if ($p -ne $r -and -not $p.StartsWith($r+'\',[StringComparison]::OrdinalIgnoreCase)) { throw "Path outside allowed root: $p" }
    # Check every existing ancestor, including the root: never write through a junction.
    $cursor=$p
    while ($cursor) {
        if ([IO.Directory]::Exists((LongPath $cursor)) -or [IO.File]::Exists((LongPath $cursor))) {
            if ([IO.File]::GetAttributes((LongPath $cursor)) -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse point requires manual review: $cursor" }
        }
        $parent=[IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }; $cursor=$parent
    }
    return $p
}
function Resolve-LauncherLogPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'LogPath must name a writable log file.' }
    if (-not [IO.Path]::IsPathRooted($Path)) { $Path=Join-Path $script:LauncherRoot $Path }
    return [IO.Path]::GetFullPath($Path)
}
function Assert-LauncherEnvironment {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Unsupported platform: Windows is required.' }
    if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Use Windows PowerShell 5.1 via Codex-SelfHeal.cmd.' }
    foreach ($command in @('Get-AppxPackage','Get-AppxPackageManifest','Get-CimInstance')) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "Required Windows command unavailable: $command" }
    }
    if (-not [IO.File]::Exists((Join-Path $env:SystemRoot 'System32\xcopy.exe'))) { throw 'Required Windows utility unavailable: xcopy.exe' }
}
function Enter-RuntimeMutex([string]$Root) {
    # One OS mutex for the same user runtime, regardless of launcher/log location.
    # Global scope also covers a second Windows session; no persistent lock file.
    $sha=[Security.Cryptography.SHA256]::Create()
    try { $key=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($Root).TrimEnd('\').ToUpperInvariant())))).Replace('-','') }
    finally { $sha.Dispose() }
    $mutex=[Threading.Mutex]::new($false,('Global\CodexSelfHeal-'+$key))
    $owned=$false
    try {
        try { $owned=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned=$true }
        if (-not $owned) { throw 'Another launcher is already working on this runtime.' }
        return $mutex
    } catch { $mutex.Dispose(); throw }
}
function Write-EventSummary([string]$Event,$Data) {
    $label='信息'; $color='Cyan'; $message=$null
    switch ($Event) {
        'package' { $message="检测到 Codex $($Data.version)，正在检查运行环境。" }
        'runtime_check' {
            if ($Data.complete) { $label='检查'; $color='Green'; $message="运行环境初步检查通过，共 $($Data.sourceCount) 个源文件。" }
            else { $label='注意'; $color='Yellow'; $message="发现 $($Data.badCount) 个文件缺失或不一致（源文件共 $($Data.sourceCount) 个）。" }
            if ($Data.currentStaging -gt 0) { $message+=' 发现当前版本的部署残留。' }
        }
        'process_check' {
            if ($Data.processCount -eq 0) { $message='未检测到当前应用的桌面进程。' }
            elseif ($Data.window) { $message='检测到 Codex 窗口。' }
            elseif ($Data.renderer) { $message='检测到前端进程，尚未确认窗口。' }
            else { $label='注意'; $color='Yellow'; $message="检测到 $($Data.processCount) 个桌面进程，尚未发现窗口或前端。" }
        }
        'desktop_evidence' { return } # Diagnostic details remain in the JSON log.
        'already_running' {
            $message='已有前端或窗口运行证据，本次不重启。'
            if ($Data.integrityRepairDeferred) { $message+=' 文件修复已推迟，请正常退出 Codex 后再运行。'; $color='Yellow' }
        }
        'running_protected' { $label='暂缓'; $color='Yellow'; $message='后端或承载当前任务的进程仍在运行。请正常退出 Codex 后再运行启动器。' }
        'runtime_schema_unsupported' { $label='注意'; $color='Yellow'; $message='当前运行环境布局无法识别，已禁用自动修复。' }
        'runtime_layout_absent' { $message='安装包中没有预期的运行环境目录，将按普通方式启动。' }
        'repair_start' { $label='修复'; $message="开始复制运行环境，共 $($Data.sourceCount) 个文件。" }
        'xcopy' {
            if ($Data.exitCode -eq 0) { $message='复制阶段结束，正在检查遗漏文件并校验内容。' }
            else { $label='失败'; $color='Red'; $message="复制未完成（退出码 $($Data.exitCode)），原运行环境已保留。" }
        }
        'long_path_recovery' { $label='修复'; $message="已补齐 $($Data.fileCount) 个长路径文件。" }
        'repair_complete' { $label='完成'; $color='Green'; $message="$($Data.destinationCount) 个文件已通过完整校验，运行环境已替换。" }
        'cleanup_removed' { $label='清理'; $color='Green'; $message=('已删除旧副本或临时目录 {0}，文件大小合计 {1:N1} MiB。' -f $Data.directory,($Data.bytes/1MB)) }
        'cleanup_deferred' {
            $label='暂缓'; $color='Yellow'
            if ($Data.reason -match 'process|active|进程') { $message='相关进程仍在运行或状态无法确认，暂不清理旧文件。' }
            elseif ($Data.reason -match 'verification') { $message='当前运行环境未通过完整校验，已保留全部旧文件。' }
            elseif ($Data.reason -match 'denied|拒绝访问') { $message='权限不足，暂不清理旧文件。' }
            else { $message='本次清理条件未满足，剩余旧文件已保留；继续启动流程。' }
        }
        'launch_attempt' {
            if ($Data.method -eq 'registered_app_activation') { $message='正在尝试通过 Windows 注册应用接口启动。' }
            else { $message='正在启动 Codex…' }
        }
        'launch_attempt_failed' { $label='注意'; $color='Yellow'; $message='本次启动调用失败，详细原因已记录到日志。' }
        'launch_requested' { $message="已发出启动请求，正在等待前端就绪（本轮最多 $TimeoutSeconds 秒）。" }
        'launch_ok' {
            $label='就绪'; $color='Green'
            if ($Data.window) { $message='已检测到 Codex 窗口。' }
            elseif ($Data.logWindow) { $message='日志已确认窗口就绪。' }
            else { $message='已检测到前端进程，尚未单独确认可见窗口。' }
        }
        'launch_ok_after_repair' { $label='就绪'; $color='Green'; $message='修复后已检测到前端或窗口就绪证据。' }
        'launch_unconfirmed' { $label='未确认'; $color='Yellow'; $message='等待结束，仍未确认前端或窗口就绪。请查看详细日志。' }
        'cli_fallback_skipped' { $label='跳过'; $color='Yellow'; $message='当前安装路径不适合备用启动方式，已跳过。' }
        'temporary_cli_retry' {
            if ($Data.success) { $label='就绪'; $color='Green'; $message='备用启动后已检测到前端或窗口就绪证据。' }
            else { $label='未确认'; $color='Yellow'; $message='备用启动后仍未确认前端就绪，请查看详细日志。' }
        }
        'diagnose_complete' { $label='诊断'; $message='检查结束；本次没有启动、修复或清理操作。' }
        'error' {
            $label='失败'; $color='Red'
            if ($Data.message -match 'Another launcher') { $message='另一份启动器正在处理同一个运行环境，请等待它结束。' }
            elseif ($Data.message -match 'Windows PowerShell 5.1|Unsupported platform|Required Windows') { $message='运行环境不满足要求。请在 Windows 上通过 Codex-SelfHeal.cmd 运行，并查看日志中的具体缺失项。' }
            elseif ($Data.message -match 'denied|拒绝访问|Unauthorized') { $message='权限不足，操作已停止。请在当前用户的普通 Windows 会话中运行启动器。' }
            elseif ($Data.message -match 'Close Codex|Active/possibly healthy|processes remain') { $message='检测到应用仍在运行，请正常退出 Codex 后重试。' }
            elseif ($Data.message -match 'verification|mismatch|omission') { $message='文件完整性检查失败，未将本次副本发布为正式运行环境。' }
            elseif ($Data.message -match 'Package updated|Package/process changed') { $message='安装包或进程状态发生变化，操作已停止，请稍后重试。' }
            else { $message='操作未完成，详细原因已保存到日志。' }
        }
        default { return }
    }
    if ($message) { Write-Host "  [$label] $message" -ForegroundColor $color }

}

function Write-Event([string]$Event,$Data=@{}) {
    $record=[ordered]@{ time=(Get-Date).ToString('o'); event=$Event }
    foreach ($key in $Data.Keys) { $record[$key]=$Data[$key] }
    $line=$record | ConvertTo-Json -Compress -Depth 6
    if ($script:LogPath) { [IO.File]::AppendAllText($script:LogPath,$line+[Environment]::NewLine,[Text.UTF8Encoding]::new($false)) }
    Write-EventSummary $Event $Data
}
function Hash-File([string]$Path) {
    $stream=[IO.File]::OpenRead((LongPath $Path)); $sha=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
    finally { $stream.Dispose(); $sha.Dispose() }
}
function Get-Inventory([string]$Root) {
    $result=@{}; $pending=[Collections.Generic.Stack[string]]::new(); $pending.Push('')
    if (-not [IO.Directory]::Exists((LongPath $Root))) { return ,$result }
    while ($pending.Count -gt 0) {
        $relative=$pending.Pop(); $directory=Join-Path $Root $relative
        foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries((LongPath $directory))) {
            $attributes=[IO.File]::GetAttributes($entry)
            if ($attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Unsupported runtime link: $entry" }
            $leaf=[IO.Path]::GetFileName($entry)
            $rel=$leaf
            if ($relative) { $rel=$relative+'/'+$leaf }
            if ($attributes -band [IO.FileAttributes]::Directory) { $pending.Push($rel) }
            else { $result[$rel]=[IO.FileInfo]::new($entry).Length }
        }
    }
    return ,$result
}
function Compare-Runtime([string]$Source,[string]$Destination,[switch]$AllHashes) {
    $s=Get-Inventory $Source; $d=Get-Inventory $Destination
    $bad=[Collections.Generic.List[string]]::new()
    foreach ($rel in $s.Keys) {
        if (-not $d.ContainsKey($rel) -or $s[$rel] -ne $d[$rel]) { $bad.Add($rel); continue }
        if ($AllHashes -or $rel -in $script:Required) {
            if ((Hash-File (Join-Path $Source $rel)) -ne (Hash-File (Join-Path $Destination $rel))) { $bad.Add($rel) }
        }
    }
    return [pscustomobject]@{Complete=($bad.Count -eq 0); SourceCount=$s.Count; DestinationCount=$d.Count; Bad=@($bad.ToArray()); ExtraCount=@($d.Keys | Where-Object {-not $s.ContainsKey($_)}).Count}
}
function Get-RuntimeIdentity([string]$Source) {
    $text=''
    foreach ($rel in $script:Required) {
        $path=Join-Path $Source $rel
        if (-not [IO.File]::Exists((LongPath $path))) { throw "Bundled runtime layout changed; missing $rel" }
        $text += $rel + [char]0 + (Hash-File $path) + [char]0
    }
    $manifest=[IO.File]::ReadAllText((LongPath (Join-Path $Source 'manifest.json'))) | ConvertFrom-Json
    if ($manifest.platform -ne 'windows' -or $manifest.node_path -ne 'bin/node.exe' -or $manifest.node_repl_path -ne 'bin/node_repl.exe') { throw 'Unrecognized runtime manifest; no repair allowed.' }
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-','').Substring(0,16).ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function Find-Package {
    $packages=@(Get-AppxPackage -Name $PackageName -ErrorAction Stop | Where-Object {-not $_.IsResourcePackage})
    if ($packages.Count -ne 1) { throw "AppX query returned $($packages.Count) packages. Run the .cmd in your normal signed-in Windows session; no guessed package path will be used." }
    $p=$packages[0]
    if ([string]$p.Status -ne 'Ok') { throw "AppX status is $($p.Status); runtime workaround is not applicable." }
    $manifest=Get-AppxPackageManifest -Package $p.PackageFullName
    $apps=@($manifest.Package.Applications.Application | Where-Object {$_.Executable -match '(?i)(ChatGPT|Codex)\.exe$'})
    if ($apps.Count -ne 1) { throw 'Cannot identify a unique desktop executable in AppX manifest.' }
    $exe=Join-Path $p.InstallLocation $apps[0].Executable
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'Manifest desktop executable is missing.' }
    return [pscustomobject]@{Version=[string]$p.Version;FullName=$p.PackageFullName;Install=$p.InstallLocation;Exe=[IO.Path]::GetFullPath($exe);Source=(Join-Path (Split-Path $exe) 'resources\cua_node');Aumid=($p.PackageFamilyName+'!'+$apps[0].Id)}
}
function Get-AppState($Package) {
    $all=@(Get-CimInstance Win32_Process -ErrorAction Stop)
    $session=(Get-Process -Id $PID).SessionId
    # Executable paths can be reported using an alias; include all paths ending in
    # this exact registered package name, never match by ChatGPT.exe alone.
    $suffix='\'+$Package.FullName+'\'+$Package.Exe.Substring($Package.Install.Length).TrimStart('\')
    $app=@($all | Where-Object { $_.SessionId -eq $session -and $_.ExecutablePath -and ($_.ExecutablePath -ieq $Package.Exe -or $_.ExecutablePath.EndsWith($suffix,[StringComparison]::OrdinalIgnoreCase)) })
    $ids=@($app | ForEach-Object {[int]$_.ProcessId})
    $children=@($all | Where-Object {$_.ParentProcessId -in $ids -and $_.Name -ieq 'codex.exe'})
    $window=$false
    foreach ($entry in $app) {
        $proc=Get-Process -Id $entry.ProcessId -ErrorAction SilentlyContinue
        if ($proc -and $proc.MainWindowHandle -ne [IntPtr]::Zero) { $window=$true }
    }
    $ancestors=[Collections.Generic.List[int]]::new(); $cursor=$PID
    for($i=0;$i -lt 32;$i++) {
        $row=$all | Where-Object {$_.ProcessId -eq $cursor} | Select-Object -First 1
        if (-not $row -or $row.ParentProcessId -eq 0) { break }
        $cursor=[int]$row.ParentProcessId; $ancestors.Add($cursor)
    }
    return [pscustomobject]@{Processes=$app;Ids=$ids;Window=$window;Renderer=(@($app | Where-Object {$_.CommandLine -match '--type=renderer'}).Count -gt 0);Backend=($children.Count -gt 0);OwnHost=(@($ids | Where-Object {$_ -in $ancestors}).Count -gt 0)}
}
function Get-LogFiles {
    $roots=@((Join-Path $env:LOCALAPPDATA 'Codex\Logs'),(Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\Logs'))
    return @($roots | Where-Object {Test-Path -LiteralPath $_} | ForEach-Object {Get-ChildItem -LiteralPath $_ -File -Recurse -Filter '*.log' -ErrorAction Stop} | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 16)
}
function Read-StartupEvidence([datetime]$Since,$ProcessIds=@()) {
    $selected=@(Get-LogFiles | Where-Object {$_.LastWriteTimeUtc -ge $Since.ToUniversalTime()})
    $lines=[Collections.Generic.List[string]]::new()
    foreach ($file in $selected) {
        if ($ProcessIds.Count -gt 0 -and -not @($ProcessIds | Where-Object {$file.Name -match ('-'+$_+'-t')}).Count) { continue }
        foreach ($line in Get-Content -LiteralPath $file.FullName -Tail 2500 -ErrorAction Stop) {
            if ($line -match '^(\d{4}-\d{2}-\d{2}T\S+)') {
                $time=[datetimeoffset]::MinValue
                if ([datetimeoffset]::TryParse($Matches[1],[ref]$time) -and $time.UtcDateTime -ge $Since.ToUniversalTime()) { $lines.Add($line) }
            }
        }
    }
    # Do not log complete desktop lines: they can contain conversation data and paths.
    $body=$lines -join "`n"
    return [pscustomobject]@{
        Window=($body -match 'window (ready-to-show|main frame finished load).*appearance=primary|rendererWindowVisible=true.*windowType=electron')
        Handshake=($body -match 'initialize_handshake_result .*outcome=success|Codex CLI initialized')
        Eperm=($body -match '(?im)^.*(\[StdioConnection\]|\[AppServerConnection\]).*spawn EPERM')
        RelocatedCli=($body -match '(?im)^.*(\[StdioConnection\]|\[AppServerConnection\]).*(OpenAI[\\/]+Codex[\\/]+bin[\\/]+[0-9a-f]{16}[\\/]+codex\.exe)')
        Transport=($body -match 'transport_connect_failed|Transport start failed')
        AppServer=($body -match '(?im)^.*app.?server.*(failed|error)|^.*(failed|error).*app.?server')
        Relocation=($body -match 'bundled_executable_relocation_failed')
        ShellTimeout=($body -match 'Failed to load shell env.*timed_out')
        CrossDevice=($body -match 'EXDEV')
        Files=@($selected | ForEach-Object {$_.Name})
    }
}
function Get-Staging([string]$Id) {
    if (-not (Test-Path -LiteralPath $script:RuntimeRoot)) { return @() }
    return @(Get-ChildItem -LiteralPath $script:RuntimeRoot -Directory -Force | Where-Object {$_.Name -match '^\.staging-([0-9a-f]{16})-[A-Za-z0-9]+$'} | ForEach-Object {
        $null=$_.Name -match '^\.staging-([0-9a-f]{16})-'
        [pscustomobject]@{Name=$_.Name;Id=$Matches[1];Current=($Matches[1] -eq $Id);Path=$_.FullName;LastWrite=$_.LastWriteTimeUtc}
    })
}
function Wait-App($Package,[datetime]$Since) {
    $until=(Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $state=Get-AppState $Package
        $evidence=Read-StartupEvidence $Since $state.Ids
        if ($state.Window -or $state.Renderer -or $evidence.Window) { return [pscustomobject]@{Healthy=$true;State=$state;Evidence=$evidence} }
        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $until)
    return [pscustomobject]@{Healthy=$false;State=$state;Evidence=$evidence}
}
function Stop-ProvenStall($Package,$State,$Evidence) {
    if ($State.Window -or $State.Renderer -or $State.Backend -or $State.OwnHost -or $Evidence.Window -or $Evidence.Handshake) { throw 'Active/possibly healthy app detected; close Codex normally before repair.' }
    foreach ($entry in $State.Processes) {
        $fresh=Get-CimInstance Win32_Process -Filter "ProcessId=$($entry.ProcessId)" -ErrorAction Stop
        if ($fresh -and $fresh.ExecutablePath -eq $entry.ExecutablePath -and $fresh.CreationDate -eq $entry.CreationDate) {
            Stop-Process -Id $entry.ProcessId -Force -ErrorAction Stop
        }
    }
    Start-Sleep -Seconds 2
    if (@((Get-AppState $Package).Processes).Count -gt 0) { throw 'Codex processes remain; no runtime files changed.' }
}
function Repair-Runtime($Package,[string]$Id) {
    $current=Find-Package
    if ($current.FullName -ne $Package.FullName) { throw 'Package updated during this run; retry launcher.' }
    if (@((Get-AppState $Package).Processes).Count -gt 0) { throw 'Close Codex before modifying its runtime.' }
    $destination=Assert-SafePath (Join-Path $script:RuntimeRoot $Id) $script:Base
    $null=[IO.Directory]::CreateDirectory($script:RuntimeRoot)
    $temp=Assert-SafePath (Join-Path $script:RuntimeRoot ('.selfheal-'+[guid]::NewGuid().ToString('N').Substring(0,8))) $script:Base
    $null=[IO.Directory]::CreateDirectory($temp)
    $repairProgress=$null; $repairSuccess=$false
    try {
    $repairProgress=Start-RepairProgress
    $sourceInventory=Get-Inventory $Package.Source
    Write-Event 'repair_start' @{version=$Package.Version;runtimeId=$Id;sourceCount=$sourceInventory.Count;temporary=$temp}
    # Direct executable invocation, no cmd /c; /G copies readable EFS data to plaintext.
    $savedErrorAction=$ErrorActionPreference
    $copyOutput=[Collections.Generic.Queue[string]]::new()
    $copyCount=0
    $sourcePrefix=$Package.Source.TrimEnd('\')+'\'
    $progressTimer=[Diagnostics.Stopwatch]::StartNew()
    try {
        $ErrorActionPreference='Continue'
        Update-RepairProgress $repairProgress '正在复制文件' 0 '' ("0 / $($sourceInventory.Count) 个文件")
        # /F emits source -> destination for each file. Stream it instead of
        # buffering the whole command; keep only the final diagnostic lines.
        & "$env:SystemRoot\System32\xcopy.exe" ($Package.Source+'\*') ($temp+'\') /E /I /H /K /R /Y /G /F 2>&1 | ForEach-Object {
            $line=[string]$_
            $copyOutput.Enqueue($line)
            if ($copyOutput.Count -gt 3) { $null=$copyOutput.Dequeue() }
            $separator=$line.IndexOf(' -> ')
            if ($separator -gt 0 -and $line.StartsWith($sourcePrefix,[StringComparison]::OrdinalIgnoreCase)) {
                $relative=$line.Substring($sourcePrefix.Length,$separator-$sourcePrefix.Length).Replace('\','/')
                if ($sourceInventory.ContainsKey($relative)) {
                    $copyCount++
                    # xcopy announces a file before its write finishes. Reserve
                    # 100% for a successful exit, and throttle console redraws.
                    $percent=[Math]::Min(99,[int][Math]::Floor(100.0*$copyCount/[Math]::Max(1,$sourceInventory.Count)))
                    if ($copyCount -eq 1 -or $copyCount -eq $sourceInventory.Count -or $progressTimer.ElapsedMilliseconds -ge 300) {
                        Update-RepairProgress $repairProgress '正在复制文件' $percent $relative ("$copyCount / $($sourceInventory.Count) 个文件")
                        $progressTimer.Restart()
                    }
                }
            }
        }
        $copyExit=$LASTEXITCODE

    } finally {
        $ErrorActionPreference=$savedErrorAction
        $progressTimer.Stop()
    }
    Write-Event 'xcopy' @{exitCode=$copyExit;summary=(($copyOutput | Select-Object -Last 3) -join ' ')}
    if ($copyExit -ne 0) { throw "xcopy failed ($copyExit); original runtime retained, incomplete temp retained at $temp" }
    # xcopy can return 0 while silently omitting a deeply nested path (reproduced
    # on this machine). Recover only missing long-path files, using readable bytes,
    # not their encryption metadata. Any other mismatch is a hard failure.
    Update-RepairProgress $repairProgress '正在检查并补齐长路径文件' -1 '复制阶段结束，正在检查完整性'
    $precheck=Compare-Runtime $Package.Source $temp
    $recovered=0
    foreach ($rel in $precheck.Bad) {
        $from=Join-Path $Package.Source $rel; $to=Join-Path $temp $rel
        if ([IO.File]::Exists((LongPath $to)) -or ($from.Length -lt 260 -and $to.Length -lt 260)) { throw "Unexpected xcopy omission or mismatch: $rel. Original retained." }
        $null=Assert-SafePath $to $script:Base
        $null=[IO.Directory]::CreateDirectory((LongPath (Split-Path $to)))
        $inputStream=[IO.File]::OpenRead((LongPath $from)); $outputStream=$null
        try {
            $outputStream=[IO.File]::Open((LongPath $to),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            $inputStream.CopyTo($outputStream)
        } finally { $inputStream.Dispose(); if ($outputStream) {$outputStream.Dispose()} }
        $recovered++
    }
    if ($recovered) { Write-Event 'long_path_recovery' @{fileCount=$recovered;method='readable bytes; exclusive new files in temporary runtime'} }
    Update-RepairProgress $repairProgress '正在校验文件' -1 '正在逐一核对所有文件的 SHA-256，请稍候'
    $check=Compare-Runtime $Package.Source $temp -AllHashes
    if (-not $check.Complete -or $check.ExtraCount -ne 0) { throw "Copy failed complete SHA256 verification; original retained. Source=$($check.SourceCount), destination=$($check.DestinationCount), bad=$($check.Bad.Count). Temp=$temp" }
    if ((Find-Package).FullName -ne $Package.FullName -or @((Get-AppState $Package).Processes).Count -gt 0) { throw 'Package/process changed during copy; verified temp retained, no publish.' }
    Update-RepairProgress $repairProgress '正在应用修复' -1 '校验通过，正在切换运行环境'
    # Same-parent rename. Preserve an existing destination for manual rollback.
    $backup=$null
    if ([IO.Directory]::Exists($destination)) {
        $backup=Assert-SafePath ($destination+'.backup-'+[guid]::NewGuid().ToString('N')) $script:Base
        $null=Assert-SafePath $destination $script:Base
        [IO.Directory]::Move($destination,$backup)
    }
    try { $null=Assert-SafePath $temp $script:Base; [IO.Directory]::Move($temp,$destination) }
    catch { if ($backup -and -not [IO.Directory]::Exists($destination)) { [IO.Directory]::Move($backup,$destination) }; throw }
    Write-Event 'repair_complete' @{runtimeId=$Id;sourceCount=$check.SourceCount;destinationCount=$check.DestinationCount;verification='all-file SHA256';backup=$backup}
    $repairSuccess=$true
    } finally { Stop-RepairProgress $repairProgress $repairSuccess }
    Invoke-RuntimeCleanup $Package $Id
}
function Get-LaunchError($ErrorRecord) {
    $exception=$ErrorRecord.Exception
    while ($exception.InnerException) { $exception=$exception.InnerException }
    $nativeCode=$null
    if ($exception -is [ComponentModel.Win32Exception]) { $nativeCode=$exception.NativeErrorCode }
    return @{message=$exception.Message;exceptionType=$exception.GetType().FullName;hresult=$exception.HResult;nativeErrorCode=$nativeCode}
}
function Start-DirectApp($Package,[string]$CliPath) {
    # Avoid ShellExecute/explorer and launch the executable from the AppX manifest.
    # Codex is the requested interactive app, so its window must not be hidden.
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=$Package.Exe
    $start.WorkingDirectory=Split-Path $Package.Exe
    $start.UseShellExecute=$false
    $start.CreateNoWindow=$false
    $start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Normal
    if ($CliPath) { $start.EnvironmentVariables['CODEX_CLI_PATH']=$CliPath }
    $process=[Diagnostics.Process]::Start($start)
    if (-not $process) { throw 'Process creation returned no process.' }
    try { return [int]$process.Id } finally { $process.Dispose() }
}
function Start-RegisteredApp([string]$Aumid) {
    $identityPattern='^'+[regex]::Escape($PackageName)+'_[A-Za-z0-9]+![A-Za-z0-9._-]+$'
    if ($Aumid -notmatch $identityPattern) { throw 'Unexpected AppX application identity.' }
    if (-not ('CodexSelfHeal.AppActivation' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace CodexSelfHeal {
  [ComImport, Guid("2e941141-7f97-4756-ba1d-9decde894a3d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IApplicationActivationManager {
    [PreserveSig] int ActivateApplication([MarshalAs(UnmanagedType.LPWStr)] string appId,
      [MarshalAs(UnmanagedType.LPWStr)] string arguments, uint options, out uint processId);
    [PreserveSig] int ActivateForFile([MarshalAs(UnmanagedType.LPWStr)] string appId,
      IntPtr items, [MarshalAs(UnmanagedType.LPWStr)] string verb, out uint processId);
    [PreserveSig] int ActivateForProtocol([MarshalAs(UnmanagedType.LPWStr)] string appId,
      IntPtr items, out uint processId);
  }
  public static class AppActivation {
    public static uint Launch(string appId) {
      object instance = Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")));
      try {
        uint pid;
        int hr = ((IApplicationActivationManager)instance).ActivateApplication(appId, null, 0, out pid);
        Marshal.ThrowExceptionForHR(hr);
        return pid;
      } finally { if (Marshal.IsComObject(instance)) Marshal.ReleaseComObject(instance); }
    }
  }
}
'@
    }
    return [int][CodexSelfHeal.AppActivation]::Launch($Aumid)
}
function Start-App($Package,[string]$CliPath) {
    $method='direct_process'
    Write-Event 'launch_attempt' @{method=$method;executable=$Package.Exe;launcherVersion=$script:LauncherVersion}
    try { $childPid=Start-DirectApp $Package $CliPath }
    catch {
        $details=Get-LaunchError $_; $details['method']=$method
        Write-Event 'launch_attempt_failed' $details
        # Broker activation cannot guarantee inheritance of a temporary CLI override.
        if ($CliPath) { throw }
        $method='registered_app_activation'
        Write-Event 'launch_attempt' @{method=$method;aumid=$Package.Aumid}
        try { $childPid=Start-RegisteredApp $Package.Aumid }
        catch {
            $details=Get-LaunchError $_; $details['method']=$method
            Write-Event 'launch_attempt_failed' $details
            throw
        }
    }
    # A returned PID means requested, not ready. Wait-App verifies the actual window.
    Write-Event 'launch_requested' @{method=$method;processId=$childPid;version=$Package.Version;temporaryCliOverride=$CliPath}
}
function Invoke-Launcher {
    $pkg=Find-Package
    Write-Event 'package' @{version=$pkg.Version;install=$pkg.Install;appxStatus='Ok';diagnose=[bool]$Diagnose;launcherVersion=$script:LauncherVersion}
    $state=Get-AppState $pkg
    $evidence=Read-StartupEvidence ((Get-Date).AddDays(-1)) $state.Ids
    $id=$null; $check=$null; $staging=@()
    if (Test-Path -LiteralPath $pkg.Source -PathType Container) {
        try { $id=Get-RuntimeIdentity $pkg.Source }
        catch {
            Write-Event 'runtime_schema_unsupported' @{repair=$false;reason=$_.Exception.Message}
            if ($Diagnose) { return 2 }
            if (-not $state.Window -and -not $state.Renderer -and -not $state.Backend -and -not $state.OwnHost) { Start-App $pkg }
            return 2
        }
        $staging=@(Get-Staging $id)
        $check=Compare-Runtime $pkg.Source (Join-Path $script:RuntimeRoot $id)
        Write-Event 'runtime_check' @{runtimeId=$id;stagingFound=($staging.Count -gt 0);currentStaging=@($staging | Where-Object Current).Count;stagingIds=@($staging | ForEach-Object Id | Select-Object -Unique);complete=$check.Complete;sourceCount=$check.SourceCount;destinationCount=$check.DestinationCount;badCount=$check.Bad.Count;missingExamples=@($check.Bad | Select-Object -First 3);repair=$false}
    } else { Write-Event 'runtime_layout_absent' @{repair=$false;reason='No bundled cua_node; use normal launcher.'} }
    Write-Event 'process_check' @{processCount=@($state.Processes).Count;window=$state.Window;renderer=$state.Renderer;backend=$state.Backend;ownHost=$state.OwnHost}
    Write-Event 'desktop_evidence' @{window=$evidence.Window;handshake=$evidence.Handshake;spawnEperm=$evidence.Eperm;transport=$evidence.Transport;appServerError=$evidence.AppServer;shellTimeout=$evidence.ShellTimeout;crossDevice=$evidence.CrossDevice}
    if ($Diagnose) { Write-Event 'diagnose_complete'; return 0 }
    if ($state.Window -or $state.Renderer -or ($state.Processes.Count -gt 0 -and $evidence.Window)) { Write-Event 'already_running' @{repair=$false;integrityRepairDeferred=($check -and -not $check.Complete)}; return 0 }
    if ($state.Backend -or $state.OwnHost) { Write-Event 'running_protected' @{repair=$false;reason='Backend or own host is active, but window is not confirmed.'}; return 2 }
    $since=Get-Date
    if (@($state.Processes).Count -eq 0 -and $check -and -not $check.Complete) {
        if (@($staging | Where-Object Current).Count -gt 0 -or ($RepairIncomplete -and (Test-Path -LiteralPath (Join-Path $script:RuntimeRoot $id)))) { Repair-Runtime $pkg $id }
    }
    if ($id -and $check -and $check.Complete) { Invoke-RuntimeCleanup $pkg $id }
    Start-App $pkg
    $result=Wait-App $pkg $since
    if ($result.Healthy) { Write-Event 'launch_ok' @{window=$result.State.Window;renderer=$result.State.Renderer;logWindow=$result.Evidence.Window}; return 0 }
    # Evaluate only after a bounded startup wait; a new update gets its first normal try.
    if ($id) {
        $staging=@(Get-Staging $id | Where-Object Current)
        $check=Compare-Runtime $pkg.Source (Join-Path $script:RuntimeRoot $id)
        if ($staging.Count -gt 0 -and -not $check.Complete) {
            Stop-ProvenStall $pkg $result.State $result.Evidence
            Repair-Runtime $pkg $id
            $since=Get-Date; Start-App $pkg; $result=Wait-App $pkg $since
            if ($result.Healthy) { Write-Event 'launch_ok_after_repair' @{runtimeId=$id}; return 0 }
        }
    }
    Write-Event 'launch_unconfirmed' @{renderer=$result.State.Renderer;backend=$result.State.Backend;spawnEperm=$result.Evidence.Eperm;transport=$result.Evidence.Transport;appServerError=$result.Evidence.AppServer;relocatedCliEvidence=$result.Evidence.RelocatedCli}
    if ($TryCliFallback -and $result.Evidence.Eperm -and $result.Evidence.RelocatedCli -and -not $result.Evidence.Handshake) {
        $cli=Join-Path (Split-Path $pkg.Exe) 'resources\codex.exe'
        if ($cli -match '(?i)\\program files\\windowsapps\\') { Write-Event 'cli_fallback_skipped' @{reason='This path is relocated again by the current desktop implementation.'}; return 2 }
        if (-not (Test-Path -LiteralPath $cli -PathType Leaf)) { throw 'Bundled CLI missing.' }
        if ([Environment]::GetEnvironmentVariable('CODEX_CLI_PATH','User') -or $env:CODEX_CLI_PATH) { throw 'Existing CLI override detected; leave it unchanged.' }
        Stop-ProvenStall $pkg $result.State $result.Evidence
        $since=Get-Date; Start-App $pkg $cli; $retry=Wait-App $pkg $since
        Write-Event 'temporary_cli_retry' @{success=$retry.Healthy;userEnvironmentChanged=$false}
        if ($retry.Healthy) { return 0 }
    }
    return 2
}

# Dot-sourcing loads functions for isolated tests without performing any action.
if ($MyInvocation.InvocationName -eq '.') { return }
$lock=$null; $runtimeMutex=$null; $exitCode=1; $logReady=$false; $openingLog=$false
try {
    $script:LogPath=Resolve-LauncherLogPath $LogPath
    $runtimeMutex=Enter-RuntimeMutex $script:RuntimeRoot
    $openingLog=$true
    $logFull=Assert-SafePath $script:LogPath (Split-Path -Parent $script:LogPath)
    $null=[IO.Directory]::CreateDirectory((Split-Path $logFull))
    $script:LogPath=$logFull
    # Protect a shared custom log too; the lock file disappears when its handle closes.
    $lock=[IO.FileStream]::new(($logFull+'.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None,4096,[IO.FileOptions]::DeleteOnClose)
    $null=[IO.File]::AppendAllText($logFull,'',[Text.UTF8Encoding]::new($false))
    $logReady=$true; $openingLog=$false
    if ((Test-Path -LiteralPath $logFull) -and (Get-Item -LiteralPath $logFull).Length -gt 5MB) {
        $archive=Assert-SafePath ($logFull+'.1') (Split-Path $logFull)
        [IO.File]::Copy($logFull,$archive,$true); [IO.File]::WriteAllText($logFull,'')
    }
    Assert-LauncherEnvironment
    $exitCode=Invoke-Launcher
} catch {
    $failure=$_
    try {
        $details=Get-LaunchError $failure
        $details['repairNotAssumedSuccessful']=$true
        $details['scriptLine']=$failure.InvocationInfo.ScriptLineNumber
        $details['launcherVersion']=$script:LauncherVersion
        if ($logReady) { Write-Event 'error' $details }
        else {
            if ($openingLog) { Write-Host '  [失败] 日志无法创建或写入。请将脚本放到可写文件夹，或使用 -LogPath 指定可写位置。' -ForegroundColor Yellow }
            else { Write-EventSummary 'error' $details }
        }
    } catch {
        Write-Host ('  [失败] '+$failure.Exception.Message) -ForegroundColor Red
        Write-Host '  本次错误未能写入日志，请保留终端提示。' -ForegroundColor Yellow
    }
    $exitCode=1
} finally {
    if ($lock) {$lock.Dispose()}
    if ($runtimeMutex) { $runtimeMutex.ReleaseMutex(); $runtimeMutex.Dispose() }
    Write-Host ''
    Write-Host ("  日志路径："+$script:LogPath) -ForegroundColor Cyan
    if (-not $logReady) { Write-Host '  本次未写入日志。' -ForegroundColor Yellow }
}
exit $exitCode
