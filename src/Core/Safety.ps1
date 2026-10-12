<#
    Polish - safety and reversibility

    Three jobs:
      1. Protect lists. Things that are never touched, whatever the user ticks.
      2. System restore point before the first mutating action of a run.
      3. An undo manifest. Every mutation is recorded by the helper that made
         it, so an action physically cannot forget to record its own reversal.

    Design note: the protect lists are deliberately broader than strictly
    necessary. On someone else's laptop, the cost of leaving a service running
    is a few MB. The cost of breaking their Fn keys is that they stop trusting
    you. Those are not symmetric.
#>

# ===========================================================================
#  Protect lists
# ===========================================================================

# Store packages that break the shell, sign-in, Settings, Security or winget
# if removed. Matched as a prefix against PackageFamilyName/Name.
$script:ProtectedAppx = @(
    # shell and Start
    'Microsoft.Windows.ShellExperienceHost'
    'Microsoft.Windows.StartMenuExperienceHost'
    'MicrosoftWindows.Client.CBS'
    'MicrosoftWindows.Client.Core'
    'MicrosoftWindows.Client.FileExp'
    'Microsoft.Windows.Search'
    'Microsoft.Windows.SearchApp'
    'windows.immersivecontrolpanel'        # the Settings app
    'Microsoft.Windows.ContentDeliveryManager'
    'Microsoft.Windows.CloudExperienceHost'
    'Microsoft.Windows.PeopleExperienceHost'
    'Microsoft.Windows.OOBENetworkConnectionFlow'
    'Microsoft.Windows.AssignedAccessLockApp'
    'Microsoft.LockApp'
    'Microsoft.XboxGameCallableUI'
    'Microsoft.Win32WebViewHost'
    'Microsoft.CredDialogHost'

    # sign-in and identity
    'Microsoft.AAD.BrokerPlugin'
    'Microsoft.AccountsControl'
    'Microsoft.Windows.CallingShellApp'

    # security UI
    'Microsoft.SecHealthUI'
    'Microsoft.Windows.SecHealthUI'

    # package management. Removing DesktopAppInstaller kills winget, which is
    # how Polish puts apps BACK. Never.
    'Microsoft.DesktopAppInstaller'
    'Microsoft.WindowsStore'
    'Microsoft.StorePurchaseApp'
    'Microsoft.WinGet.Source'
    'Microsoft.WinGet.Platform'

    # runtimes and frameworks: removing these breaks unrelated apps
    'Microsoft.VCLibs'
    'Microsoft.NET.Native'
    'Microsoft.UI.Xaml'
    'Microsoft.WindowsAppRuntime'
    'MicrosoftCorporationII.WinAppRuntime'
    'Microsoft.Services.Store.Engagement'
    'Microsoft.Advertising.Xaml'

    # accessibility: removing these can lock out users who depend on them
    'Microsoft.Windows.NarratorQuickStart'
    'Microsoft.ECApp'
    'Microsoft.Windows.Apprep.ChxApp'

    # input
    'Microsoft.Windows.InputApp'
    'Microsoft.Ink.Handwriting'
    'Microsoft.LanguageExperiencePack'
    'Microsoft.Windows.Ime'

    # media codecs: cheap to keep, and removing them silently breaks
    # image and video playback in File Explorer and Photos
    'Microsoft.HEIFImageExtension'
    'Microsoft.HEVCVideoExtension'
    'Microsoft.AV1VideoExtension'
    'Microsoft.AVCEncoderVideoExtension'
    'Microsoft.VP9VideoExtensions'
    'Microsoft.WebMediaExtensions'
    'Microsoft.WebpImageExtension'
    'Microsoft.RawImageExtension'
    'Microsoft.MPEG2VideoExtension'

    # vendor control panels for installed hardware
    'NVIDIACorp.NVIDIAControlPanel'
    'AdvancedMicroDevicesInc'
    'RealtekSemiconductorCorp'
    'IntelCorporation'
)

