<#
    Polish - action catalog

    Every capability is one entry here. Nothing is hidden in the UI layer.

    Fields
      Id          stable identifier, used by -Only/-Skip and the undo manifest
      Module      UI grouping
      Name        what the user reads
      Detail      the honest consequence, including the downside
      Risk        Safe | Moderate | Advanced
      Undo        Full | Partial | None
      Default     pre-ticked on first run (only ever true for Safe + no restart)
      Reboot      needs a restart to take effect
      NeedsAdmin  requires elevation
      Applies     predicate on the detection object; false means never shown
      Apply       the work. Only ever calls Set-Polish* helpers, so undo is automatic.

    Risk means:
      Safe      reversible, no behaviour a normal user would miss
      Moderate  removes or disables something you might actually want
      Advanced  can break a specific machine; shown with a warning, never default
#>

function Get-PolishCatalog {

    $c = [System.Collections.ArrayList]::new()
    function _add($h) { [void]$c.Add([pscustomobject]$h) }

    # =======================================================================
    #  OPTIMIZE  - the one-click, no-restart group
    # =======================================================================
    _add @{
        Id = 'optimize.closebg'; Module = 'Optimize'
        Name = 'Close background apps that are eating RAM'
        Detail = 'Finds launchers, updaters, tray apps and overlays that are running for no reason and closes them. They all reopen when you next use them. Never touches anything with an open window, anything Windows needs, or your antivirus.'
        Risk = 'Safe'; Undo = 'None'; Default = $true; Reboot = $false; NeedsAdmin = $false
        Applies = { param($s) $true }
        Apply = {
            param($Ctx)
            $rows = Get-PolishProcessReport
            $reap = Get-PolishReapSummary -Rows $rows
            if ($reap.Count -eq 0) {
                Write-PolishCtx $Ctx 'nothing reapable is running' 'skip'
                return
            }
            Write-PolishCtx $Ctx ("found {0} background app(s) holding {1}" -f $reap.Count, (Format-PolishSize $reap.Bytes)) 'info'
            [void](Close-PolishProcesses -Ctx $Ctx -Names $reap.Names -ActionId 'optimize.closebg')
        }
    }

    _add @{
        Id = 'optimize.closeapps'; Module = 'Optimize'
        Name = 'Also close chat, music and recording apps'
        Detail = 'Closes Discord, Spotify, Teams, WhatsApp, Medal, OBS and similar. This frees by far the most memory, but you might be in a call, listening to something, or part way through a recording. Never pre-ticked for that reason. Cloud sync apps like OneDrive and Dropbox are handled separately and are not touched here.'
        Risk = 'Moderate'; Undo = 'None'; Default = $false; Reboot = $false; NeedsAdmin = $false
        Applies = { param($s) $true }
        Apply = {
            param($Ctx)
            $rows = Get-PolishProcessReport
            $apps = Get-PolishReapSummary -Rows $rows -Class 'UserApp'
            if ($apps.Count -eq 0) { Write-PolishCtx $Ctx 'none of these are running' 'skip'; return }
            Write-PolishCtx $Ctx ("{0} app(s) holding {1}" -f $apps.Count, (Format-PolishSize $apps.Bytes)) 'info'
            [void](Close-PolishProcesses -Ctx $Ctx -Names $apps.Names -ActionId 'optimize.closeapps')
        }
    }

    _add @{
        Id = 'optimize.trimram'; Module = 'Optimize'
        Name = 'Free up physical RAM now'
        Detail = 'Pushes idle pages out of memory so physical RAM is available immediately. Genuinely useful right before launching a game or a VM. NOT a general speed-up: Windows pages data back in if apps need it, so running this repeatedly makes things slower, not faster. Polish deliberately does not flush the standby cache, which is the trick other optimizers use to inflate the number.'
        Risk = 'Safe'; Undo = 'None'; Default = $false; Reboot = $false; NeedsAdmin = $false
        Applies = { param($s) $true }
        Apply = { param($Ctx) [void](Invoke-PolishWorkingSetTrim -Ctx $Ctx -IdleOnly) }
    }

    _add @{
        Id = 'optimize.flushdns'; Module = 'Optimize'
        Name = 'Flush the DNS cache'
        Detail = 'Clears stale name lookups. Fixes sites that resolve to the wrong address after a network change. Costs one extra lookup per site afterwards.'
        Risk = 'Safe'; Undo = 'None'; Default = $true; Reboot = $false; NeedsAdmin = $false
        Applies = { param($s) $true }
        Apply = {
            param($Ctx)
            if ($Ctx.DryRun) { Write-PolishCtx $Ctx 'would flush DNS cache' 'ok'; return }
            try { [void](ipconfig /flushdns); Write-PolishCtx $Ctx 'DNS cache flushed' 'ok'; $Ctx.Changed++ }
            catch { Write-PolishCtx $Ctx "flush failed: $($_.Exception.Message)" 'warn' }
        }
    }

    _add @{
        Id = 'optimize.explorer'; Module = 'Optimize'
        Name = 'Restart Windows Explorer'
        Detail = 'Clears a leaking shell process and fixes a sluggish or glitched taskbar without a reboot. Your open File Explorer windows will close. Desktop icons flicker for a second.'
        Risk = 'Moderate'; Undo = 'None'; Default = $false; Reboot = $false; NeedsAdmin = $false
        Applies = { param($s) $true }
        Apply = {
            param($Ctx)
            if ($Ctx.DryRun) { Write-PolishCtx $Ctx 'would restart explorer.exe' 'ok'; return }
            try {
                Stop-Process -Name explorer -Force -ErrorAction Stop
                Start-Sleep -Milliseconds 1200
                if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
                Write-PolishCtx $Ctx 'Explorer restarted' 'ok'; $Ctx.Changed++
            } catch { Write-PolishCtx $Ctx "could not restart Explorer: $($_.Exception.Message)" 'warn' }
        }
    }

    # =======================================================================
    #  GAMING
    # =======================================================================
    _add @{
        Id = 'gaming.gamemode'; Module = 'Gaming'
        Name = 'Turn on Game Mode'
        Detail = 'Tells Windows to deprioritise background work while a game is in the foreground. No downside. Windows sometimes resets this on its own, so Polish can re-assert it.'
        Risk = 'Safe'; Undo = 'Full'; Default = $true; Reboot = $false; NeedsAdmin = $false
        Applies = { param($s) $true }
        Apply = {
            param($Ctx)
            Set-PolishReg -Ctx $Ctx -Path 'HKCU:\Software\Microsoft\GameBar' -Name 'AutoGameModeEnabled' -Value 1 -ActionId 'gaming.gamemode' -Label 'Game Mode' | Out-Null
            Set-PolishReg -Ctx $Ctx -Path 'HKCU:\Software\Microsoft\GameBar' -Name 'AllowAutoGameMode' -Value 1 -ActionId 'gaming.gamemode' -Label 'Game Mode allowed' | Out-Null
        }
    }

    _add @{
        Id = 'gaming.gamedvr'; Module = 'Gaming'
        Name = 'Disable background game recording (Game DVR)'
        Detail = 'Game DVR records the last few minutes of gameplay constantly, which costs frames on most machines. Turning it off disables the Game Bar "record that" feature. Manual recording and third-party capture are unaffected.'
        Risk = 'Safe'; Undo = 'Full'; Default = $true; Reboot = $false; NeedsAdmin = $false
        Applies = { param($s) $true }
        Apply = {
            param($Ctx)
            $a = 'gaming.gamedvr'
            Set-PolishReg -Ctx $Ctx -Path 'HKCU:\System\GameConfigStore' -Name 'GameDVR_Enabled' -Value 0 -ActionId $a -Label 'Game DVR' | Out-Null
            Set-PolishReg -Ctx $Ctx -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -Name 'AppCaptureEnabled' -Value 0 -ActionId $a -Label 'background capture' | Out-Null
            if ($Ctx.Sys.IsAdmin) {
                Set-PolishReg -Ctx $Ctx -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' -Name 'AllowGameDVR' -Value 0 -ActionId $a -Label 'Game DVR policy' | Out-Null
            }
        }
    }

    _add @{
        Id = 'gaming.fse'; Module = 'Gaming'
        Name = 'Prefer true fullscreen over fullscreen optimizations'
        Detail = 'Lets games use exclusive fullscreen instead of the borderless path Windows prefers. Usually lower input latency. If a game starts showing a black screen on launch, untick this and run Polish again.'
        Risk = 'Moderate'; Undo = 'Full'; Default = $false; Reboot = $false; NeedsAdmin = $false
        Applies = { param($s) $true }
        Apply = {
            param($Ctx)
            $a = 'gaming.fse'; $p = 'HKCU:\System\GameConfigStore'
            Set-PolishReg -Ctx $Ctx -Path $p -Name 'GameDVR_FSEBehaviorMode' -Value 2 -ActionId $a -Label 'FSE behaviour' | Out-Null
            Set-PolishReg -Ctx $Ctx -Path $p -Name 'GameDVR_HonorUserFSEBehaviorMode' -Value 1 -ActionId $a -Label 'honour FSE choice' | Out-Null
            Set-PolishReg -Ctx $Ctx -Path $p -Name 'GameDVR_DXGIHonorFSEWindowsCompatible' -Value 1 -ActionId $a -Label 'DXGI FSE' | Out-Null
        }
    }

    _add @{
        Id = 'gaming.mouseaccel'; Module = 'Gaming'
        Name = 'Turn off mouse acceleration'
        Detail = 'Makes cursor movement a fixed ratio to physical movement, which is what you want for aiming. If you actually like acceleration for desktop work, skip this.'
        Risk = 'Safe'; Undo = 'Full'; Default = $false; Reboot = $false; NeedsAdmin = $false
        Applies = { param($s) $true }
        Apply = {
            param($Ctx)
            $a = 'gaming.mouseaccel'; $p = 'HKCU:\Control Panel\Mouse'
            Set-PolishReg -Ctx $Ctx -Path $p -Name 'MouseSpeed'      -Value '0' -Type String -ActionId $a -Label 'mouse acceleration' | Out-Null
            Set-PolishReg -Ctx $Ctx -Path $p -Name 'MouseThreshold1' -Value '0' -Type String -ActionId $a -Label 'mouse threshold 1' | Out-Null
            Set-PolishReg -Ctx $Ctx -Path $p -Name 'MouseThreshold2' -Value '0' -Type String -ActionId $a -Label 'mouse threshold 2' | Out-Null
        }
    }

    _add @{
        Id = 'gaming.hags'; Module = 'Gaming'
        Name = 'Hardware-accelerated GPU scheduling'
        Detail = 'Hands frame scheduling to the GPU instead of the CPU. Usually a small latency win on modern NVIDIA and AMD cards. Needs a restart. A few older titles dislike it; if you see new stutter, undo this.'
        Risk = 'Moderate'; Undo = 'Full'; Default = $false; Reboot = $true; NeedsAdmin = $true
        Applies = { param($s) ($s.HasNvidia -or $s.HasAmd) -and -not $s.IsVM }
        Apply = {
            param($Ctx)
            Set-PolishReg -Ctx $Ctx -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'HwSchMode' -Value 2 -ActionId 'gaming.hags' -Label 'GPU scheduling' | Out-Null
            Add-PolishNote $Ctx 'GPU scheduling takes effect after a restart.'
        }
    }

    _add @{
        Id = 'gaming.powerplan'; Module = 'Gaming'
        Name = 'Switch to the High Performance power plan'
        Detail = 'Stops the CPU dropping to low clocks between frames.'
        Risk = 'Moderate'; Undo = 'Partial'; Default = $false; Reboot = $false; NeedsAdmin = $false
        Applies = { param($s) -not $s.IsVM }
        Apply = {
            param($Ctx)
            if ($Ctx.Sys.IsLaptop) {
                Write-PolishCtx $Ctx 'laptop detected: this will shorten battery life noticeably' 'warn'
            }
            if ($Ctx.DryRun) { Write-PolishCtx $Ctx 'would switch to High Performance' 'ok'; return }
            $prev = $null
            try { $prev = ((powercfg /getactivescheme) -split '\s+')[3] } catch { }
            try {
                [void](powercfg /setactive SCHEME_MIN)
                Write-PolishCtx $Ctx 'power plan set to High Performance' 'ok'
                $Ctx.Changed++
                if ($prev) { Add-PolishNote $Ctx "Previous power plan GUID was $prev (powercfg /setactive $prev to revert)." }
            } catch { Write-PolishCtx $Ctx "could not change power plan: $($_.Exception.Message)" 'warn' }
        }
    }

    # =======================================================================
    #  STARTUP
    # =======================================================================
    _add @{
        Id = 'startup.thirdparty'; Module = 'Startup'
        Name = 'Disable third-party startup programs'
        Detail = 'Stops non-Microsoft apps launching with Windows. They still work, you just open them yourself. Every entry stays visible in Task Manager > Startup apps with a one-click re-enable. Security software and anything Windows needs is skipped.'
        Risk = 'Moderate'; Undo = 'Full'; Default = $false; Reboot = $false; NeedsAdmin = $false
        Applies = { param($s) $true }
        Apply = {
            param($Ctx)
            $runKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
            $item = Get-Item -LiteralPath $runKey -ErrorAction SilentlyContinue
            if (-not $item) { Write-PolishCtx $Ctx 'no user startup entries' 'skip'; return }

            # never auto-disable security or vendor hardware helpers
            $keepRx = '(?i)(defender|security|antivirus|avast|avg|bitdefender|kaspersky|norton|mcafee|eset|malwarebytes|sophos|windows ?security|onedrive|realtek|nahimic|synaptics|elan|touchpad|audio)'
            $n = 0
            foreach ($name in $item.Property) {
                if ($name -match $keepRx) {
                    Write-PolishCtx $Ctx ("kept (security or hardware): $name") 'skip'
                    continue
                }
                if (Disable-PolishStartup -Ctx $Ctx -Scope User -Kind 'Run' -Name $name -ActionId 'startup.thirdparty') { $n++ }
            }
            if ($n -eq 0) { Write-PolishCtx $Ctx 'nothing left to disable' 'skip' }
        }
    }

    _add @{
        Id = 'startup.oemtasks'; Module = 'Startup'
        Name = 'Disable OEM and vendor nag tasks'
        Detail = 'Turns off scheduled tasks that only exist to check for vendor updates, show offers or upload usage data. Hotkey, power, thermal and touchpad tasks are protected and never touched.'
        Risk = 'Moderate'; Undo = 'Full'; Default = $false; Reboot = $false; NeedsAdmin = $true
        Applies = { param($s) $true }
        Apply = {
            param($Ctx)
            $nagRx = '(?i)(customer ?experience|telemetry|consolidator|usage ?data|feedback|SoftLanding|offers?|promo|marketing|survey|registration|analytics|CCXProcess|Adobe.*(Update|CCX)|SelfUpdate|UpdateCheck|CheckForUpdates?)'
            $protectRx = '(?i)(hotkey|function ?key|touchpad|power|thermal|fan|battery|keyboard|audio|display|backlight)'

            $tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue |
                       Where-Object { $_.State -ne 'Disabled' })
            $n = 0
            foreach ($t in $tasks) {
                $full = "$($t.TaskPath)$($t.TaskName)"
                if ($full -notmatch $nagRx) { continue }
                if ($full -match $protectRx) {
                    Write-PolishCtx $Ctx ("protected, skipped: $full") 'skip'
                    continue
                }
                if (Disable-PolishTask -Ctx $Ctx -TaskPath $t.TaskPath -TaskName $t.TaskName -ActionId 'startup.oemtasks') { $n++ }
            }
            if ($n -eq 0) { Write-PolishCtx $Ctx 'no nag tasks found' 'skip' }
        }
    }

    # =======================================================================
    #  CACHES
    # =======================================================================
    _add @{
        Id = 'cache.shader'; Module = 'Caches'
        Name = 'Clear the GPU shader cache'
        Detail = 'Deletes compiled shaders for your graphics driver. Reclaims real space, often several GB, and fixes rendering glitches after a driver update. THE COST: every game recompiles its shaders on next launch, so expect stutter the first time you play each one. Worth doing occasionally. Not worth doing on a schedule.'
        Risk = 'Moderate'; Undo = 'None'; Default = $false; Reboot = $false; NeedsAdmin = $false
        Applies = { param($s) $true }
        Apply = {
            param($Ctx)
            $paths = Get-PolishShaderCachePaths -Sys $Ctx.Sys
            if ($paths.Count -eq 0) { Write-PolishCtx $Ctx 'no shader caches found on this machine' 'skip'; return }
            foreach ($p in $paths) {
                [void](Clear-PolishPath -Ctx $Ctx -Path $p.Path -Label ("$($p.Vendor): " + (Split-Path $p.Path -Leaf)))
            }
        }
    }

    _add @{
        Id = 'cache.temp'; Module = 'Caches'
        Name = 'Clear temp files'
        Detail = 'Deletes temporary files older than 24 hours from your user temp folder and, with admin, from the Windows temp folder. Files currently in use are skipped. No downside.'
        Risk = 'Safe'; Undo = 'None'; Default = $true; Reboot = $false; NeedsAdmin = $false
        Applies = { param($s) $true }
        Apply = {
            param($Ctx)
            [void](Clear-PolishPath -Ctx $Ctx -Path $env:TEMP -Label 'User temp' -OlderThanHours 24 -PreserveNames @('polish', 'claude'))
            if ($Ctx.Sys.IsAdmin) {
                [void](Clear-PolishPath -Ctx $Ctx -Path 'C:\Windows\Temp' -Label 'Windows temp' -OlderThanHours 24)
            }
            [void](Clear-PolishPath -Ctx $Ctx -Path "$env:LOCALAPPDATA\CrashDumps" -Label 'Crash dumps')
        }
    }

    _add @{
        Id = 'cache.winupdate'; Module = 'Caches'
        Name = 'Clear downloaded Windows Update files'
        Detail = 'Removes update payloads Windows has already installed. Frees space and sometimes fixes a stuck update. Windows re-downloads anything it still needs.'
        Risk = 'Safe'; Undo = 'None'; Default = $false; Reboot = $false; NeedsAdmin = $true
        Applies = { param($s) $true }
        Apply = {
            param($Ctx)
            [void](Clear-PolishPath -Ctx $Ctx -Path 'C:\Windows\SoftwareDistribution\Download' -Label 'Update payloads')
        }
    }

    _add @{
        Id = 'cache.browser'; Module = 'Caches'
        Name = 'Clear browser caches'
        Detail = 'Clears Chrome, Edge, Brave and Firefox caches across all profiles. Does NOT touch passwords, bookmarks, history or logins. The cost is slower first loads while caches refill. Open browsers keep their files locked, so close them first for a full clean.'
        Risk = 'Moderate'; Undo = 'None'; Default = $false; Reboot = $false; NeedsAdmin = $false
        Applies = { param($s) $true }
        Apply = {
            param($Ctx)
            $L = $env:LOCALAPPDATA; $A = $env:APPDATA
            $roots = @(
                "$L\Google\Chrome\User Data", "$L\Microsoft\Edge\User Data",
                "$L\BraveSoftware\Brave-Browser\User Data", "$L\Vivaldi\User Data",
                "$L\Chromium\User Data"
            )
            foreach ($root in $roots) {
                if (-not (Test-Path -LiteralPath $root)) { continue }
                $profiles = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                              Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })
                foreach ($pr in $profiles) {
                    foreach ($sub in @('Cache', 'Code Cache', 'GPUCache', 'DawnGraphiteCache', 'DawnWebGPUCache')) {
                        $t = Join-Path $pr.FullName $sub
                        $label = '{0} {1} {2}' -f (Split-Path (Split-Path $root -Parent) -Leaf), $pr.Name, $sub
                        [void](Clear-PolishPath -Ctx $Ctx -Path $t -Label $label)
                    }
                }
            }
            # Firefox keeps caches under a per-profile folder in LocalAppData
            $ff = "$L\Mozilla\Firefox\Profiles"
            if (Test-Path -LiteralPath $ff) {
                foreach ($pr in (Get-ChildItem -LiteralPath $ff -Directory -ErrorAction SilentlyContinue)) {
                    [void](Clear-PolishPath -Ctx $Ctx -Path (Join-Path $pr.FullName 'cache2') -Label ('Firefox ' + $pr.Name))
                }
            }
        }
    }

    _add @{
        Id = 'cache.thumbnails'; Module = 'Caches'
        Name = 'Rebuild the thumbnail and icon cache'
        Detail = 'Fixes wrong or blank thumbnails and stale icons. Explorer rebuilds them on demand. Thumbnails regenerate more slowly the first time you browse a folder of photos.'
        Risk = 'Safe'; Undo = 'None'; Default = $false; Reboot = $false; NeedsAdmin = $false
        Applies = { param($s) $true }
        Apply = {
            param($Ctx)
            [void](Clear-PolishPath -Ctx $Ctx -Path "$env:LOCALAPPDATA\Microsoft\Windows\Explorer" -Label 'Thumbnail/icon cache')
        }
    }

    _add @{
        Id = 'cache.recyclebin'; Module = 'Caches'
        Name = 'Empty the recycle bin'
        Detail = 'Permanently deletes everything currently in the recycle bin on every drive. This is the one action in Polish that can lose a file you wanted, so it is never pre-ticked.'
        Risk = 'Moderate'; Undo = 'None'; Default = $false; Reboot = $false; NeedsAdmin = $false
        Applies = { param($s) $true }
        Apply = {
            param($Ctx)
            if ($Ctx.DryRun) { Write-PolishCtx $Ctx 'would empty the recycle bin' 'ok'; return }
            try { Clear-RecycleBin -Force -Confirm:$false -ErrorAction Stop; Write-PolishCtx $Ctx 'recycle bin emptied' 'ok'; $Ctx.Changed++ }
            catch { Write-PolishCtx $Ctx 'recycle bin was already empty' 'skip' }
        }
    }

    # =======================================================================
    #  PRIVACY
    # =======================================================================
    _add @{
        Id = 'privacy.telemetry'; Module = 'Privacy'
        Name = 'Minimise Windows telemetry'
        Detail = 'Sets the diagnostic data policy to the minimum and stops the telemetry service. Windows Update and Defender keep working normally. On Home editions Microsoft enforces a floor, so this reduces rather than eliminates data collection. Polish does not pretend otherwise.'
        Risk = 'Safe'; Undo = 'Full'; Default = $false; Reboot = $false; NeedsAdmin = $true
        Applies = { param($s) $true }
        Apply = {
            param($Ctx)
            $a = 'privacy.telemetry'
            Set-PolishReg -Ctx $Ctx -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Name 'AllowTelemetry' -Value 0 -ActionId $a -Label 'telemetry policy' | Out-Null
            Set-PolishReg -Ctx $Ctx -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' -Name 'AllowTelemetry' -Value 0 -ActionId $a -Label 'telemetry (CurrentVersion)' | Out-Null
            Set-PolishService -Ctx $Ctx -Name 'DiagTrack' -StartupType Disabled -StopNow -ActionId $a | Out-Null
            Set-PolishService -Ctx $Ctx -Name 'dmwappushservice' -StartupType Disabled -StopNow -ActionId $a | Out-Null
        }
    }

    _add @{
        Id = 'privacy.adid'; Module = 'Privacy'
        Name = 'Turn off the advertising ID and targeted ads'
        Detail = 'Stops apps using a per-user advertising identifier, and turns off tailored suggestions in Start, Settings and the lock screen. You still see ads, they are just not personalised.'
        Risk = 'Safe'; Undo = 'Full'; Default = $false; Reboot = $false; NeedsAdmin = $false
        Applies = { param($s) $true }
        Apply = {
            param($Ctx)
            $a = 'privacy.adid'
            Set-PolishReg -Ctx $Ctx -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' -Name 'Enabled' -Value 0 -ActionId $a -Label 'advertising ID' | Out-Null
            $cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
            foreach ($v in 'SilentInstalledAppsEnabled', 'SystemPaneSuggestionsEnabled', 'SoftLandingEnabled',
                           'RotatingLockScreenOverlayEnabled', 'PreInstalledAppsEnabled', 'OemPreInstalledAppsEnabled',
                           'SubscribedContent-338388Enabled', 'SubscribedContent-338389Enabled',
                           'SubscribedContent-310093Enabled', 'SubscribedContent-338393Enabled') {
                Set-PolishReg -Ctx $Ctx -Path $cdm -Name $v -Value 0 -ActionId $a -Label "suggestion: $v" | Out-Null
            }
            Set-PolishReg -Ctx $Ctx -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'Start_IrisRecommendations' -Value 0 -ActionId $a -Label 'Start recommendations' | Out-Null
        }
    }

    _add @{
        Id = 'privacy.activity'; Module = 'Privacy'
        Name = 'Turn off activity history'
        Detail = 'Stops Windows collecting a timeline of what you opened and syncing it to your Microsoft account. Timeline and "pick up where you left off" stop working.'
        Risk = 'Safe'; Undo = 'Full'; Default = $false; Reboot = $false; NeedsAdmin = $true
        Applies = { param($s) $true }
        Apply = {
            param($Ctx)
            $a = 'privacy.activity'; $p = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
            Set-PolishReg -Ctx $Ctx -Path $p -Name 'EnableActivityFeed'        -Value 0 -ActionId $a -Label 'activity feed' | Out-Null
            Set-PolishReg -Ctx $Ctx -Path $p -Name 'PublishUserActivities'     -Value 0 -ActionId $a -Label 'publish activities' | Out-Null
            Set-PolishReg -Ctx $Ctx -Path $p -Name 'UploadUserActivities'      -Value 0 -ActionId $a -Label 'upload activities' | Out-Null
        }
    }

    # =======================================================================
    #  FEATURES  - Copilot, Recall, Widgets, Edge nags
    # =======================================================================
    _add @{
        Id = 'features.copilot'; Module = 'Features'
        Name = 'Remove Windows Copilot'
        Detail = 'Turns off Copilot by policy and hides its taskbar button. Microsoft has re-enabled this on feature updates before, so Polish can re-assert it.'
        Risk = 'Safe'; Undo = 'Full'; Default = $false; Reboot = $false; NeedsAdmin = $false
        Applies = { param($s) $s.IsWindows11 }
        Apply = {
            param($Ctx)
            $a = 'features.copilot'
            Set-PolishReg -Ctx $Ctx -Path 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' -Name 'TurnOffWindowsCopilot' -Value 1 -ActionId $a -Label 'Copilot off (user)' | Out-Null
            Set-PolishReg -Ctx $Ctx -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'ShowCopilotButton' -Value 0 -ActionId $a -Label 'Copilot taskbar button' | Out-Null
            if ($Ctx.Sys.IsAdmin) {
                Set-PolishReg -Ctx $Ctx -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' -Name 'TurnOffWindowsCopilot' -Value 1 -ActionId $a -Label 'Copilot off (machine)' | Out-Null
            }
        }
    }

    _add @{
        Id = 'features.recall'; Module = 'Features'
        Name = 'Disable Windows Recall snapshots'
        Detail = 'Stops Recall taking periodic screenshots of your activity. Only present on Copilot+ builds; on machines without Recall this writes a policy nothing reads, which is harmless and still logged for undo.'
        Risk = 'Safe'; Undo = 'Full'; Default = $false; Reboot = $false; NeedsAdmin = $true
        Applies = { param($s) $s.IsWindows11 -and $s.OsBuild -ge 26100 }
        Apply = {
            param($Ctx)
            $a = 'features.recall'
            Set-PolishReg -Ctx $Ctx -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' -Name 'DisableAIDataAnalysis' -Value 1 -ActionId $a -Label 'Recall snapshots off' | Out-Null
            Set-PolishReg -Ctx $Ctx -Path 'HKCU:\Software\Policies\Microsoft\Windows\WindowsAI' -Name 'DisableAIDataAnalysis' -Value 1 -ActionId $a -Label 'Recall (user)' | Out-Null
        }
    }

    _add @{
        Id = 'features.widgets'; Module = 'Features'
        Name = 'Remove Widgets and the news feed'
        Detail = 'Hides the widgets panel and stops its background process. Removes the weather and news button from the taskbar.'
        Risk = 'Safe'; Undo = 'Full'; Default = $false; Reboot = $false; NeedsAdmin = $false
        Applies = { param($s) $s.IsWindows11 }
        Apply = {
            param($Ctx)
            $a = 'features.widgets'
            Set-PolishReg -Ctx $Ctx -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'TaskbarDa' -Value 0 -ActionId $a -Label 'widgets button' | Out-Null
            if ($Ctx.Sys.IsAdmin) {
                Set-PolishReg -Ctx $Ctx -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' -Name 'AllowNewsAndInterests' -Value 0 -ActionId $a -Label 'news and interests policy' | Out-Null
            }
        }
    }

    _add @{
        Id = 'features.searchweb'; Module = 'Features'
        Name = 'Remove web results from Start menu search'
        Detail = 'Makes the Start menu search your PC only, instead of sending what you type to Bing. Searching files and apps gets noticeably faster.'
        Risk = 'Safe'; Undo = 'Full'; Default = $false; Reboot = $false; NeedsAdmin = $false
        Applies = { param($s) $true }
        Apply = {
            param($Ctx)
            $a = 'features.searchweb'
            Set-PolishReg -Ctx $Ctx -Path 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' -Name 'DisableSearchBoxSuggestions' -Value 1 -ActionId $a -Label 'no web suggestions' | Out-Null
            Set-PolishReg -Ctx $Ctx -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' -Name 'BingSearchEnabled' -Value 0 -ActionId $a -Label 'Bing search off' | Out-Null
            Set-PolishReg -Ctx $Ctx -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' -Name 'CortanaConsent' -Value 0 -ActionId $a -Label 'Cortana consent' | Out-Null
        }
    }

    _add @{
        Id = 'features.edgenags'; Module = 'Features'
        Name = 'Stop Edge nagging and preloading'
        Detail = 'Turns off the "recommended browser" prompts, the first-run flow and Edge preloading itself at startup. Edge still works normally when you open it. Does not uninstall Edge: on Windows 11 that breaks Windows Update and several built-in panels.'
        Risk = 'Safe'; Undo = 'Full'; Default = $false; Reboot = $false; NeedsAdmin = $true
        Applies = { param($s) $true }
        Apply = {
            param($Ctx)
            $a = 'features.edgenags'; $p = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
            Set-PolishReg -Ctx $Ctx -Path $p -Name 'HideFirstRunExperience'          -Value 1 -ActionId $a -Label 'no Edge first-run' | Out-Null
            Set-PolishReg -Ctx $Ctx -Path $p -Name 'StartupBoostEnabled'             -Value 0 -ActionId $a -Label 'no Edge startup boost' | Out-Null
            Set-PolishReg -Ctx $Ctx -Path $p -Name 'BackgroundModeEnabled'           -Value 0 -ActionId $a -Label 'no Edge background mode' | Out-Null
            Set-PolishReg -Ctx $Ctx -Path $p -Name 'ShowRecommendationsEnabled'      -Value 0 -ActionId $a -Label 'no Edge recommendations' | Out-Null
            Set-PolishReg -Ctx $Ctx -Path $p -Name 'DefaultBrowserSettingEnabled'    -Value 0 -ActionId $a -Label 'no default-browser nag' | Out-Null
        }
    }

    # =======================================================================
    #  VISUAL
    # =======================================================================
    _add @{
        Id = 'visual.snappy'; Module = 'Visual'
        Name = 'Make the interface respond instantly'
        Detail = 'Removes window and menu animation delay while keeping ClearType text smoothing and thumbnails. The desktop feels faster because you stop waiting for animations, not because anything renders quicker. Takes effect after sign-out.'
        Risk = 'Safe'; Undo = 'Full'; Default = $false; Reboot = $false; NeedsAdmin = $false
        Applies = { param($s) $true }
        Apply = {
            param($Ctx)
            $a = 'visual.snappy'
            Set-PolishReg -Ctx $Ctx -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' -Name 'VisualFXSetting' -Value 3 -ActionId $a -Label 'custom visual effects' | Out-Null
            Set-PolishReg -Ctx $Ctx -Path 'HKCU:\Control Panel\Desktop\WindowMetrics' -Name 'MinAnimate' -Value '0' -Type String -ActionId $a -Label 'window animations off' | Out-Null
            Set-PolishReg -Ctx $Ctx -Path 'HKCU:\Control Panel\Desktop' -Name 'MenuShowDelay' -Value '100' -Type String -ActionId $a -Label 'menu delay 100ms' | Out-Null
            Set-PolishReg -Ctx $Ctx -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'TaskbarAnimations' -Value 0 -ActionId $a -Label 'taskbar animations off' | Out-Null
            Add-PolishNote $Ctx 'Interface changes fully apply after you sign out and back in.'
        }
    }

    _add @{
        Id = 'visual.transparency'; Module = 'Visual'
        Name = 'Turn off transparency effects'
        Detail = 'Disables the blur behind the taskbar and Start menu. Measurably cheaper on weak integrated graphics. Looks flatter.'
        Risk = 'Safe'; Undo = 'Full'; Default = $false; Reboot = $false; NeedsAdmin = $false
        Applies = { param($s) $true }
        Apply = {
            param($Ctx)
            Set-PolishReg -Ctx $Ctx -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'EnableTransparency' -Value 0 -ActionId 'visual.transparency' -Label 'transparency off' | Out-Null
        }
    }

    # =======================================================================
    #  MAINTENANCE
    # =======================================================================
    _add @{
        Id = 'maint.storagesense'; Module = 'Maintenance'
        Name = 'Turn on automatic cleanup (Storage Sense)'
        Detail = 'Lets Windows clear temp files and 30-day-old recycle bin contents on its own, so you stop needing a cleaner. Your Downloads folder is explicitly left alone.'
        Risk = 'Safe'; Undo = 'Full'; Default = $true; Reboot = $false; NeedsAdmin = $false
        Applies = { param($s) $true }
        Apply = {
            param($Ctx)
            $a = 'maint.storagesense'
            $p = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'
            Set-PolishReg -Ctx $Ctx -Path $p -Name '01'  -Value 1  -ActionId $a -Label 'Storage Sense on' | Out-Null
            Set-PolishReg -Ctx $Ctx -Path $p -Name '04'  -Value 1  -ActionId $a -Label 'clear temp files' | Out-Null
            Set-PolishReg -Ctx $Ctx -Path $p -Name '08'  -Value 1  -ActionId $a -Label 'clear old recycle bin' | Out-Null
            Set-PolishReg -Ctx $Ctx -Path $p -Name '32'  -Value 30 -ActionId $a -Label 'recycle bin age 30d' | Out-Null
            Set-PolishReg -Ctx $Ctx -Path $p -Name '256' -Value 0  -ActionId $a -Label 'leave Downloads alone' | Out-Null
        }
    }

    _add @{
        Id = 'maint.trim'; Module = 'Maintenance'
        Name = 'Re-TRIM solid state drives'
        Detail = 'Tells the SSD controller which blocks are free again, which keeps write speed at factory level. Skipped automatically on mechanical drives, where it would be useless and slow.'
        Risk = 'Safe'; Undo = 'None'; Default = $false; Reboot = $false; NeedsAdmin = $true
        Applies = { param($s) $s.SysDriveIsSSD -ne $false -and -not $s.IsVM }
        Apply = {
            param($Ctx)
            if ($Ctx.DryRun) { Write-PolishCtx $Ctx 'would re-TRIM all SSD volumes' 'ok'; return }
            $vols = @(Get-Volume | Where-Object { $_.DriveLetter -and $_.FileSystem -eq 'NTFS' })
            foreach ($v in $vols) {
                try {
                    Optimize-Volume -DriveLetter $v.DriveLetter -ReTrim -ErrorAction Stop
                    Write-PolishCtx $Ctx ("{0}: re-trimmed" -f $v.DriveLetter) 'ok'
                    $Ctx.Changed++
                } catch {
                    Write-PolishCtx $Ctx ("{0}: skipped ({1})" -f $v.DriveLetter, $_.Exception.Message) 'skip'
                }
            }
        }
    }

    _add @{
        Id = 'maint.componentstore'; Module = 'Maintenance'; Slow = $true
        Name = 'Shrink the Windows component store'
        Detail = 'Removes superseded versions of Windows components, usually reclaiming several GB. Takes a few minutes. Polish does not pass /ResetBase, so you can still uninstall Windows updates afterwards.'
        Risk = 'Moderate'; Undo = 'None'; Default = $false; Reboot = $false; NeedsAdmin = $true
        Applies = { param($s) -not $s.IsVM }
        Apply = {
            param($Ctx)
            if ($Ctx.DryRun) { Write-PolishCtx $Ctx 'would run DISM /StartComponentCleanup' 'ok'; return }
            Write-PolishCtx $Ctx 'running DISM component cleanup, this takes a few minutes...' 'info'
            $out = dism.exe /Online /Cleanup-Image /StartComponentCleanup
            foreach ($l in $out) { if ($l -match '\S') { Write-PolishCtx $Ctx ("    $l") 'info' } }
            $Ctx.Changed++
        }
    }

    _add @{
        Id = 'maint.integrity'; Module = 'Maintenance'; Slow = $true
        Name = 'Check and repair Windows system files'
        Detail = 'Runs DISM RestoreHealth then SFC to verify and repair Windows itself. This is the "is my Windows actually healthy" check. Takes 15 to 30 minutes and cannot be interrupted safely, so it is never part of a quick run.'
        Risk = 'Safe'; Undo = 'None'; Default = $false; Reboot = $false; NeedsAdmin = $true
        Applies = { param($s) $true }
        Apply = {
            param($Ctx)
            if ($Ctx.DryRun) { Write-PolishCtx $Ctx 'would run DISM /RestoreHealth then sfc /scannow' 'ok'; return }
            Write-PolishCtx $Ctx 'DISM RestoreHealth then SFC. Expect 15-30 minutes. Do not close Polish.' 'warn'
            $out = dism.exe /Online /Cleanup-Image /RestoreHealth
            foreach ($l in $out) { if ($l -match '\S') { Write-PolishCtx $Ctx ("    $l") 'info' } }
            $out2 = sfc.exe /scannow
            foreach ($l in $out2) { if ($l -match '\S') { Write-PolishCtx $Ctx ("    $l") 'info' } }
            $Ctx.Changed++
        }
    }

    # =======================================================================
    #  APPS  - Store and vendor preinstalls
    # =======================================================================
    _add @{
        Id = 'apps.msbloat'; Module = 'Apps'
        Name = 'Remove unwanted Microsoft Store apps'
        Detail = 'Removes inbox apps most people never open: Media Player, Maps, Bing News, Solitaire, Phone Link, Teams, 3D Viewer and similar. The Store, Photos, Notepad, Settings, Security, winget, codecs and every shell component are hard-protected and cannot be removed by Polish at all. REINSTALL: from the Microsoft Store. There is no one-click restore once a package payload is deleted, so this is the least reversible thing in the tool.'
        Risk = 'Moderate'; Undo = 'Partial'; Default = $false; Reboot = $false; NeedsAdmin = $false
        Applies = { param($s) $true }
        Apply = {
            param($Ctx)
            $rows = Get-PolishAppxReport
            $targets = Get-PolishAppxSuggestions -Rows $rows -Category 'MsBloat'
            if ($targets.Count -eq 0) { Write-PolishCtx $Ctx 'none of the known Store bloat is installed' 'skip'; return }
            Write-PolishCtx $Ctx ("{0} package(s) match, {1} on disk" -f $targets.Count, (Format-PolishSize (($targets | Measure-Object Bytes -Sum).Sum))) 'info'
            foreach ($t in $targets) {
                [void](Remove-PolishAppx -Ctx $Ctx -Name $t.Name -ActionId 'apps.msbloat' -AllUsers)
            }
            Add-PolishNote $Ctx 'Removed Store apps reinstall from the Microsoft Store, not from Polish.'
        }
    }

    _add @{
        Id = 'apps.oembloat'; Module = 'Apps'
        Name = 'Remove manufacturer preinstalls'
        Detail = 'Removes vendor and sponsored preinstalls: trial apps, Candy Crush, TikTok and Disney stubs, vendor "assistant" apps. Your OEM control panel for fan curves, lighting and hotkeys is protected and kept, because removing it on a gaming laptop breaks fan control.'
        Risk = 'Moderate'; Undo = 'Partial'; Default = $false; Reboot = $false; NeedsAdmin = $false
        Applies = { param($s) $true }
        Apply = {
            param($Ctx)
            $rows = Get-PolishAppxReport
            $targets = Get-PolishAppxSuggestions -Rows $rows -Category 'OemBloat'
            if ($targets.Count -eq 0) { Write-PolishCtx $Ctx 'no vendor preinstalls found' 'skip'; return }
            foreach ($t in $targets) {
                [void](Remove-PolishAppx -Ctx $Ctx -Name $t.Name -ActionId 'apps.oembloat' -AllUsers)
            }
        }
    }

    # =======================================================================
    #  SERVICES
    # =======================================================================
    _add @{
        Id = 'services.updaters'; Module = 'Services'
        Name = 'Set auto-start updater services to Manual'
        Detail = 'Updaters for Chrome, Edge, Firefox, Adobe and similar currently start with Windows and sit resident. On Manual they still run when the app asks for an update, they just stop launching at boot. Fully reversible.'
        Risk = 'Moderate'; Undo = 'Full'; Default = $false; Reboot = $false; NeedsAdmin = $true
        Applies = { param($s) $true }
        Apply = {
            param($Ctx)
            $rows = Get-PolishServiceReport
            $targets = @($rows | Where-Object { $_.Category -eq 'Updater' })
            if ($targets.Count -eq 0) { Write-PolishCtx $Ctx 'no auto-start updater services found' 'skip'; return }
            foreach ($t in $targets) {
                Set-PolishService -Ctx $Ctx -Name $t.Name -StartupType Manual -ActionId 'services.updaters' | Out-Null
            }
        }
    }

    _add @{
        Id = 'services.report'; Module = 'Services'
        Name = 'Show other auto-start services (report only)'
        Detail = 'Lists every remaining third-party service that starts with Windows, so you can judge them yourself. Polish deliberately will NOT batch-disable these: there is no reliable list of which vendor services a given laptop model needs, and this is exactly where function keys, touchpads and fan control break. Changes nothing.'
        Risk = 'Safe'; Undo = 'None'; Default = $false; Reboot = $false; NeedsAdmin = $false
        Applies = { param($s) $true }
        Apply = {
            param($Ctx)
            $rows = @((Get-PolishServiceReport) | Where-Object { $_.Category -eq 'Unknown' })
            if ($rows.Count -eq 0) { Write-PolishCtx $Ctx 'no unclassified third-party services' 'skip'; return }
            Write-PolishCtx $Ctx ("{0} third-party auto-start service(s). UNKNOWN RISK, judge each yourself:" -f $rows.Count) 'warn'
            foreach ($r in $rows) {
                Write-PolishCtx $Ctx ('  {0,-34} {1}' -f $r.Name, $r.DisplayName) 'info'
            }
            Write-PolishCtx $Ctx 'To change one:  Set-Service <Name> -StartupType Manual   (then reboot and test your hotkeys)' 'info'
        }
    }

    return $c
}

<#
  Filter the catalog to what applies to this machine. An action that cannot do
  anything here is removed entirely rather than shown greyed out.
#>
function Get-PolishApplicableActions {
    param($Sys, $Catalog)

    $out = @()
    foreach ($a in $Catalog) {
        $ok = $true
        try { $ok = [bool](& $a.Applies $Sys) } catch { $ok = $false }
        if (-not $ok) { continue }
        $out += $a
    }
    return $out
}

function Get-PolishModules {
    param($Actions)
    # stable display order
    $order = @('Optimize', 'Gaming', 'Startup', 'Caches', 'Privacy', 'Features', 'Visual', 'Apps', 'Services', 'Maintenance')
    $present = @($Actions | Select-Object -ExpandProperty Module -Unique)
    $result = @()
    foreach ($m in $order) { if ($present -contains $m) { $result += $m } }
    foreach ($m in $present) { if ($result -notcontains $m) { $result += $m } }
    return $result
}
