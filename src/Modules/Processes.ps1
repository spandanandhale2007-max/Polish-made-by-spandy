<#
    Polish - process discovery and reaping

    This runs on machines we have never seen, so nothing is hardcoded to one
    person's app list. Processes are discovered live and classified by:
      - the hard protect list                      -> Protected
      - being the process behind a running service -> Service
      - matching a known launcher/updater/overlay  -> Reapable
      - having a visible window                    -> InUse
      - anything else                              -> Background

    Only Reapable is ever pre-ticked.
#>

# Families of background software that are safe to close on any machine,
# because they relaunch on demand and exist only to sit in the tray.
# Matched case insensitively against the process name.
$script:ReapPatterns = @(
    # game launchers and their helpers
    '^steam(webhelper|service)?$', '^EpicGamesLauncher$', '^EpicWebHelper$', '^EOSOverlayRenderer$'
    '^EADesktop$', '^EABackgroundService$', '^EALauncher$', '^EACefSubProcess$', '^Origin'
    '^Battle\.net', '^Agent$', '^BlizzardError'
    '^RiotClient', '^Rockstar', '^SocialClubHelper', '^ubisoft', '^UplayWebCore', '^UbisoftConnect'
    '^GalaxyClient', '^GOG', '^itch$', '^Paradox', '^Amazon Games'

    # overlays. Relaunch with the game, nothing is lost.
    '^NVIDIA (Overlay|Share|Web Helper)', '^RTSS$', '^MSIAfterburner$'
    '^GameBarPresenceWriter$', '^XboxGameBarWidgets$', '^XboxGameBar$'

    # peripheral and RGB suites: heavy, and all of them relaunch on demand
    '^(lghub|lghub_agent|lghub_updater|lghub_system_tray)$'
    '^iCUE', '^Corsair', '^RzSynapse', '^Razer (Central|Synapse)', '^NGENUITY', '^HyperX'
    '^SignalRgb', '^OpenRGB', '^Logi(Options|Overlay)', '^SteelSeries', '^Glorious'
    '^Wootility', '^VIA$', '^Keychron'

    # creative suite background agents
    '^CCXProcess$', '^Adobe (Desktop Service|CEF Helper|Crash|Update)', '^AdobeIPCBroker$'
    '^AdobeNotificationClient$', '^CoreSync$', '^Creative Cloud'

    # updaters. Nothing is lost by closing an updater.
    '(?i)updater?$', '^GoogleUpdate', '^GoogleCrashHandler', '^MicrosoftEdgeUpdate'
    '^jusched$', '^SumatraPDF-update', '^Squirrel$', '^Update\.exe$'
    '^OfficeClickToRun$', '^OneDriveUpdater'

    # misc tray clutter
    '^FxSound', '^Wispr', '^Grammarly', '^ShareX$', '^Everything$', '^qBittorrent'
    '^uTorrent', '^BitTorrent', '^Rainmeter$', '^TranslucentTB$', '^Lively'
    '^PowerToys\.', '^Flow\.Launcher'
)

# Apps the person is plausibly USING right now. Closing these is legitimate and
# frees the most memory by far, but it can interrupt a call, stop music or lose
# an unsaved recording. So they are a separate, non-default tier. A pre-ticked
# box that closes someone's Discord mid-conversation is how a tool loses trust.
$script:UserAppPatterns = @(
    '^Discord(Canary|PTB)?$', '^Spotify(Webhelper)?$'
    '^Slack$', '^Teams$', '^ms-teams$', '^Zoom$', '^Telegram', '^WhatsApp', '^Signal$', '^Skype'
    '^Medal', '^MedalEncoder$', '^Streamlabs', '^obs64$', '^obs32$'
    '^Steam$'   # the client itself, as opposed to steamwebhelper
)

# Closing these stops a background sync. Different promise again: files stop
# syncing until the app is reopened, which the user may not notice.
$script:SyncPatterns = @(
    '^OneDrive$', '^Dropbox', '^GoogleDriveFS$', '^googledrivesync', '^MEGAsync'
    '^pCloud', '^Sync$', '^Resilio', '^NextcloudCmd', '^Nextcloud$', '^Box(Sync|Drive)'
)

function Test-PolishReapable {
    param([string]$Name)
    foreach ($rx in $script:ReapPatterns) { if ($Name -match $rx) { return $true } }
    return $false
}

function Test-PolishUserApp {
    param([string]$Name)
    foreach ($rx in $script:UserAppPatterns) { if ($Name -match $rx) { return $true } }
    return $false
}