# Services that are load bearing. Exact names, case insensitive.
$script:ProtectedServices = @(
    # RPC / COM / core plumbing
    'RpcSs', 'RpcEptMapper', 'DcomLaunch', 'LSM', 'BrokerInfrastructure'
    'CoreMessagingRegistrar', 'SystemEventsBroker', 'TimeBrokerSvc', 'TokenBroker'
    'Winmgmt', 'StateRepository', 'AppXSvc', 'ClipSVC', 'EventLog', 'EventSystem'
    'Schedule', 'ProfSvc', 'UserManager', 'CryptSvc', 'SamSs', 'gpsvc', 'Power'
    'PlugPlay', 'DeviceInstall', 'ShellHWDetection', 'Themes', 'FontCache'
    'camsvc', 'TextInputManagementService', 'WpnService', 'WpnUserService'
    'CDPSvc', 'CDPUserSvc', 'cbdhsvc', 'SENS', 'StorSvc', 'DispBrokerDesktopSvc'

    # audio
    'Audiosrv', 'AudioEndpointBuilder'

    # network
    'Dhcp', 'Dnscache', 'NlaSvc', 'netprofm', 'nsi', 'Wcmsvc', 'WlanSvc'
    'LanmanWorkstation', 'LanmanServer', 'iphlpsvc', 'NetSetupSvc', 'WinHttpAutoProxySvc'

    # security. Non negotiable.
    'WinDefend', 'mpssvc', 'BFE', 'MDCoreSvc', 'SecurityHealthService'
    'wscsvc', 'webthreatdefusersvc', 'webthreatdefsvc', 'Sense', 'WdNisSvc'

    # servicing. A debloater that breaks patching is malware with good intentions.
    'wuauserv', 'msiserver', 'TrustedInstaller', 'UsoSvc', 'DoSvc', 'BITS'
    'sppsvc', 'ClipSvc'

    # graphics vendor containers
    'NVDisplay.ContainerLocalSystem', 'NvContainerLocalSystem'
    'AMD External Events Utility', 'amdfendr', 'AMDRyzenMasterDriverV'
    'igfxCUIService', 'IntelAudioService'
)

# Regex patterns for OEM services. The research is unambiguous that there is no
# authoritative per vendor safe list, and that hotkeys, touchpads, fan curves
# and power profiles live in these. So anything matching is protected and the
# rest is offered only as 'unknown risk'.
$script:ProtectedServicePatterns = @(
    # input and hotkeys, any vendor
    '(?i)^(Synaptics|ETD|Elan|Alps|Focaltech)'
    '(?i)(HotKey|FnAndFunction|FunctionKeys|Keyboard|TouchPad|Trackpad)'

    # thermal and power, any vendor
    '(?i)(Thermal|FanControl|PowerAgent|BatteryHealth|DynamicPlatform)'

    # ASUS
    '(?i)^(ATKGFNEX|AsusPTP|ASUSOptimization|ArmouryCrate|AsusAppService|LightingService|ASUSSwitch|AsusCertService|ASUSLinkNear)'
    # Dell
    '(?i)^(Dell(ClientManagement|Instrumentation|TechHub|Power|Thermal|Display|Audio)|DDVData|DDVCollector|SupportAssist)'
    # HP
    '(?i)^(HP(SupportSolutions|Audio|SysInfo|AppHelper|Diagnostic)|hpqwmiex|HPPrintScan)'
    # Lenovo
    '(?i)^(Lenovo(Vantage|Fn|Platform|Power|Display)|ImController|LenovoHardware)'
    # MSI
    '(?i)^(MSI_|MSI Foundation|Micro Star)'
    # Acer / Razer / Gigabyte / Framework / Samsung
    '(?i)^(Acer|RzActionSvc|Razer|GigabyteUpdate|Framework|Samsung(Settings|Power))'

    # audio DSP, breaking this means no sound
    '(?i)^(Rtk|Realtek|NahimicService|Nahimic|WavesSysSvc|DTSAPO|SmartAudio|Dolby)'

    # Intel ME and graphics
    '(?i)^(Intel\(R\)|jhi_service|LMS|esifsvc|dptftcs)'
)

# Processes never terminated.
$script:ProtectedProcesses = @(
    'System', 'Registry', 'Idle', 'Secure System', 'Memory Compression'
    'smss', 'csrss', 'wininit', 'winlogon', 'services', 'lsass', 'svchost'
    'fontdrvhost', 'dwm', 'explorer', 'sihost', 'taskhostw', 'ctfmon'
    'audiodg', 'conhost', 'dllhost', 'RuntimeBroker', 'WmiPrvSE', 'spoolsv'
    'SearchHost', 'SearchIndexer', 'StartMenuExperienceHost', 'ShellExperienceHost'
    'TextInputHost', 'ApplicationFrameHost', 'SystemSettings', 'LockApp'
    'LogonUI', 'userinit', 'wlanext', 'WUDFHost', 'dasHost'
    'MsMpEng', 'NisSrv', 'SecurityHealthService', 'SecurityHealthSystray', 'MpDefenderCoreService'
    'powershell', 'pwsh', 'WindowsTerminal', 'cmd', 'conhost'
    'TrustedInstaller', 'TiWorker', 'msiexec'
)

function Test-PolishProtectedAppx {
    param([string]$Name)
    foreach ($p in $script:ProtectedAppx) {
        if ($Name -like "$p*") { return $true }
    }
    return $false
}

