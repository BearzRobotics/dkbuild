# Builds PowerShell's external help (MAML XML, what Get-Help reads) from the PowerShell-Docs
# Markdown, with platyPS, offline: the same source Microsoft's Update-Help content comes from.
# Usage: pwsh -NoProfile -File gen-help.ps1 <PowerShell-Docs reference/7.x dir> <platyPS module dir> <output dir>
param([string]$Reference, [string]$PlatyPS, [string]$Out)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PlatyPS 'Microsoft.PowerShell.PlatyPS.psd1')
foreach ($m in Get-ChildItem -LiteralPath $Reference -Directory) {
    # the module page (<Module>.md) is not a command; About/ holds the about_ topics (made below)
    $files = Get-ChildItem -LiteralPath $m.FullName -Filter *.md -File | Where-Object { $_.BaseName -ne $m.Name }
    if (-not $files) { continue }
    Write-Host "help: $($m.Name) ($($files.Count) commands)"
    $cmds = $files.FullName | Import-MarkdownCommandHelp
    Export-MamlCommandHelp -CommandHelp $cmds -OutputFolder (Join-Path $Out $m.Name) -Force | Out-Null
}
# about_ topics: plain text, the Markdown without its YAML header, as Get-Help reads
# <name>.help.txt files
$about = Join-Path $Out 'about'
New-Item -ItemType Directory -Force -Path $about | Out-Null
foreach ($f in Get-ChildItem -LiteralPath $Reference -Recurse -Filter 'about_*.md' -File) {
    $t = Get-Content -LiteralPath $f.FullName -Raw
    $t = [regex]::Replace($t, '\A---\r?\n.*?\r?\n---\r?\n', '', 'Singleline')
    Set-Content -LiteralPath (Join-Path $about ($f.BaseName + '.help.txt')) -Value $t -Encoding utf8NoBOM
}
