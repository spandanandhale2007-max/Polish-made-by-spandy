<#
.SYNOPSIS
    Polish - a Windows tune-up and debloat tool that can undo itself.

.DESCRIPTION
    Closes background apps, trims startup, clears caches, removes Store bloat,
    tunes gaming and privacy settings. Every reversible change is recorded to a
    manifest so a single command puts it all back.

    Safe by default: with no arguments it opens the window with only
    fully-reversible, no-restart actions pre-ticked.

.PARAMETER Gui
    Open the window. This is the default when no other mode is given.

.PARAMETER Preset
    safe       every Safe action that needs no reboot
    recommend  safe plus the Moderate actions most people want
    all        everything applicable to this machine
    default    only the pre-ticked set

.PARAMETER Only
    Action ids or module names to run, comma separated.

.PARAMETER Skip
    Action ids or module names to exclude.

.PARAMETER DryRun
    Show exactly what would happen and change nothing.

.PARAMETER Undo
    Last, List, or a specific run id.

.PARAMETER List
    Print every action that applies to this machine, then exit.

.PARAMETER Processes
    Print what is running and what would be closed, then exit.

.EXAMPLE
    .\Polish.ps1
    Opens the window.

.EXAMPLE
    .\Polish.ps1 -Preset safe -DryRun
    Previews the safe preset without touching anything.

.EXAMPLE
    .\Polish.ps1 -Only optimize.closebg,optimize.trimram
    The one-click "free up my RAM now" path, no restart.

.EXAMPLE
    .\Polish.ps1 -Undo Last
    Reverses the most recent run.

.LINK
    https://github.com/YOUR-USERNAME/polish
#>

[CmdletBinding(DefaultParameterSetName = 'Gui')]
param(
    [Parameter(ParameterSetName = 'Gui')]
    [switch]$Gui,

    [Parameter(ParameterSetName = 'Run')]
    [ValidateSet('safe', 'recommend', 'all', 'default')]
    [string]$Preset,

    [Parameter(ParameterSetName = 'Run')]
    [string[]]$Only,

    [Parameter(ParameterSetName = 'Run')]
    [string[]]$Skip,

    [Parameter(ParameterSetName = 'Run')]
    [switch]$DryRun,

    [Parameter(ParameterSetName = 'Run')]
    [switch]$NoRestorePoint,

    [Parameter(ParameterSetName = 'Run')]
    [switch]$Yes,

    [Parameter(ParameterSetName = 'Undo')]
    [string]$Undo,

    [Parameter(ParameterSetName = 'List')]
    [switch]$List,

    [Parameter(ParameterSetName = 'Processes')]
    [switch]$Processes,

    [switch]$Quiet,
    [switch]$NoElevate,
    [switch]$NoPause
)

$ErrorActionPreference = 'Continue'
$script:PolishVersion  = '1.0.0'
$script:PolishQuiet    = [bool]$Quiet
$script:PolishLogFile  = $null

# ---------------------------------------------------------------------------
#  Source loading
#
#  In the repo this dot-sources src/. The bundler replaces the whole marked
#  block with the concatenated sources so the published Polish.ps1 is one file
#  that works with  irm <url> | iex
# ---------------------------------------------------------------------------
#region POLISH_BUNDLE_MARKER
$polishRoot = $PSScriptRoot
if (-not $polishRoot) { $polishRoot = (Get-Location).Path }

$polishSources = @(
    'src\Core\Detect.ps1'
    'src\Core\Safety.ps1'
    'src\Core\Engine.ps1'
    'src\Modules\Processes.ps1'
    'src\Modules\Bloat.ps1'
    'src\Core\Catalog.ps1'
    'src\Cli.ps1'
    'src\UI\Window.ps1'
)
foreach ($s in $polishSources) {
    $p = Join-Path $polishRoot $s
    if (Test-Path -LiteralPath $p) {
        . $p
    } else {
        Write-Host "Polish: missing source file $s" -ForegroundColor Red
        Write-Host "Run from the repo root, or use the single-file build from dist\." -ForegroundColor Red
        exit 1
    }
}
#endregion POLISH_BUNDLE_MARKER

