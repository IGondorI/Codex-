#requires -Version 5.1
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$version=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'release\version.txt')).Trim()
$name="Codex-SelfHeal-v$version-windows"
$path=Join-Path $PSScriptRoot ('dist\'+$name+'.zip')
$expected=@('Codex-SelfHeal.cmd','Codex-SelfHeal.ps1','Codex-Progress.ps1','Codex-Cleanup.ps1','先读我.txt')
$zip=[IO.Compression.ZipFile]::OpenRead($path)
try {
    if ($zip.Entries.Count -ne $expected.Count) { throw 'Unexpected release file count' }
    foreach ($entry in $zip.Entries) {
        if ($entry.FullName -notin @($expected | ForEach-Object {$name+'/'+$_})) { throw 'Unexpected release entry' }
        $inputStream=$entry.Open(); $memory=[IO.MemoryStream]::new()
        try { $inputStream.CopyTo($memory); $bytes=$memory.ToArray() }
        finally { $inputStream.Dispose(); $memory.Dispose() }
        if ($entry.Name.EndsWith('.ps1')) {
            if ($bytes.Length -lt 3 -or $bytes[0] -ne 239 -or $bytes[1] -ne 187 -or $bytes[2] -ne 191) { throw 'PowerShell UTF-8 BOM missing' }
            $tokens=$null; $errors=$null
            $null=[Management.Automation.Language.Parser]::ParseInput([Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF),[ref]$tokens,[ref]$errors)
            if ($errors.Count) { throw 'Packaged PowerShell does not parse' }
        }
        $text=[Text.Encoding]::UTF8.GetString($bytes)
        if ($text -match '(?<!\r)\n') { throw 'Packaged text must use Windows line endings' }
    }
} finally { $zip.Dispose() }
$expectedHash=([IO.File]::ReadAllText($path+'.sha256') -split ' ')[0]
if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedHash) { throw 'Checksum mismatch' }
Write-Host 'PASS: ZIP contains only the five intended files, Windows line endings, valid PowerShell BOM/syntax, and matching SHA256'