function Test-PolishProtectedService {
    param([string]$Name, [string]$DisplayName = '')
    foreach ($p in $script:ProtectedServices) {
        if ($Name -ieq $p) { return $true }
        # user-session services get a per-session suffix: cbdhsvc_9f4821c
        if ($Name -imatch ('^' + [regex]::Escape($p) + '_[0-9a-f]+$')) { return $true }
    }
    foreach ($rx in $script:ProtectedServicePatterns) {
        if ($Name -match $rx) { return $true }
        if ($DisplayName -and $DisplayName -match $rx) { return $true }
    }
    return $false
}

function Test-PolishProtectedProcess {
    param([string]$Name)
    foreach ($p in $script:ProtectedProcesses) {
        if ($Name -ieq $p) { return $true }
    }
    return $false
}

# ===========================================================================
#  Restore point
# ===========================================================================

<#
  Windows throttles restore point creation to one per 24 hours via
  SystemRestorePointCreationFrequency. A tool that silently fails to create one
  is worse than a tool with no restore point at all, because the user believes
  they are covered. So: read the throttle, temporarily set it to 0, create the
  point, then put the original value back exactly as it was.
#>
function New-PolishRestorePoint {
    param([string]$Description = 'Before Polish', $Log)

    $result = [pscustomobject]@{ Created = $false; Reason = ''; Skipped = $false }

    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not ([Security.Principal.WindowsPrincipal]$id).IsInRole(
                 [Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $result.Reason = 'not elevated'
        return $result
    }

    $srKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $hadFreq = $false
    $oldFreq = $null
    try {
        $existing = Get-ItemProperty -LiteralPath $srKey -Name 'SystemRestorePointCreationFrequency' -ErrorAction Stop
        $hadFreq = $true
        $oldFreq = $existing.SystemRestorePointCreationFrequency
    } catch { }

    try {
        if (-not (Test-Path -LiteralPath $srKey)) { New-Item -Path $srKey -Force | Out-Null }
        Set-ItemProperty -LiteralPath $srKey -Name 'SystemRestorePointCreationFrequency' -Value 0 -Type DWord -Force

        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
        Checkpoint-Computer -Description $Description -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        $result.Created = $true
    } catch {
        $result.Reason = $_.Exception.Message
    } finally {
        # put the throttle back exactly as found
        try {
            if ($hadFreq) {
                Set-ItemProperty -LiteralPath $srKey -Name 'SystemRestorePointCreationFrequency' -Value $oldFreq -Type DWord -Force
            } else {
                Remove-ItemProperty -LiteralPath $srKey -Name 'SystemRestorePointCreationFrequency' -ErrorAction SilentlyContinue
            }
        } catch { }
    }

    return $result
}

# ===========================================================================
#  Undo manifest
# ===========================================================================

function Get-PolishDataDir {
    $d = Join-Path $env:LOCALAPPDATA 'Polish'
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    return $d
}

function New-PolishRun {
    param([string]$Mode = 'Custom')

    $runId = 'run-{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 6))
    [pscustomobject]@{
        RunId       = $runId
        Started     = (Get-Date).ToString('o')
        Machine     = $env:COMPUTERNAME
        User        = $env:USERNAME
        Mode        = $Mode
        PolishVer   = $script:PolishVersion
        RestorePoint = $null
        Entries     = [System.Collections.ArrayList]::new()
    }
}

<#
  Record one reversal. Called by the Set-Polish* helpers, never by action code
  directly, which is what guarantees completeness.

  Type:
    registry  Path, Name, PrevValue, PrevType, Existed
    service   Name, PrevStartMode, PrevStatus
    task      Path, Name, PrevState
    appx      Name, PackageFullName, WingetId   (reinstall only, not true undo)
    startup   Key, Name, PrevBlob, Existed
    none      informational, nothing to reverse
#>
function Add-PolishUndo {
    param($Run, [string]$ActionId, [string]$Type, [hashtable]$Data)

    [void]$Run.Entries.Add([pscustomobject]@{
        ActionId = $ActionId
        Type     = $Type
        At       = (Get-Date).ToString('o')
        Data     = $Data
    })
}

function Save-PolishRun {
    param($Run)

    $dir = Join-Path (Get-PolishDataDir) 'runs'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $file = Join-Path $dir ($Run.RunId + '.json')
    $Run | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $file -Encoding utf8
    return $file
}

function Get-PolishRuns {
    $dir = Join-Path (Get-PolishDataDir) 'runs'
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    return @(Get-ChildItem -LiteralPath $dir -Filter 'run-*.json' -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending)
}

function Import-PolishRun {
    param([string]$Path)
    try { return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) }
    catch { return $null }
}