# ---------------------------------------------------------------------------
#  Elevation
#
#  Opt-in, but offered. Most of Polish works unelevated; the actions that do not
#  are skipped with a clear message rather than failing silently. When the user
#  asked for something that needs admin, we relaunch once with their selection
#  preserved rather than making them retype it.
# ---------------------------------------------------------------------------
function Request-PolishElevation {
    param([string[]]$ForwardArgs)

    if ($NoElevate) { return $false }

    $exe = 'powershell.exe'
    if ($PSVersionTable.PSEdition -eq 'Core') { $exe = 'pwsh.exe' }

    $self = $PSCommandPath
    if (-not $self) { return $false }   # running from irm|iex, cannot re-invoke a file

    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $self) + $ForwardArgs
    try {
        Start-Process -FilePath $exe -ArgumentList $a -Verb RunAs -Wait -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------------------
#  Main
# ---------------------------------------------------------------------------
Initialize-PolishLog
$sys = Get-PolishSystem
$catalog = Get-PolishCatalog
$actions = Get-PolishApplicableActions -Sys $sys -Catalog $catalog

switch ($PSCmdlet.ParameterSetName) {

    'List' {
        Show-PolishBanner -Sys $sys
        Show-PolishList -Actions $actions
    }

    'Processes' {
        Show-PolishProcesses
    }

    'Undo' {
        Show-PolishBanner -Sys $sys

        # Only ask for elevation if this manifest actually contains machine-scope
        # changes. A run that only touched HKCU reverses fine as a normal user,
        # and prompting for admin anyway trains people to click through UAC.
        if (-not $sys.IsAdmin -and $Undo -ne 'List') {
            if (Test-PolishUndoNeedsAdmin -Which $Undo) {
                Write-PolishLine 'This run changed machine-wide settings, so undo needs administrator.' 'warn'
                if (Request-PolishElevation -ForwardArgs @('-Undo', $Undo)) { break }
                Write-PolishLine 'elevation declined; machine-wide items will be skipped' 'warn'
            }
        }
        Invoke-PolishUndo -Which $Undo
    }

    'Run' {
        Show-PolishBanner -Sys $sys

        # NOT $preset: PowerShell variable names are case insensitive, so that
        # would reassign the $Preset parameter and re-run its ValidateSet
        # against an empty string.
        $presetName = $Preset
        if (-not $presetName) { $presetName = 'default' }
        $selected = Resolve-PolishSelection -Actions $actions -Preset $presetName -Only $Only -Skip $Skip

        if ($selected.Count -eq 0) {
            Write-PolishLine 'nothing selected. Use -List to see available actions.' 'warn'
            break
        }

        # elevate if the selection needs it and we are not there yet
        $wantsAdmin = @($selected | Where-Object { $_.NeedsAdmin }).Count -gt 0
        if ($wantsAdmin -and -not $sys.IsAdmin -and -not $DryRun) {
            Write-PolishLine ("{0} of the selected actions need administrator. Relaunching elevated..." -f @($selected | Where-Object { $_.NeedsAdmin }).Count) 'warn'
            $fwd = @()
            if ($Preset)         { $fwd += @('-Preset', $Preset) }
            if ($Only)           { $fwd += @('-Only', ($Only -join ',')) }
            if ($Skip)           { $fwd += @('-Skip', ($Skip -join ',')) }
            if ($NoRestorePoint) { $fwd += '-NoRestorePoint' }
            $fwd += '-Yes'
            if (Request-PolishElevation -ForwardArgs $fwd) { break }
            Write-PolishLine 'elevation declined; admin-only actions will be skipped' 'warn'
        }

        Write-PolishLine ("{0} action(s) selected:" -f $selected.Count) 'info'
        foreach ($a in $selected) {
            $lvl = 'info'
            if ($a.Risk -eq 'Advanced') { $lvl = 'warn' }
            Write-PolishLine ('  {0,-26} {1,-9} undo:{2}' -f $a.Id, $a.Risk, $a.Undo) $lvl
        }

        $risky = @($selected | Where-Object { $_.Risk -ne 'Safe' })
        if ($risky.Count -gt 0 -and -not $Yes -and -not $DryRun -and -not $Quiet) {
            Write-PolishLine '' 'head'
            Write-PolishLine ("{0} action(s) are not in the Safe tier." -f $risky.Count) 'warn'
            $ans = Read-Host '  Continue? (y/N)'
            if ($ans -notmatch '^(y|yes)$') { Write-PolishLine 'cancelled' 'warn'; break }
        }

        [void](Invoke-PolishRun -Sys $sys -Selected $selected -DryRun:$DryRun `
                   -NoRestorePoint:$NoRestorePoint -Mode $presetName)
    }

    default {
        # GUI
        if (Get-Command Show-PolishWindow -ErrorAction SilentlyContinue) {
            Show-PolishWindow -Sys $sys -Actions $actions
        } else {
            Show-PolishBanner -Sys $sys
            Write-PolishLine 'the window could not be loaded on this system' 'warn'
            Show-PolishList -Actions $actions
        }
    }
}

if (-not $NoPause -and -not $Quiet -and $PSCmdlet.ParameterSetName -ne 'Gui' -and $Host.Name -eq 'ConsoleHost') {
    Write-Host ''
    Write-Host '  Press any key to close...' -ForegroundColor DarkGray
    try { [void]$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { }
}
