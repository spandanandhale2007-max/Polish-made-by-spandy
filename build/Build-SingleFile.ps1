<#
    Polish - bundler

    Inlines src/ into one dist/Polish.ps1 so it can be served over HTTP and run
    with  irm <url> | iex  . Run this before every release.

    It replaces the POLISH_BUNDLE_MARKER region in the root Polish.ps1 with the
    concatenated sources, in dependency order.
#>

[CmdletBinding()]
param(
    [string]$Root,
    [string]$OutFile,
    [switch]$Check
)

$ErrorActionPreference = 'Stop'

if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
if (-not $OutFile) { $OutFile = Join-Path $Root 'dist\Polish.ps1' }

$entry = Join-Path $Root 'Polish.ps1'
if (-not (Test-Path -LiteralPath $entry)) { throw "entry script not found: $entry" }

# dependency order matters: Detect and Safety define things Engine and Catalog use
$sources = @(
    'src\Core\Detect.ps1'
    'src\Core\Safety.ps1'
    'src\Core\Engine.ps1'
    'src\Modules\Processes.ps1'
    'src\Modules\Bloat.ps1'
    'src\Core\Catalog.ps1'
    'src\Cli.ps1'
    'src\UI\Window.ps1'
)

Write-Host 'Polish bundler' -ForegroundColor Cyan
Write-Host ''

# ---- read and verify every source ---------------------------------------
$parts = @()
$totalLines = 0
foreach ($s in $sources) {
    $p = Join-Path $Root $s
    if (-not (Test-Path -LiteralPath $p)) { throw "missing source: $s" }

    $errors = $null; $tokens = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        Write-Host "  SYNTAX ERROR in $s" -ForegroundColor Red
        foreach ($e in $errors) { Write-Host ("    line {0}: {1}" -f $e.Extent.StartLineNumber, $e.Message) -ForegroundColor Red }
        throw "refusing to bundle a file that does not parse"
    }

    $text = Get-Content -LiteralPath $p -Raw
    $lines = ($text -split "`n").Count
    $totalLines += $lines
    Write-Host ("  {0,-30} {1,5} lines  ok" -f $s, $lines) -ForegroundColor Green

    $parts += ''
    $parts += ('# ' + ('=' * 74))
    $parts += "#  $s"
    $parts += ('# ' + ('=' * 74))
    $parts += $text
}

# ---- splice into the entry script ---------------------------------------
$entryText = Get-Content -LiteralPath $entry -Raw

$startRx = '(?ms)#region POLISH_BUNDLE_MARKER.*?#endregion POLISH_BUNDLE_MARKER'
if ($entryText -notmatch $startRx) { throw 'POLISH_BUNDLE_MARKER region not found in Polish.ps1' }

$banner = @"
#region POLISH_BUNDLED_SOURCES
# ---------------------------------------------------------------------------
#  This file is GENERATED. Do not edit it by hand.
#  Built from src/ by build/Build-SingleFile.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm')
#  Edit the files under src/ and rebuild.
# ---------------------------------------------------------------------------
$($parts -join "`r`n")
#endregion POLISH_BUNDLED_SOURCES
"@

$bundled = [regex]::Replace($entryText, $startRx, { $banner })

# ---- write ---------------------------------------------------------------
$outDir = Split-Path -Parent $OutFile
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

# UTF-8 with NO byte-order mark.
#
# This is not a style preference, it is required. Invoke-RestMethod returns the
# BOM as a literal U+FEFF character at the start of the string, and
# "﻿<#" stops PowerShell recognising the opening comment block, so the
# whole help header gets parsed as code and  irm <url> | iex  dies with
# "Unexpected token 'param'". Reading the same file from disk hides the problem,
# because Get-Content treats the BOM as an encoding signature and strips it.
# Keep this $false.
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($OutFile, $bundled, $enc)

# ---- verify the output ---------------------------------------------------
$errors = $null; $tokens = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($OutFile, [ref]$tokens, [ref]$errors)

Write-Host ''
if ($errors -and $errors.Count -gt 0) {
    Write-Host '  BUNDLE DOES NOT PARSE' -ForegroundColor Red
    foreach ($e in $errors) { Write-Host ("    line {0}: {1}" -f $e.Extent.StartLineNumber, $e.Message) -ForegroundColor Red }
    throw 'bundle failed verification'
}

# ---- verify the irm | iex path specifically -----------------------------
# ParseFile above reads from disk and would not catch a BOM regression. This
# reproduces what the network actually hands to iex: the decoded text, BOM and
# all, turned into a scriptblock.
$firstBytes = [System.IO.File]::ReadAllBytes($OutFile)
if ($firstBytes.Length -ge 3 -and $firstBytes[0] -eq 0xEF -and $firstBytes[1] -eq 0xBB -and $firstBytes[2] -eq 0xBF) {
    throw 'bundle starts with a UTF-8 BOM, which breaks irm | iex. Write it with UTF8Encoding($false).'
}
$asServed = [System.Text.Encoding]::UTF8.GetString($firstBytes)
try {
    [void][scriptblock]::Create($asServed)
    Write-Host '  irm | iex simulation: parses as a scriptblock' -ForegroundColor Green
} catch {
    Write-Host '  BUNDLE FAILS THE irm | iex PATH' -ForegroundColor Red
    Write-Host ("    {0}" -f $_.Exception.Message) -ForegroundColor Red
    throw 'bundle would fail when piped from the web'
}

$size = (Get-Item -LiteralPath $OutFile).Length
Write-Host ('  wrote {0}' -f $OutFile) -ForegroundColor Green
Write-Host ('  {0:N0} bytes, {1:N0} source lines, parses clean' -f $size, $totalLines) -ForegroundColor Green

if ($size -gt 2MB) {
    Write-Host '  warning: over 2 MB is slow to pipe from the web' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '  Publish dist\Polish.ps1 to your repo, then share:' -ForegroundColor White
Write-Host '    irm https://raw.githubusercontent.com/YOUR-USERNAME/polish/main/dist/Polish.ps1 | iex' -ForegroundColor Cyan
Write-Host ''
