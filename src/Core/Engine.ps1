<#
    Polish - execution engine

    Actions never mutate the system directly. They call these helpers, and the
    helpers record the reversal into the run manifest before making the change.
    That is the whole trick: undo cannot be forgotten because writing the undo
    IS how you make the change.
#>

function New-PolishContext {
    param($Sys, $Run, [switch]$DryRun, [scriptblock]$Logger)

    [pscustomobject]@{
        Sys        = $Sys
        Run        = $Run
        DryRun     = [bool]$DryRun
        Logger     = $Logger
        BytesFreed = [long]0
        RamFreed   = [long]0
        Changed    = 0
        Failed     = 0
        Notes      = [System.Collections.ArrayList]::new()
    }
}

function Write-PolishCtx {
    param($Ctx, [string]$Message, [string]$Level = 'info')
    if ($Ctx.Logger) { & $Ctx.Logger $Message $Level }
}

function Add-PolishNote {
    param($Ctx, [string]$Message)
    [void]$Ctx.Notes.Add($Message)
}

# ===========================================================================
#  Registry
# ===========================================================================
function Set-PolishReg {
    param($Ctx, [string]$Path, [string]$Name, $Value, [string]$Type = 'DWord', [string]$ActionId = '', [string]$Label = '')

    if (-not $Label) { $Label = "$Name = $Value" }

    # read current state for the undo record
    $existed = $false
    $prevValue = $null
    $prevType = $null
    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($item.Property -contains $Name) {
            $existed = $true
            $prevValue = (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name
            $prevType = $item.GetValueKind($Name).ToString()
        }
    } catch { }

    # already correct? say nothing, change nothing, record nothing
    if ($existed -and "$prevValue" -eq "$Value") {
        return $false
    }

    if ($Ctx.DryRun) {
        Write-PolishCtx $Ctx ("would set   $Label") 'ok'
        $Ctx.Changed++
        return $true
    }

    try {
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
        Set-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -Type $Type -Force -ErrorAction Stop

        Add-PolishUndo -Run $Ctx.Run -ActionId $ActionId -Type 'registry' -Data @{
            Path      = $Path
            Name      = $Name
            PrevValue = $prevValue
            PrevType  = $prevType
            Existed   = $existed
        }
        $was = 'unset'
        if ($existed) { $was = "$prevValue" }
        Write-PolishCtx $Ctx ("set   $Label   (was $was)") 'ok'
        $Ctx.Changed++
        return $true
    } catch {
        Write-PolishCtx $Ctx ("FAILED  $Label : $($_.Exception.Message)") 'warn'
        $Ctx.Failed++
        return $false
    }
}

# ===========================================================================
#  Services
# ===========================================================================
function Set-PolishService {
    param($Ctx, [string]$Name, [ValidateSet('Manual', 'Disabled', 'Automatic')][string]$StartupType = 'Manual',
          [switch]$StopNow, [string]$ActionId = '')

    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return $false }

    if (Test-PolishProtectedService -Name $svc.Name -DisplayName $svc.DisplayName) {
        Write-PolishCtx $Ctx ("protected, not touching service '$Name'") 'skip'
        return $false
    }

    $wmi = Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $svc.Name) -ErrorAction SilentlyContinue
    $prevMode = 'Manual'
    if ($wmi -and $wmi.StartMode) { $prevMode = $wmi.StartMode }
    $prevStatus = $svc.Status.ToString()

    $wantMode = $StartupType
    $normPrev = $prevMode
    if ($normPrev -eq 'Auto') { $normPrev = 'Automatic' }
    if ($normPrev -ieq $wantMode -and -not $StopNow) { return $false }

    if ($Ctx.DryRun) {
        Write-PolishCtx $Ctx ("would set service  {0,-34} {1} -> {2}" -f $Name, $normPrev, $wantMode) 'ok'
        $Ctx.Changed++
        return $true
    }

    try {
        Set-Service -Name $svc.Name -StartupType $wantMode -ErrorAction Stop
        Add-PolishUndo -Run $Ctx.Run -ActionId $ActionId -Type 'service' -Data @{
            Name          = $svc.Name
            PrevStartMode = $prevMode
            PrevStatus    = $prevStatus
        }
        if ($StopNow -and $svc.Status -eq 'Running') {
            Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue
        }
        Write-PolishCtx $Ctx ("service  {0,-34} {1} -> {2}" -f $Name, $normPrev, $wantMode) 'ok'
        $Ctx.Changed++
        return $true
    } catch {
        Write-PolishCtx $Ctx ("FAILED service $Name : $($_.Exception.Message)") 'warn'
        $Ctx.Failed++
        return $false
    }
}

# ===========================================================================
#  Scheduled tasks
# ===========================================================================
function Disable-PolishTask {
    param($Ctx, [string]$TaskPath, [string]$TaskName, [string]$ActionId = '')

    $t = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $t) { return $false }
    if ($t.State -eq 'Disabled') { return $false }

    if ($Ctx.DryRun) {
        Write-PolishCtx $Ctx ("would disable task  $TaskPath$TaskName") 'ok'
        $Ctx.Changed++
        return $true
    }

    try {
        Disable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop | Out-Null
        Add-PolishUndo -Run $Ctx.Run -ActionId $ActionId -Type 'task' -Data @{
            Path      = $TaskPath
            Name      = $TaskName
            PrevState = $t.State.ToString()
        }
        Write-PolishCtx $Ctx ("task disabled  $TaskPath$TaskName") 'ok'
        $Ctx.Changed++
        return $true
    } catch {
        Write-PolishCtx $Ctx ("FAILED task $TaskName : $($_.Exception.Message)") 'warn'
        $Ctx.Failed++
        return $false
    }
}