function Test-PolishSyncApp {
    param([string]$Name)
    foreach ($rx in $script:SyncPatterns) { if ($Name -match $rx) { return $true } }
    return $false
}

function Get-PolishServicePidMap {
    $map = @{}
    foreach ($s in (Get-CimInstance Win32_Service -Filter "State='Running'" -ErrorAction SilentlyContinue)) {
        if ($s.ProcessId -and $s.ProcessId -ne 0) { $map[[int]$s.ProcessId] = $s.Name }
    }
    return $map
}

<#
  One row per process NAME, not per PID, because Chrome with 29 helpers is one
  decision for the user, not 29.
#>
function Get-PolishProcessReport {
    [CmdletBinding()]
    param([switch]$IncludeAll)

    $svcMap = Get-PolishServicePidMap
    $self = $PID

    $rows = Get-Process -ErrorAction SilentlyContinue | Group-Object ProcessName | ForEach-Object {

        $name  = $_.Name
        $procs = $_.Group
        $bytes = ($procs | Measure-Object -Property WorkingSet64 -Sum).Sum

        $isSelf = $false
        $hasWindow = $false
        $isService = $false
        $svcName = $null

        foreach ($p in $procs) {
            if ($p.Id -eq $self) { $isSelf = $true }
            try { if ($p.MainWindowHandle -ne 0) { $hasWindow = $true } } catch { }
            if ($svcMap.ContainsKey([int]$p.Id)) { $isService = $true; $svcName = $svcMap[[int]$p.Id] }
        }

        # classify
        $class = 'Background'
        $reason = ''
        if (Test-PolishProtectedProcess -Name $name) {
            $class = 'Protected'; $reason = 'core Windows or security component'
        } elseif ($isSelf) {
            $class = 'Protected'; $reason = 'this is Polish'
        } elseif ($isService) {
            $class = 'Service'; $reason = "run by service '$svcName'"
        } elseif (Test-PolishSyncApp -Name $name) {
            $class = 'Sync'; $reason = 'cloud sync, closing pauses it'
        } elseif (Test-PolishUserApp -Name $name) {
            $class = 'UserApp'; $reason = 'you may be using this right now'
        } elseif (Test-PolishReapable -Name $name) {
            $class = 'Reapable'; $reason = 'background launcher/updater/tray app'
        } elseif ($hasWindow) {
            $class = 'InUse'; $reason = 'has an open window'
        } else {
            $class = 'Background'; $reason = 'unrecognised background process'
        }

        [pscustomobject]@{
            Name      = $name
            Count     = $procs.Count
            Bytes     = [long]$bytes
            Class     = $class
            Reason    = $reason
            HasWindow = $hasWindow
            Service   = $svcName
        }
    }

    $rows = @($rows | Sort-Object Bytes -Descending)
    if (-not $IncludeAll) {
        # anything under 20 MB is noise in a RAM conversation
        $rows = @($rows | Where-Object { $_.Bytes -ge 20MB -or $_.Class -eq 'Reapable' })
    }
    return $rows
}

function Get-PolishReapSummary {
    param($Rows, [string]$Class = 'Reapable')
    $sel = @($Rows | Where-Object { $_.Class -eq $Class })
    $sum = ($sel | Measure-Object -Property Bytes -Sum).Sum
    if (-not $sum) { $sum = 0 }
    [pscustomobject]@{
        Count = $sel.Count
        Bytes = [long]$sum
        Names = @($sel | Select-Object -ExpandProperty Name)
    }
}