<#
  Replay a manifest backwards. Returns a per entry result so the caller can
  report honestly which reversals worked and which could not.
#>
function Undo-PolishRun {
    param($Run, [scriptblock]$Log)

    function _say($m, $lvl) { if ($Log) { & $Log $m $lvl } }

    $results = @()
    $entries = @($Run.Entries)
    [array]::Reverse($entries)

    foreach ($e in $entries) {
        $ok = $false
        $note = ''

        try {
            switch ($e.Type) {

                'registry' {
                    $d = $e.Data
                    if (-not (Test-Path -LiteralPath $d.Path)) {
                        New-Item -Path $d.Path -Force | Out-Null
                    }
                    if ($d.Existed) {
                        $type = $d.PrevType
                        if (-not $type) { $type = 'DWord' }
                        Set-ItemProperty -LiteralPath $d.Path -Name $d.Name -Value $d.PrevValue -Type $type -Force -ErrorAction Stop
                        $note = "restored to $($d.PrevValue)"
                    } else {
                        Remove-ItemProperty -LiteralPath $d.Path -Name $d.Name -Force -ErrorAction Stop
                        $note = 'removed (did not exist before)'
                    }
                    $ok = $true
                }

                'service' {
                    $d = $e.Data
                    $svc = Get-Service -Name $d.Name -ErrorAction Stop
                    $mode = $d.PrevStartMode
                    # Win32 StartMode words -> Set-Service values
                    switch ($mode) {
                        'Auto'      { $mode = 'Automatic' }
                        'Automatic' { $mode = 'Automatic' }
                        'Manual'    { $mode = 'Manual' }
                        'Disabled'  { $mode = 'Disabled' }
                        default     { $mode = 'Manual' }
                    }
                    Set-Service -Name $d.Name -StartupType $mode -ErrorAction Stop
                    if ($d.PrevStatus -eq 'Running' -and $svc.Status -ne 'Running') {
                        Start-Service -Name $d.Name -ErrorAction SilentlyContinue
                    }
                    $note = "start type back to $mode"
                    $ok = $true
                }

                'task' {
                    $d = $e.Data
                    if ($d.PrevState -eq 'Disabled') {
                        Disable-ScheduledTask -TaskPath $d.Path -TaskName $d.Name -ErrorAction Stop | Out-Null
                        $note = 'left disabled (was disabled before)'
                    } else {
                        Enable-ScheduledTask -TaskPath $d.Path -TaskName $d.Name -ErrorAction Stop | Out-Null
                        $note = 're-enabled'
                    }
                    $ok = $true
                }

                'startup' {
                    $d = $e.Data
                    if (-not (Test-Path -LiteralPath $d.Key)) { New-Item -Path $d.Key -Force | Out-Null }
                    if ($d.Existed) {
                        $blob = [byte[]]@($d.PrevBlob)
                        Set-ItemProperty -LiteralPath $d.Key -Name $d.Name -Value $blob -Type Binary -Force -ErrorAction Stop
                        $note = 'previous state restored'
                    } else {
                        Remove-ItemProperty -LiteralPath $d.Key -Name $d.Name -Force -ErrorAction Stop
                        $note = 'entry removed, back to default enabled'
                    }
                    $ok = $true
                }

                'appx' {
                    # Store apps cannot be restored from a manifest. Offer the
                    # reinstall command instead of pretending otherwise.
                    $d = $e.Data
                    $cmd = $null
                    if ($d.WingetId) { $cmd = "winget install --id $($d.WingetId) --accept-package-agreements --accept-source-agreements" }
                    if ($cmd) {
                        _say "  $($d.Name): run  $cmd" 'warn'
                        $note = 'needs reinstall, command printed'
                    } else {
                        _say "  $($d.Name): reinstall from the Microsoft Store" 'warn'
                        $note = 'needs reinstall from Store'
                    }
                    $ok = $false
                }

                'none' { $ok = $true; $note = 'nothing to reverse' }

                default { $note = "unknown undo type '$($e.Type)'" }
            }
        } catch {
            $note = $_.Exception.Message
            $ok = $false
        }

        $label = '  [ok]  '
        $lvl = 'ok'
        if (-not $ok) { $label = '  [--]  '; $lvl = 'warn' }
        if ($e.Type -ne 'none') {
            _say ("{0}{1,-28} {2}" -f $label, $e.ActionId, $note) $lvl
        }

        $results += [pscustomobject]@{ ActionId = $e.ActionId; Type = $e.Type; Reversed = $ok; Note = $note }
    }

    return $results
}