# ===========================================================================
#  Startup entries
# ===========================================================================
$script:StartupDisabledBlob = [byte[]](3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

function Disable-PolishStartup {
    param($Ctx, [string]$Scope = 'User', [string]$Kind = 'Run', [string]$Name, [string]$ActionId = '')

    $hive = 'HKCU:'
    if ($Scope -eq 'Machine') { $hive = 'HKLM:' }
    $key = "$hive\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\$Kind"

    $existed = $false
    $prevBlob = $null
    try {
        $item = Get-Item -LiteralPath $key -ErrorAction Stop
        if ($item.Property -contains $Name) {
            $existed = $true
            $prevBlob = @((Get-ItemProperty -LiteralPath $key -Name $Name -ErrorAction Stop).$Name)
            if ($prevBlob.Count -gt 0 -and $prevBlob[0] -eq 3) { return $false }  # already disabled
        }
    } catch { }

    if ($Ctx.DryRun) {
        Write-PolishCtx $Ctx ("would disable startup  $Name") 'ok'
        $Ctx.Changed++
        return $true
    }

    try {
        if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force -ErrorAction Stop | Out-Null }
        Set-ItemProperty -LiteralPath $key -Name $Name -Value $script:StartupDisabledBlob -Type Binary -Force -ErrorAction Stop

        Add-PolishUndo -Run $Ctx.Run -ActionId $ActionId -Type 'startup' -Data @{
            Key      = $key
            Name     = $Name
            PrevBlob = $prevBlob
            Existed  = $existed
        }
        Write-PolishCtx $Ctx ("startup disabled  $Name") 'ok'
        $Ctx.Changed++
        return $true
    } catch {
        Write-PolishCtx $Ctx ("FAILED startup $Name : $($_.Exception.Message)") 'warn'
        $Ctx.Failed++
        return $false
    }
}

# ===========================================================================
#  Store apps
# ===========================================================================
function Remove-PolishAppx {
    param($Ctx, [string]$Name, [string]$WingetId = '', [string]$ActionId = '', [switch]$AllUsers)

    if (Test-PolishProtectedAppx -Name $Name) {
        Write-PolishCtx $Ctx ("PROTECTED, refusing to remove  $Name") 'warn'
        return $false
    }

    $pkgs = @(Get-AppxPackage -Name $Name -ErrorAction SilentlyContinue)
    if ($pkgs.Count -eq 0) { return $false }

    if ($Ctx.DryRun) {
        Write-PolishCtx $Ctx ("would remove  $Name") 'ok'
        $Ctx.Changed++
        return $true
    }

    $any = $false
    foreach ($p in $pkgs) {
        try {
            Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop
            Add-PolishUndo -Run $Ctx.Run -ActionId $ActionId -Type 'appx' -Data @{
                Name            = $Name
                PackageFullName = $p.PackageFullName
                WingetId        = $WingetId
            }
            Write-PolishCtx $Ctx ("removed  $Name") 'ok'
            $Ctx.Changed++
            $any = $true
        } catch {
            Write-PolishCtx $Ctx ("could not remove $Name : $($_.Exception.Message)") 'warn'
            $Ctx.Failed++
        }
    }

    # Also drop the provisioned copy, otherwise Windows reinstalls it for the
    # next user profile and sometimes for this one on a feature update.
    if ($any -and $AllUsers -and $Ctx.Sys.IsAdmin) {
        try {
            $prov = Get-AppxProvisionedPackage -Online -ErrorAction Stop |
                    Where-Object { $_.DisplayName -eq $Name }
            foreach ($pp in $prov) {
                Remove-AppxProvisionedPackage -Online -PackageName $pp.PackageName -ErrorAction Stop | Out-Null
                Write-PolishCtx $Ctx ("  also de-provisioned (will not return for new users)") 'ok'
            }
        } catch { }
    }

    return $any
}

# ===========================================================================
#  Caches. Not reversible, and labelled as such in the catalog.
# ===========================================================================
function Clear-PolishPath {
    param($Ctx, [string]$Path, [string]$Label, [int]$OlderThanHours = 0, [string[]]$PreserveNames = @())

    if (-not (Test-Path -LiteralPath $Path)) { return [long]0 }

    $cutoff = (Get-Date).AddHours(-1 * $OlderThanHours)
    $freed = [long]0
    $locked = 0

    $files = Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue
    foreach ($f in $files) {
        $skip = $false
        foreach ($n in $PreserveNames) {
            if ($f.FullName -like "*\$n\*") { $skip = $true; break }
        }
        if ($skip) { continue }
        if ($OlderThanHours -gt 0 -and $f.LastWriteTime -gt $cutoff) { continue }

        $size = $f.Length
        if ($Ctx.DryRun) { $freed += $size; continue }
        try { [System.IO.File]::Delete($f.FullName); $freed += $size } catch { $locked++ }
    }

    # tidy up directories we just emptied
    if (-not $Ctx.DryRun) {
        $dirs = Get-ChildItem -LiteralPath $Path -Recurse -Force -Directory -ErrorAction SilentlyContinue |
                Sort-Object { $_.FullName.Length } -Descending
        foreach ($d in $dirs) {
            try {
                if (-not (Get-ChildItem -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue)) {
                    [System.IO.Directory]::Delete($d.FullName, $false)
                }
            } catch { }
        }
    }

    if ($freed -gt 0) {
        $verb = 'freed'
        if ($Ctx.DryRun) { $verb = 'would free' }
        $msg = '{0,-44} {1} {2}' -f $Label, $verb, (Format-PolishSize $freed)
        if ($locked -gt 0) { $msg += "  ($locked in use, left alone)" }
        Write-PolishCtx $Ctx $msg 'ok'
        $Ctx.BytesFreed += $freed
    }
    return $freed
}
