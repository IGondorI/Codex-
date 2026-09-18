# Cleanup is deliberately conservative across all Windows sessions.
function Get-CleanupBlockers {
    $rootPrefix=[IO.Path]::GetFullPath($script:RuntimeRoot).TrimEnd('\')+'\'
    return @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
        $_.Name -match '^(?i:codex|chatgpt)\.exe$' -or
        ($_.ExecutablePath -and $_.ExecutablePath.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase)) -or
        ($_.Name -match '^(?i:node|node_repl)\.exe$' -and -not $_.ExecutablePath)
    })
}
function Invoke-RuntimeCleanup($Package,[string]$Id) {
    if ($Diagnose) { return }
    try {
        if (@(Get-CleanupBlockers).Count -gt 0) {
            Write-Event 'cleanup_deferred' @{reason='Codex/runtime process is active or cannot be identified safely'}
            return
        }
        $root=Assert-SafePath $script:RuntimeRoot $script:Base
        $current=Assert-SafePath (Join-Path $root $Id) $root
        if ($Id -notmatch '^[0-9a-f]{16}$' -or (Find-Package).FullName -ne $Package.FullName -or (Get-RuntimeIdentity $Package.Source) -ne $Id) { throw 'Package/runtime identity changed; cleanup skipped.' }
        if (-not [IO.Directory]::Exists((LongPath $current))) { return }
        $directories=@(Get-ChildItem -LiteralPath $root -Force -Directory)
        $old=@($directories | Where-Object {$_.Name -match '^[0-9a-f]{16}$' -and $_.Name -ne $Id} | Sort-Object LastWriteTimeUtc,Name -Descending)
        $backups=@($directories | Where-Object {$_.Name -match '^[0-9a-f]{16}\.backup-[0-9a-f]{32}$'} | Sort-Object LastWriteTimeUtc,Name -Descending)
        # Keep the current runtime, one previous runtime, and one latest backup.
        $candidates=@($directories | Where-Object {$_.Name -match '^\.selfheal-[0-9a-f]{8}$|^\.staging-[0-9a-f]{16}-[A-Za-z0-9]+$'})
        $candidates+=@($old | Select-Object -Skip 1)
        $candidates+=@($backups | Select-Object -Skip 1)
        if ($candidates.Count -eq 0) { return }
        $check=Compare-Runtime $Package.Source $current -AllHashes
        if (-not $check.Complete -or $check.ExtraCount -ne 0) { throw 'Current runtime failed full verification; nothing cleaned.' }
        foreach ($candidate in $candidates) {
            # Re-resolve the exact target before every recursive deletion.
            $target=Assert-SafePath $candidate.FullName $root
            if ($target -eq $root -or $target -eq $current -or [IO.Path]::GetDirectoryName($target) -ne $root) { throw 'Unsafe cleanup target.' }
            # Inventory rejects reparse points anywhere inside the tree.
            $inventory=Get-Inventory $target
            if ((Find-Package).FullName -ne $Package.FullName -or @(Get-CleanupBlockers).Count -gt 0) { throw 'Package/process changed; remaining cleanup deferred.' }
            $bytes=0L
            foreach ($rel in $inventory.Keys) {
                $file=Assert-SafePath (Join-Path $target $rel) $target
                $bytes+=$inventory[$rel]
                [IO.File]::SetAttributes((LongPath $file),[IO.FileAttributes]::Normal)
            }
            if (@(Get-CleanupBlockers).Count -gt 0) { throw 'Process started during cleanup; deletion deferred.' }
            $null=Assert-SafePath $target $root
            [IO.Directory]::Delete((LongPath $target),$true)
            Write-Event 'cleanup_removed' @{directory=$candidate.Name;files=$inventory.Count;bytes=$bytes}
        }
    } catch {
        # Cleanup must never prevent an otherwise valid launch.
        Write-Event 'cleanup_deferred' @{reason=$_.Exception.Message}
    }
}