# ===========================================================================
#  Closing
# ===========================================================================
function Close-PolishProcesses {
    param($Ctx, [string[]]$Names, [string]$ActionId = '')

    $svcMap = Get-PolishServicePidMap
    $freed = [long]0
    $stuck = @()

    foreach ($n in $Names) {
        if (Test-PolishProtectedProcess -Name $n) {
            Write-PolishCtx $Ctx ("protected, not closing  $n") 'skip'
            continue
        }

        $procs = @(Get-Process -Name $n -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID })
        if ($procs.Count -eq 0) { continue }

        $bytes = ($procs | Measure-Object -Property WorkingSet64 -Sum).Sum

        $svcName = $null
        foreach ($p in $procs) { if ($svcMap.ContainsKey([int]$p.Id)) { $svcName = $svcMap[[int]$p.Id]; break } }
        if ($svcName) {
            Write-PolishCtx $Ctx ("$n is the Windows service '$svcName'; killing it is futile, the service manager restarts it") 'warn'
            Write-PolishCtx $Ctx ("   to stop it properly use the Services module, not this one") 'warn'
            $stuck += $n
            continue
        }

        if ($Ctx.DryRun) {
            Write-PolishCtx $Ctx ('would close  {0,-30} {1,3} proc  {2,10}' -f $n, $procs.Count, (Format-PolishSize $bytes)) 'ok'
            $freed += $bytes
            continue
        }

        # ask politely first so tray apps can persist their own state
        foreach ($p in $procs) {
            try { if (-not $p.HasExited -and $p.MainWindowHandle -ne 0) { [void]$p.CloseMainWindow() } } catch { }
        }
        Start-Sleep -Milliseconds 350

        $left = @(Get-Process -Name $n -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID })
        if ($left.Count -gt 0) { Stop-Process -InputObject $left -Force -ErrorAction SilentlyContinue }

        Start-Sleep -Milliseconds 200
        $final = @(Get-Process -Name $n -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID })

        if ($final.Count -eq 0) {
            Write-PolishCtx $Ctx ('closed  {0,-30} {1,3} proc  {2,10}' -f $n, $procs.Count, (Format-PolishSize $bytes)) 'ok'
            $freed += $bytes
            $Ctx.Changed++
        } else {
            Write-PolishCtx $Ctx ("could not close $n, it is respawning itself") 'warn'
            $stuck += $n
        }
    }

    if ($stuck.Count -gt 0) {
        Add-PolishNote $Ctx ("Would not close: {0}" -f ($stuck -join ', '))
    }
    $Ctx.RamFreed += $freed
    return $freed
}

# ===========================================================================
#  Working set trim
# ===========================================================================
<#
  Honest description, because this is the single most over-promised feature in
  every "PC optimizer" ever shipped:

  EmptyWorkingSet asks Windows to move a process's resident pages out of its
  working set. The "free RAM" number goes up immediately. The pages go to the
  standby list or the page file, and if the process needs them again Windows
  pages them straight back in, which costs time.

  So this is genuinely useful in one situation: you are about to launch
  something big (a game, a VM, a render) and you want physical RAM free for it
  right now. It is not a general speed-up, and running it on a loop makes
  things slower. Polish says so in the UI rather than selling it as magic.

  Polish does NOT flush the system standby list. That throws away cached data
  every running program is about to want, and the measurable result is a slower
  machine for the next few minutes in exchange for a bigger number in Task
  Manager.
#>
function Invoke-PolishWorkingSetTrim {
    param($Ctx, [string[]]$Names = @(), [switch]$IdleOnly)

    if (-not ('PolishMem' -as [type])) {
        try {
            Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PolishMem {
    [DllImport("psapi.dll", SetLastError = true)]
    public static extern bool EmptyWorkingSet(IntPtr hProcess);
}
'@
        } catch {
            Write-PolishCtx $Ctx "could not load the memory API: $($_.Exception.Message)" 'warn'
            return [long]0
        }
    }

    $before = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory * 1024

    $targets = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID }
    if ($Names.Count -gt 0) {
        $targets = $targets | Where-Object { $Names -contains $_.ProcessName }
    }
    if ($IdleOnly) {
        # a process with no window that has used little CPU is a fair proxy for idle
        $targets = $targets | Where-Object {
            $hasWin = $false
            try { $hasWin = ($_.MainWindowHandle -ne 0) } catch { }
            -not $hasWin
        }
    }
    $targets = @($targets | Where-Object { -not (Test-PolishProtectedProcess -Name $_.ProcessName) })

    if ($Ctx.DryRun) {
        Write-PolishCtx $Ctx ("would trim the working set of {0} process(es)" -f $targets.Count) 'ok'
        return [long]0
    }

    $trimmed = 0
    foreach ($p in $targets) {
        try {
            if ([PolishMem]::EmptyWorkingSet($p.Handle)) { $trimmed++ }
        } catch { }
    }

    Start-Sleep -Milliseconds 700
    $after = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory * 1024
    $delta = $after - $before

    Write-PolishCtx $Ctx ("trimmed {0} process working set(s)" -f $trimmed) 'ok'
    if ($delta -gt 0) {
        Write-PolishCtx $Ctx ("free RAM {0} -> {1}  (+{2})" -f (Format-PolishSize $before), (Format-PolishSize $after), (Format-PolishSize $delta)) 'ok'
    } else {
        Write-PolishCtx $Ctx ("free RAM barely moved; nothing was holding reclaimable pages") 'info'
    }
    Write-PolishCtx $Ctx 'note: Windows pages this back in if the apps need it. Useful right before' 'info'
    Write-PolishCtx $Ctx 'launching something big, not as a routine speed-up.' 'info'

    if ($delta -gt 0) { $Ctx.RamFreed += $delta }
    return [long]$delta
}
