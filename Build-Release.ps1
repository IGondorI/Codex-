#requires -Version 5.1
[CmdletBinding()]
param([string]$OutputDirectory = 'dist')
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression
$version=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'release\version.txt')).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid release version.' }
$main=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Codex-SelfHeal.ps1'))
if ($main -notmatch ('\$script:LauncherVersion\s*=\s*'''+[regex]::Escape($version)+'''')) { throw 'Release version differs from launcher version.' }
if (-not [IO.Path]::IsPathRooted($OutputDirectory)) { $OutputDirectory=Join-Path $PSScriptRoot $OutputDirectory }
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
$null=[IO.Directory]::CreateDirectory($OutputDirectory)
$name="Codex-SelfHeal-v$version-windows"
$archivePath=Join-Path $OutputDirectory ($name+'.zip')
# Fixed allowlist: never package local logs, installation records, or .git.
$files=[ordered]@{
    'Codex-SelfHeal.cmd'='Codex-SelfHeal.cmd'
    'Codex-SelfHeal.ps1'='Codex-SelfHeal.ps1'
    'Codex-Progress.ps1'='Codex-Progress.ps1'
    'Codex-Cleanup.ps1'='Codex-Cleanup.ps1'
    'release\QUICKSTART.txt'='先读我.txt'
}
$stream=[IO.File]::Open($archivePath,[IO.FileMode]::Create,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try {
    $zip=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$true)
    try {
        foreach ($source in $files.Keys) {
            $text=[IO.File]::ReadAllText((Join-Path $PSScriptRoot $source)).Replace("`r`n","`n").Replace("`n","`r`n")
            $encoding=[Text.UTF8Encoding]::new(-not $source.EndsWith('.cmd'))
            $entry=$zip.CreateEntry(($name+'/'+$files[$source]),[IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime=[datetimeoffset]::new(2000,1,1,0,0,0,[timespan]::Zero)
            $output=$entry.Open()
            try {
                $preamble=$encoding.GetPreamble(); $output.Write($preamble,0,$preamble.Length)
                $bytes=$encoding.GetBytes($text); $output.Write($bytes,0,$bytes.Length)
            } finally { $output.Dispose() }
        }
    } finally { $zip.Dispose() }
} finally { $stream.Dispose() }
$hash=(Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText(($archivePath+'.sha256'),($hash+'  '+[IO.Path]::GetFileName($archivePath)+"`n"),[Text.Encoding]::ASCII)
Write-Host "Release package: $archivePath"
Write-Host "SHA256: $hash"
