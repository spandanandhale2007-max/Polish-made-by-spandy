<#
    Polish - command line and run orchestration
#>

function Write-PolishLine {
    param([string]$Message, [string]$Level = 'info')

    $prefix = '         '
    $colour = 'Gray'
    switch ($Level) {
        'ok'    { $prefix = '  [ok]   '; $colour = 'Green' }
        'warn'  { $prefix = '  [!]    '; $colour = 'Yellow' }
        'skip'  { $prefix = '  [-]    '; $colour = 'DarkGray' }
        'head'  { $prefix = '';          $colour = 'Cyan' }
        'title' { $prefix = '';          $colour = 'White' }
        default { $prefix = '         '; $colour = 'Gray' }
    }

    $line = $prefix + $Message
    if ($script:PolishLogFile) {
        Add-Content -LiteralPath $script:PolishLogFile -Value ((Get-Date -Format 'HH:mm:ss') + ' ' + $line) -Encoding utf8 -ErrorAction SilentlyContinue
    }
    if (-not $script:PolishQuiet) { Write-Host $line -ForegroundColor $colour }
}

function Initialize-PolishLog {
    $dir = Join-Path (Get-PolishDataDir) 'logs'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $script:PolishLogFile = Join-Path $dir ('polish-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
    Get-ChildItem -LiteralPath $dir -Filter 'polish-*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -Skip 30 |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Show-PolishBanner {
    param($Sys)
    Write-PolishLine '' 'head'
    Write-PolishLine ('  P O L I S H   {0}' -f $script:PolishVersion) 'title'
    Write-PolishLine '  Windows tune-up that can undo itself' 'head'
    Write-PolishLine '' 'head'
    foreach ($l in (Get-PolishSystemSummary -Sys $Sys)) { Write-PolishLine ('  ' + $l) 'info' }
    Write-PolishLine '' 'head'
}

<#
  Resolve which actions to run.

  Preset:
    safe      every Safe action that needs no reboot. The default.
    recommend safe plus the Moderate actions most people want.
    all       everything applicable. Advanced included. Asks for confirmation.
#>
<#
  Normalise a list argument.

  powershell.exe -File script.ps1 -Only a,b binds ONE string "a,b" rather than
  a two element array, so the documented comma syntax would otherwise select
  nothing at all. Split on comma, semicolon and whitespace, and trim, so every
  calling style works:
      -Only a,b            (from powershell -File)
      -Only a,b            (from inside PowerShell, already an array)
      -Only "a; b"
#>
function Expand-PolishList {
    param([string[]]$Value)
    if (-not $Value) { return @() }
    $out = @()
    foreach ($v in $Value) {
        if ($null -eq $v) { continue }
        foreach ($part in ($v -split '[,;\s]+')) {
            $p = $part.Trim()
            if ($p) { $out += $p }
        }
    }
    return @($out)
}

function Resolve-PolishSelection {
    param($Actions, [string]$Preset = 'safe', [string[]]$Only, [string[]]$Skip)

    $sel = @()
    $Only = Expand-PolishList -Value $Only
    $Skip = Expand-PolishList -Value $Skip

    if ($Only.Count -gt 0) {
        # case insensitive so -Only Optimize and -Only optimize both work
        $wanted = @($Only | ForEach-Object { $_.ToLowerInvariant() })
        $unmatched = [System.Collections.ArrayList]::new()
        foreach ($w in $Only) { [void]$unmatched.Add($w) }

        foreach ($a in $Actions) {
            $hitId  = $wanted -contains $a.Id.ToLowerInvariant()
            $hitMod = $wanted -contains $a.Module.ToLowerInvariant()
            if ($hitId -or $hitMod) {
                if ($sel -notcontains $a) { $sel += $a }
                foreach ($u in @($unmatched)) {
                    if ($u -ieq $a.Id -or $u -ieq $a.Module) { $unmatched.Remove($u) }
                }
            }
        }
        foreach ($u in $unmatched) {
            Write-PolishLine ("'{0}' is not an action id or module on this machine (see -List)" -f $u) 'warn'
        }
    } else {
        switch ($Preset) {
            # Slow actions (DISM, SFC) are excluded from presets: nobody running
            # '-Preset safe' is expecting a 30 minute scan. Ask for them by id.
            'safe'      { $sel = @($Actions | Where-Object { $_.Risk -eq 'Safe' -and -not $_.Reboot -and -not $_.Slow }) }
            'recommend' { $sel = @($Actions | Where-Object { $_.Risk -in @('Safe', 'Moderate') -and -not $_.Reboot -and -not $_.Slow }) }
            'all'       { $sel = @($Actions) }
            'default'   { $sel = @($Actions | Where-Object { $_.Default }) }
            default     { $sel = @($Actions | Where-Object { $_.Default }) }
        }
    }

    if ($Skip.Count -gt 0) {
        $drop = @($Skip | ForEach-Object { $_.ToLowerInvariant() })
        $sel = @($sel | Where-Object {
            ($drop -notcontains $_.Id.ToLowerInvariant()) -and ($drop -notcontains $_.Module.ToLowerInvariant())
        })
    }
    return $sel
}

function Invoke-PolishRun {
    [CmdletBinding()]
    param(
        $Sys,
        $Selected,
        [switch]$DryRun,
        [switch]$NoRestorePoint,
        [scriptblock]$Logger,
        [string]$Mode = 'Custom'
    )

    if (-not $Logger) { $Logger = ${function:Write-PolishLine} }

    $run = New-PolishRun -Mode $Mode
    $ctx = New-PolishContext -Sys $Sys -Run $run -DryRun:$DryRun -Logger $Logger

    # ---- restore point -------------------------------------------------
    $mutating = @($Selected | Where-Object { $_.Undo -ne 'None' -or $_.Id -like 'apps.*' })
    if (-not $DryRun -and -not $NoRestorePoint -and $mutating.Count -gt 0) {
        & $Logger '' 'head'
        & $Logger '=== Safety net ===' 'head'
        if (-not $Sys.IsAdmin) {
            & $Logger 'not elevated, so no system restore point. Per-action undo still works.' 'warn'
        } else {
            $rp = New-PolishRestorePoint -Description ('Before Polish ' + $script:PolishVersion)
            if ($rp.Created) {
                & $Logger 'system restore point created' 'ok'
                $run.RestorePoint = $true
            } else {
                & $Logger ("could not create a restore point: {0}" -f $rp.Reason) 'warn'
                & $Logger 'per-action undo still works and is saved either way' 'warn'
                $run.RestorePoint = $false
            }
        }
    }

    # ---- run -----------------------------------------------------------
    $byModule = $Selected | Group-Object Module
    foreach ($grp in $byModule) {
        & $Logger '' 'head'
        & $Logger ("=== {0} ===" -f $grp.Name.ToUpper()) 'head'

        foreach ($a in $grp.Group) {
            if ($a.NeedsAdmin -and -not $Sys.IsAdmin) {
                & $Logger ("{0}: needs administrator, skipped" -f $a.Name) 'skip'
                continue
            }
            & $Logger ('-- ' + $a.Name) 'info'
            try {
                & $a.Apply $ctx
            } catch {
                & $Logger ("action '{0}' failed: {1}" -f $a.Id, $_.Exception.Message) 'warn'
                $ctx.Failed++
            }
        }
    }

    # ---- save manifest -------------------------------------------------
    $manifestPath = $null
    if (-not $DryRun -and $run.Entries.Count -gt 0) {
        $manifestPath = Save-PolishRun -Run $run
    }

    # ---- report --------------------------------------------------------
    & $Logger '' 'head'
    & $Logger '=== Result ===' 'head'
    if ($DryRun) { & $Logger 'DRY RUN. Nothing was changed.' 'warn' }
    & $Logger ("changes made     : {0}" -f $ctx.Changed) 'info'
    if ($ctx.Failed -gt 0) { & $Logger ("failed           : {0}" -f $ctx.Failed) 'warn' }
    $wouldBe = ''
    if ($DryRun) { $wouldBe = ' (would be)' }
    if ($ctx.BytesFreed -gt 0) { & $Logger ("disk reclaimed   : {0}{1}" -f (Format-PolishSize $ctx.BytesFreed), $wouldBe) 'ok' }
    if ($ctx.RamFreed -gt 0)   { & $Logger ("RAM released     : {0}{1}" -f (Format-PolishSize $ctx.RamFreed), $wouldBe) 'ok' }
    & $Logger ("reversible items : {0}" -f $run.Entries.Count) 'info'

    foreach ($n in $ctx.Notes) { & $Logger ('note: ' + $n) 'warn' }

    if ($manifestPath) {
        & $Logger '' 'head'
        & $Logger ("Undo this run with:  Polish.ps1 -Undo Last") 'ok'
        & $Logger ("manifest: {0}" -f $manifestPath) 'skip'
    }

    $needReboot = @($Selected | Where-Object { $_.Reboot })
    if ($needReboot.Count -gt 0 -and -not $DryRun) {
        & $Logger '' 'head'
        & $Logger 'A restart is needed for: ' 'warn'
        foreach ($r in $needReboot) { & $Logger ('  - ' + $r.Name) 'warn' }
    }

    return [pscustomobject]@{
        Run          = $run
        Context      = $ctx
        ManifestPath = $manifestPath
    }
}

<#
  Does reversing this run actually need elevation? True only if the manifest
  holds something machine scope: an HKLM value, a service, a scheduled task, or
  a machine-wide startup entry. Everything under HKCU reverses as the user.
#>
function Test-PolishUndoNeedsAdmin {
    param([string]$Which = 'Last')

    $runs = Get-PolishRuns
    if ($runs.Count -eq 0) { return $false }

    $target = $null
    if ($Which -eq 'Last') { $target = $runs[0] }
    else { $target = $runs | Where-Object { $_.BaseName -eq $Which -or $_.Name -eq $Which } | Select-Object -First 1 }
    if (-not $target) { return $false }

    $m = Import-PolishRun -Path $target.FullName
    if (-not $m) { return $false }

    foreach ($e in @($m.Entries)) {
        switch ($e.Type) {
            'service' { return $true }
            'task'    { return $true }
            'registry' {
                if ($e.Data.Path -match '^HKLM:') { return $true }
            }
            'startup' {
                if ($e.Data.Key -match '^HKLM:') { return $true }
            }
        }
    }
    return $false
}

function Invoke-PolishUndo {
    [CmdletBinding()]
    param([string]$Which = 'Last', [scriptblock]$Logger)

    if (-not $Logger) { $Logger = ${function:Write-PolishLine} }

    $runs = Get-PolishRuns
    if ($runs.Count -eq 0) {
        & $Logger 'no Polish runs recorded on this machine, nothing to undo' 'warn'
        return
    }

    $target = $null
    if ($Which -eq 'Last') {
        $target = $runs[0]
    } elseif ($Which -eq 'List') {
        & $Logger '' 'head'
        & $Logger '=== Recorded runs ===' 'head'
        foreach ($r in $runs) {
            $m = Import-PolishRun -Path $r.FullName
            if ($m) {
                & $Logger ('{0}   {1,-10} {2,3} reversible item(s)' -f $m.RunId, $m.Mode, @($m.Entries).Count) 'info'
            }
        }
        & $Logger '' 'head'
        & $Logger 'Undo one with:  Polish.ps1 -Undo <run-id>' 'info'
        return
    } else {
        $target = $runs | Where-Object { $_.BaseName -eq $Which -or $_.Name -eq $Which } | Select-Object -First 1
        if (-not $target) {
            & $Logger "no run named '$Which'. Use -Undo List to see them." 'warn'
            return
        }
    }

    $manifest = Import-PolishRun -Path $target.FullName
    if (-not $manifest) { & $Logger 'manifest could not be read' 'warn'; return }

    & $Logger '' 'head'
    & $Logger ("=== Undoing {0} ===" -f $manifest.RunId) 'head'
    & $Logger ("{0} item(s) recorded, reversing in opposite order" -f @($manifest.Entries).Count) 'info'

    $results = Undo-PolishRun -Run $manifest -Log $Logger

    $ok = @($results | Where-Object { $_.Reversed }).Count
    $no = @($results | Where-Object { -not $_.Reversed }).Count

    & $Logger '' 'head'
    & $Logger ("reversed      : {0}" -f $ok) 'ok'
    if ($no -gt 0) {
        & $Logger ("not reversible: {0}" -f $no) 'warn'
        & $Logger 'Store apps and deleted caches cannot be restored from a manifest.' 'warn'
        if ($manifest.RestorePoint) {
            & $Logger 'This run did create a system restore point; use rstrui.exe to go further back.' 'warn'
        }
    }

    # mark as undone so it does not get undone twice
    try {
        $manifest | Add-Member -NotePropertyName UndoneAt -NotePropertyValue (Get-Date).ToString('o') -Force
        $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $target.FullName -Encoding utf8
    } catch { }
}

function Show-PolishList {
    param($Actions)

    Write-PolishLine '' 'head'
    Write-PolishLine '=== Available actions on this machine ===' 'head'

    foreach ($m in (Get-PolishModules -Actions $Actions)) {
        Write-PolishLine '' 'head'
        Write-PolishLine ("  {0}" -f $m.ToUpper()) 'head'
        foreach ($a in ($Actions | Where-Object { $_.Module -eq $m })) {
            $flags = @()
            if ($a.Default)    { $flags += 'default' }
            if ($a.Reboot)     { $flags += 'reboot' }
            if ($a.NeedsAdmin) { $flags += 'admin' }
            $f = ''
            if ($flags.Count) { $f = '  [' + ($flags -join ', ') + ']' }

            $lvl = 'info'
            if ($a.Risk -eq 'Advanced') { $lvl = 'warn' }
            Write-PolishLine ('  {0,-26} {1,-9} undo:{2,-8} {3}{4}' -f $a.Id, $a.Risk, $a.Undo, $a.Name, $f) $lvl
        }
    }
    Write-PolishLine '' 'head'
    Write-PolishLine '  Run a preset:   -Preset safe | recommend | all' 'info'
    Write-PolishLine '  Or pick:        -Only gaming.gamemode,cache.temp' 'info'
    Write-PolishLine '  Or a module:    -Only Optimize,Caches' 'info'
    Write-PolishLine '  Preview safely: add -DryRun' 'info'
    Write-PolishLine '' 'head'
}

function Show-PolishProcesses {
    $rows = Get-PolishProcessReport
    $reap = Get-PolishReapSummary -Rows $rows

    Write-PolishLine '' 'head'
    Write-PolishLine '=== What is running ===' 'head'
    Write-PolishLine ('  {0,-30} {1,5} {2,10}  {3}' -f 'PROCESS', '#', 'RAM', 'VERDICT') 'info'

    foreach ($r in $rows) {
        $lvl = 'info'
        $verdict = $r.Class
        switch ($r.Class) {
            'Reapable'  { $lvl = 'ok';   $verdict = 'will close' }
            'Protected' { $lvl = 'skip'; $verdict = 'protected' }
            'Service'   { $lvl = 'skip'; $verdict = 'service' }
            'InUse'     { $lvl = 'info'; $verdict = 'in use' }
            'Sync'      { $lvl = 'warn'; $verdict = 'cloud sync' }
            'UserApp'   { $lvl = 'warn'; $verdict = 'in use? opt-in only' }
        }
        Write-PolishLine ('  {0,-30} {1,5} {2,10}  {3}' -f $r.Name, $r.Count, (Format-PolishSize $r.Bytes), $verdict) $lvl
    }

    Write-PolishLine '' 'head'
    if ($reap.Count -gt 0) {
        Write-PolishLine ("{0} background app(s) holding {1} could be closed right now" -f $reap.Count, (Format-PolishSize $reap.Bytes)) 'ok'
        Write-PolishLine 'Close them with:  Polish.ps1 -Only optimize.closebg' 'info'
    } else {
        Write-PolishLine 'nothing obviously reapable is running' 'ok'
    }
}
