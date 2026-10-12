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
#region POLISH_BUNDLED_SOURCES
# ---------------------------------------------------------------------------
#  This file is GENERATED. Do not edit it by hand.
#  Built from src/ by build/Build-SingleFile.ps1 on 2026-10-12 11:02
#  Edit the files under src/ and rebuild.
# ---------------------------------------------------------------------------

# ==========================================================================
#  src\Core\Detect.ps1
# ==========================================================================
<#
    Polish - hardware and OS detection

    Everything downstream is gated on this. An action that does not apply to
    the machine in front of us must never be offered, because a disabled-looking
    checkbox that silently does nothing is worse than no checkbox.
#>

function Get-PolishSystem {
    [CmdletBinding()]
    param()

    $os   = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $cs   = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $cpu  = @(Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue)[0]
    $encl = @(Get-CimInstance Win32_SystemEnclosure -ErrorAction SilentlyContinue)

    # ---- Windows version ------------------------------------------------
    $build = 0
    if ($os.BuildNumber) { $build = [int]$os.BuildNumber }

    # Windows 11 is build 22000+. Below that is Windows 10, whatever the
    # Caption claims, and a surprising number of tweaks differ between them.
    $winMajor = 10
    if ($build -ge 22000) { $winMajor = 11 }

    # ---- chassis: laptop or not ----------------------------------------
    # 8 Portable, 9 Laptop, 10 Notebook, 11 Hand Held, 12 Docking Station,
    # 14 Sub Notebook, 30 Tablet, 31 Convertible, 32 Detachable
    $laptopTypes = @(8, 9, 10, 11, 12, 14, 30, 31, 32)
    $isLaptop = $false
    foreach ($e in $encl) {
        foreach ($t in @($e.ChassisTypes)) {
            if ($laptopTypes -contains [int]$t) { $isLaptop = $true }
        }
    }
    # battery present is a second opinion; virtual machines report odd chassis
    if (-not $isLaptop) {
        if (Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue) { $isLaptop = $true }
    }

    # ---- OEM ------------------------------------------------------------
    $mfrRaw = ''
    if ($cs.Manufacturer) { $mfrRaw = $cs.Manufacturer }
    $oem = 'Generic'
    switch -Regex ($mfrRaw) {
        'ASUS'                  { $oem = 'ASUS' }
        'Dell'                  { $oem = 'Dell' }
        'HP|Hewlett'            { $oem = 'HP' }
        'LENOVO'                { $oem = 'Lenovo' }
        'Micro-Star|MSI'        { $oem = 'MSI' }
        'Acer'                  { $oem = 'Acer' }
        'Samsung'               { $oem = 'Samsung' }
        'Framework'             { $oem = 'Framework' }
        'Razer'                 { $oem = 'Razer' }
        'Gigabyte'              { $oem = 'Gigabyte' }
        'Microsoft Corporation' { $oem = 'Surface' }
        'VMware|VirtualBox|QEMU|Xen|Parallels|innotek' { $oem = 'VirtualMachine' }
    }

    # ---- GPUs -----------------------------------------------------------
    $gpus = @()
    foreach ($v in (Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)) {
        $vendor = 'Unknown'
        switch -Regex ($v.Name) {
            'NVIDIA|GeForce|Quadro|RTX|GTX' { $vendor = 'NVIDIA' }
            'AMD|Radeon|ATI'                { $vendor = 'AMD' }
            'Intel|UHD|Iris|Arc'            { $vendor = 'Intel' }
            'Microsoft Basic|Remote'        { $vendor = 'Basic' }
        }
        $gpus += [pscustomobject]@{
            Name          = $v.Name
            Vendor        = $vendor
            DriverVersion = $v.DriverVersion
            DriverDate    = $v.DriverDate
        }
    }
    $gpuVendors = @($gpus | Where-Object { $_.Vendor -notin @('Unknown', 'Basic') } |
                   Select-Object -ExpandProperty Vendor -Unique)

    # ---- memory ---------------------------------------------------------
    $dimms = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue)
    $slots = 0
    foreach ($a in (Get-CimInstance Win32_PhysicalMemoryArray -ErrorAction SilentlyContinue)) {
        $slots += [int]$a.MemoryDevices
    }
    $ramTotalGB = 0
    if ($os.TotalVisibleMemorySize) { $ramTotalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2) }

    # Distinct populated channels, read from BankLabel/DeviceLocator. Not every
    # firmware reports these usefully, so treat 'unknown' as 'do not advise'.
    $channels = @($dimms | ForEach-Object {
        $l = "$($_.BankLabel) $($_.DeviceLocator)"
        if ($l -match 'CHANNEL\s*([A-D])') { $matches[1] }
        elseif ($l -match 'DIMM\s*([A-D])') { $matches[1] }
        else { $null }
    } | Where-Object { $_ } | Select-Object -Unique)

    $memoryLayout = 'Unknown'
    if ($dimms.Count -gt 0 -and $slots -gt 0) {
        if ($dimms.Count -eq 1 -and $slots -ge 2)      { $memoryLayout = 'SingleChannel' }
        elseif ($channels.Count -ge 2)                  { $memoryLayout = 'MultiChannel' }
        elseif ($dimms.Count -ge 2)                     { $memoryLayout = 'MultiChannel' }
    }

    # ---- storage --------------------------------------------------------
    $disks = @()
    foreach ($d in (Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
        $disks += [pscustomobject]@{
            Name   = $d.FriendlyName
            Media  = $d.MediaType       # SSD / HDD / Unspecified
            SizeGB = [math]::Round($d.Size / 1GB, 1)
            Health = $d.HealthStatus
        }
    }
    # Where does Windows actually live? That is the one that matters for TRIM
    # vs defrag and for whether disabling SysMain is a good idea.
    $sysDriveIsSSD = $null
    try {
        $sysLetter = ($env:SystemDrive).TrimEnd(':')
        $part = Get-Partition -DriveLetter $sysLetter -ErrorAction Stop
        $pd = Get-PhysicalDisk -ErrorAction Stop | Where-Object { $_.DeviceId -eq $part.DiskNumber }
        if ($pd) {
            if ($pd.MediaType -eq 'SSD') { $sysDriveIsSSD = $true }
            elseif ($pd.MediaType -eq 'HDD') { $sysDriveIsSSD = $false }
        }
    } catch { }

    # ---- privilege ------------------------------------------------------
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = ([Security.Principal.WindowsPrincipal]$id).IsInRole(
                   [Security.Principal.WindowsBuiltInRole]::Administrator)

    # ---- misc -----------------------------------------------------------
    $isVM = ($oem -eq 'VirtualMachine')
    if (-not $isVM -and $cs.Model -match 'Virtual|VMware|KVM|Bochs') { $isVM = $true }

    [pscustomobject]@{
        # OS
        OsCaption     = $os.Caption
        OsBuild       = $build
        OsVersion     = $os.Version
        WindowsMajor  = $winMajor
        IsWindows11   = ($winMajor -eq 11)
        Edition       = $os.OperatingSystemSKU
        Uptime        = (Get-Date) - $os.LastBootUpTime

        # machine
        Manufacturer  = $mfrRaw
        Model         = $cs.Model
        Oem           = $oem
        IsLaptop      = $isLaptop
        IsVM          = $isVM

        # cpu
        CpuName       = $cpu.Name
        CpuCores      = $cpu.NumberOfCores
        CpuThreads    = $cpu.NumberOfLogicalProcessors

        # gpu
        Gpus          = $gpus
        GpuVendors    = $gpuVendors
        HasNvidia     = ($gpuVendors -contains 'NVIDIA')
        HasAmd        = ($gpuVendors -contains 'AMD')
        HasIntelGpu   = ($gpuVendors -contains 'Intel')

        # memory
        RamTotalGB    = $ramTotalGB
        RamSticks     = $dimms.Count
        RamSlots      = $slots
        MemoryLayout  = $memoryLayout

        # storage
        Disks         = $disks
        SysDriveIsSSD = $sysDriveIsSSD

        # session
        IsAdmin       = $isAdmin
        UserName      = $env:USERNAME
        PsVersion     = $PSVersionTable.PSVersion.ToString()
    }
}

<#
  Candidate GPU shader cache locations.

  These are probed for existence rather than assumed: vendors move them between
  driver generations, and guessing a path that does not exist would report a
  cleanup that never happened. Only directories that are actually present are
  returned.
#>
function Get-PolishShaderCachePaths {
    param($Sys)

    $L = $env:LOCALAPPDATA
    $candidates = @()

    if ($Sys.HasNvidia) {
        $candidates += [pscustomobject]@{ Vendor = 'NVIDIA'; Path = "$L\NVIDIA\DXCache" }
        $candidates += [pscustomobject]@{ Vendor = 'NVIDIA'; Path = "$L\NVIDIA\GLCache" }
        $candidates += [pscustomobject]@{ Vendor = 'NVIDIA'; Path = "$L\NVIDIA\ComputeCache" }
        $candidates += [pscustomobject]@{ Vendor = 'NVIDIA'; Path = "$L\NVIDIA Corporation\NV_Cache" }
    }
    if ($Sys.HasAmd) {
        $candidates += [pscustomobject]@{ Vendor = 'AMD'; Path = "$L\AMD\DxCache" }
        $candidates += [pscustomobject]@{ Vendor = 'AMD'; Path = "$L\AMD\DxcCache" }
        $candidates += [pscustomobject]@{ Vendor = 'AMD'; Path = "$L\AMD\GLCache" }
        $candidates += [pscustomobject]@{ Vendor = 'AMD'; Path = "$L\AMD\VkCache" }
    }
    if ($Sys.HasIntelGpu) {
        $candidates += [pscustomobject]@{ Vendor = 'Intel'; Path = "$L\Intel\ShaderCache" }
        $candidates += [pscustomobject]@{ Vendor = 'Intel'; Path = "$L\Intel\GLCache" }
    }

    # vendor neutral, present on effectively every machine
    $candidates += [pscustomobject]@{ Vendor = 'DirectX'; Path = "$L\D3DSCache" }

    return @($candidates | Where-Object { Test-Path -LiteralPath $_.Path })
}

function Format-PolishSize {
    param([double]$Bytes)
    if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N0} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} B' -f $Bytes)
}

function Get-PolishSystemSummary {
    param($Sys)

    $lines = @()
    $lines += ('{0}  (build {1})' -f $Sys.OsCaption, $Sys.OsBuild)
    $lines += ('{0} {1}' -f $Sys.Manufacturer, $Sys.Model).Trim()

    $form = 'Desktop'
    if ($Sys.IsLaptop) { $form = 'Laptop' }
    if ($Sys.IsVM)     { $form = 'Virtual machine' }
    $lines += ('{0}   OEM profile: {1}' -f $form, $Sys.Oem)

    $lines += ('{0}   {1}C / {2}T' -f $Sys.CpuName, $Sys.CpuCores, $Sys.CpuThreads)

    foreach ($g in $Sys.Gpus) {
        if ($g.Vendor -eq 'Basic') { continue }
        $lines += ('GPU: {0}   driver {1}' -f $g.Name, $g.DriverVersion)
    }

    $memNote = ''
    if ($Sys.MemoryLayout -eq 'SingleChannel') {
        $memNote = '   SINGLE CHANNEL: a second stick would help more than this tool can'
    }
    $lines += ('RAM: {0} GB in {1} of {2} slot(s){3}' -f $Sys.RamTotalGB, $Sys.RamSticks, $Sys.RamSlots, $memNote)

    $sd = 'unknown'
    if ($Sys.SysDriveIsSSD -eq $true)  { $sd = 'SSD' }
    if ($Sys.SysDriveIsSSD -eq $false) { $sd = 'HDD' }
    $lines += ('System drive: {0}' -f $sd)

    $priv = 'standard user'
    if ($Sys.IsAdmin) { $priv = 'administrator' }
    $lines += ('Running as: {0}   PowerShell {1}' -f $priv, $Sys.PsVersion)

    return $lines
}


# ==========================================================================
#  src\Core\Safety.ps1
# ==========================================================================
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


# ==========================================================================
#  src\Core\Engine.ps1
# ==========================================================================
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


# ==========================================================================
#  src\Modules\Processes.ps1
# ==========================================================================
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


# ==========================================================================
#  src\Modules\Bloat.ps1
# ==========================================================================
<#
    Polish - Store apps and vendor preinstalls

    Discovery is live. The curated list below only decides what gets SUGGESTED;
    anything actually installed is shown with its real size so the user decides.

    Reinstall honesty: once Remove-AppxPackage runs, the payload is gone. There
    is no manifest trick that brings it back for a package removed for every
    user. So Polish does not print a winget command it cannot verify works. It
    says "reinstall from the Microsoft Store", which is true.
#>

# Microsoft inbox apps that are commonly unwanted and safe to remove.
# Anything load bearing is in $script:ProtectedAppx and cannot reach here.
$script:MsBloat = @(
    @{ N = 'Microsoft.ZuneMusic';                      L = 'Media Player' }
    @{ N = 'Microsoft.ZuneVideo';                      L = 'Films & TV' }
    @{ N = 'Microsoft.WindowsMaps';                    L = 'Maps' }
    @{ N = 'Microsoft.WindowsAlarms';                  L = 'Clock & Alarms' }
    @{ N = 'Microsoft.WindowsSoundRecorder';           L = 'Sound Recorder' }
    @{ N = 'Microsoft.WindowsFeedbackHub';             L = 'Feedback Hub' }
    @{ N = 'Microsoft.GetHelp';                        L = 'Get Help' }
    @{ N = 'Microsoft.Getstarted';                     L = 'Tips / Get Started' }
    @{ N = 'Microsoft.MicrosoftOfficeHub';             L = 'Office hub advert' }
    @{ N = 'Microsoft.MicrosoftSolitaireCollection';   L = 'Solitaire (with ads)' }
    @{ N = 'Microsoft.BingNews';                       L = 'Bing News' }
    @{ N = 'Microsoft.BingWeather';                     L = 'Weather' }
    @{ N = 'Microsoft.BingSearch';                      L = 'Bing web search app' }
    @{ N = 'Microsoft.BingFinance';                     L = 'Finance' }
    @{ N = 'Microsoft.BingSports';                      L = 'Sports' }
    @{ N = 'Microsoft.People';                          L = 'People' }
    @{ N = 'Microsoft.YourPhone';                       L = 'Phone Link' }
    @{ N = 'Microsoft.windowscommunicationsapps';       L = 'Mail & Calendar' }
    @{ N = 'Microsoft.OutlookForWindows';               L = 'new Outlook' }
    @{ N = 'Microsoft.Todos';                           L = 'To Do' }
    @{ N = 'Microsoft.PowerAutomateDesktop';            L = 'Power Automate' }
    @{ N = 'Microsoft.MixedReality.Portal';             L = 'Mixed Reality Portal' }
    @{ N = 'Microsoft.3DBuilder';                       L = '3D Builder' }
    @{ N = 'Microsoft.Print3D';                         L = 'Print 3D' }
    @{ N = 'Microsoft.Microsoft3DViewer';               L = '3D Viewer' }
    @{ N = 'Microsoft.MSPaint';                         L = 'Paint 3D' }
    @{ N = 'Microsoft.SkypeApp';                        L = 'Skype' }
    @{ N = 'Microsoft.Wallet';                          L = 'Wallet' }
    @{ N = 'MicrosoftTeams';                            L = 'Teams (personal)' }
    @{ N = 'MSTeams';                                   L = 'Teams' }
    @{ N = 'MicrosoftCorporationII.QuickAssist';        L = 'Quick Assist' }
    @{ N = 'MicrosoftCorporationII.MicrosoftFamily';    L = 'Family Safety' }
    @{ N = 'Microsoft.Windows.DevHome';                 L = 'Dev Home' }
    @{ N = 'MicrosoftWindows.Client.WebExperience';     L = 'Widgets panel' }
    @{ N = 'Microsoft.WidgetsPlatformRuntime';          L = 'Widgets runtime' }
    @{ N = 'Microsoft.StartExperiencesApp';             L = 'Start suggestions' }
    @{ N = 'Microsoft.Copilot';                         L = 'Copilot app' }
    @{ N = 'Microsoft.Windows.Ai.Copilot.Provider';     L = 'Copilot provider' }
    @{ N = 'Clipchamp.Clipchamp';                       L = 'Clipchamp' }
    @{ N = 'Microsoft.OneDriveSync';                    L = 'OneDrive sync (Store build)' }
)

# Vendor and carrier preinstalls. Publisher-prefix matched, since OEMs change
# the suffix constantly.
$script:OemBloatPrefixes = @(
    'B9ECED6F'                 # ASUS (ArmouryCrate, AuraCreator, GlideX...)
    'AsusComputerInternational'
    'DellInc.'                 # Dell Digital Delivery, SupportAssist, Mobile Connect
    'DellTechnologies'
    'AD2F1837'                 # HP (HP Support Assistant, HP QuickDrop, HP Smart...)
    'HPInc.'
    'E046963F'                 # Lenovo (Vantage, Smart Appearance...)
    'LenovoCorporation'
    '4505Fortemedia'
    'AcerIncorporated'
    'MicroStarINTERNATIONAL'
    'RealtekSemiconductorCorp.RealtekWirelessLan'
    'Disney'                   # the Disney+ preinstall stub
    'SpotifyAB.SpotifyMusic'   # preinstalled stub, not a user install
    'Facebook.'
    'BytedancePte.Ltd.TikTok'
    'king.com.'                # Candy Crush family
    'AmazonVideo.PrimeVideo'
    'Netflix.'
    '5A894077'                 # Instagram stub
)

function Get-PolishAppxReport {
    [CmdletBinding()]
    param()

    $all = @(Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { -not $_.IsFramework })
    $rows = @()

    foreach ($p in $all) {
        $protected = Test-PolishProtectedAppx -Name $p.Name

        $cat = 'Other'
        $label = $p.Name
        foreach ($b in $script:MsBloat) {
            if ($p.Name -eq $b.N) { $cat = 'MsBloat'; $label = $b.L; break }
        }
        if ($cat -eq 'Other') {
            foreach ($pre in $script:OemBloatPrefixes) {
                if ($p.Name -like "$pre*") { $cat = 'OemBloat'; break }
            }
        }
        if ($protected) { $cat = 'Protected' }

        # size on disk. InstallLocation can be missing for staged packages.
        $bytes = 0
        if ($p.InstallLocation -and (Test-Path -LiteralPath $p.InstallLocation)) {
            try {
                $bytes = (Get-ChildItem -LiteralPath $p.InstallLocation -Recurse -Force -File -ErrorAction SilentlyContinue |
                          Measure-Object -Property Length -Sum).Sum
                if (-not $bytes) { $bytes = 0 }
            } catch { }
        }

        $rows += [pscustomobject]@{
            Name      = $p.Name
            Label     = $label
            Publisher = $p.Publisher
            Version   = $p.Version
            Bytes     = [long]$bytes
            Category  = $cat
            Protected = $protected
            NonRemovable = [bool]$p.NonRemovable
        }
    }

    return @($rows | Sort-Object @{E = 'Category'; D = $false}, @{E = 'Bytes'; D = $true})
}

function Get-PolishAppxSuggestions {
    param($Rows, [string]$Category = 'MsBloat')
    return @($Rows | Where-Object { $_.Category -eq $Category -and -not $_.Protected -and -not $_.NonRemovable })
}

# ===========================================================================
#  Services discovery
# ===========================================================================
<#
  Research finding that shapes this: there is no authoritative per vendor list
  of which OEM services are safe to disable, and hotkeys, touchpads, fan curves
  and power profiles live in them. So services are reported in three buckets
  and only the first is ever suggested:

    Updater   its only job is checking for updates. Safe to set to Manual.
    Unknown   third-party, auto-start, not obviously an updater. Shown, never
              pre-ticked, labelled honestly as unknown risk.
    Protected matched the protect list or patterns. Not offered at all.
#>
function Get-PolishServiceReport {
    [CmdletBinding()]
    param()

    $updaterRx = '(?i)(update|upgrade|installer service|clicktorun|googleupdate|edgeupdate|mozillamaintenance|adobeupdate|brave.*update|opera.*update)'
    $rows = @()

    $svcs = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
              Where-Object { $_.StartMode -in @('Auto', 'Automatic') })

    foreach ($s in $svcs) {
        $protected = Test-PolishProtectedService -Name $s.Name -DisplayName $s.DisplayName

        # Treat anything living under \Windows\ as Microsoft-owned and off limits
        # for this module; Windows' own services are handled by named actions.
        $isWindows = $false
        if ($s.PathName -and $s.PathName -match '(?i)[\\/]Windows[\\/]') { $isWindows = $true }

        $cat = 'Unknown'
        if ($protected -or $isWindows) { $cat = 'Protected' }
        elseif (("$($s.Name) $($s.DisplayName) $($s.PathName)") -match $updaterRx) { $cat = 'Updater' }

        $rows += [pscustomobject]@{
            Name        = $s.Name
            DisplayName = $s.DisplayName
            State       = $s.State
            StartMode   = $s.StartMode
            Path        = $s.PathName
            Category    = $cat
        }
    }

    return @($rows | Sort-Object Category, DisplayName)
}


# ==========================================================================
#  src\Core\Catalog.ps1
# ==========================================================================
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


# ==========================================================================
#  src\Cli.ps1
# ==========================================================================
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


# ==========================================================================
#  src\UI\Window.ps1
# ==========================================================================
<#
    Polish - window (WPF)

    Threading note: actions run synchronously on the UI thread with a dispatcher
    pump between log lines. A background runspace would keep the window
    draggable during long operations, but it would need the whole Polish source
    marshalled into it, and when Polish is served through  irm <url> | iex
    there is no file on disk to hand to a child process. The pump keeps the log
    live and repainting, which is what actually matters. The two genuinely slow
    actions (component cleanup, integrity scan) say so on the label.
#>

function Show-PolishWindow {
    param($Sys, $Actions)

    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
        Add-Type -AssemblyName PresentationCore, WindowsBase -ErrorAction Stop
    } catch {
        Write-PolishLine "WPF is unavailable here: $($_.Exception.Message)" 'warn'
        return
    }

    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Polish" Height="760" Width="1060" MinHeight="620" MinWidth="900"
        WindowStartupLocation="CenterScreen" Background="#FF17171A">
  <Window.Resources>
    <SolidColorBrush x:Key="Fg"      Color="#FFE7E7EA"/>
    <SolidColorBrush x:Key="Muted"   Color="#FF9A9AA4"/>
    <SolidColorBrush x:Key="Panel"   Color="#FF212126"/>
    <SolidColorBrush x:Key="Accent"  Color="#FF6C6CF5"/>
    <SolidColorBrush x:Key="Ok"      Color="#FF4ADE80"/>
    <SolidColorBrush x:Key="Warn"    Color="#FFFACC15"/>

    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="Margin" Value="0,7,0,0"/>
    </Style>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Background" Value="{StaticResource Panel}"/>
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="14,9"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="Cursor" Value="Hand"/>
    </Style>
    <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="{StaticResource Accent}"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
  </Window.Resources>

  <Grid Margin="18">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="190"/>
    </Grid.RowDefinitions>

    <!-- header -->
    <Grid Grid.Row="0">
      <StackPanel Orientation="Horizontal">
        <TextBlock Text="Polish" FontSize="26" FontWeight="Bold"/>
        <TextBlock x:Name="VerText" Foreground="{StaticResource Muted}" FontSize="12"
                   VerticalAlignment="Bottom" Margin="10,0,0,5"/>
      </StackPanel>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <Button x:Name="BtnProcs"  Style="{StaticResource Btn}" Content="What's running" Margin="0,0,8,0"/>
        <Button x:Name="BtnUndo"   Style="{StaticResource Btn}" Content="Undo last run"  Margin="0,0,8,0"/>
        <Button x:Name="BtnRuns"   Style="{StaticResource Btn}" Content="History"/>
      </StackPanel>
    </Grid>

    <!-- machine summary -->
    <Border Grid.Row="1" Background="{StaticResource Panel}" CornerRadius="6" Padding="14" Margin="0,14,0,0">
      <StackPanel>
        <TextBlock x:Name="SysText" Foreground="{StaticResource Muted}" FontSize="12" TextWrapping="Wrap"/>
        <TextBlock x:Name="WarnText" Foreground="{StaticResource Warn}" FontSize="12"
                   TextWrapping="Wrap" Margin="0,8,0,0" Visibility="Collapsed"/>
      </StackPanel>
    </Border>

    <!-- modules + actions -->
    <Grid Grid.Row="2" Margin="0,14,0,0">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="190"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <Border Grid.Column="0" Background="{StaticResource Panel}" CornerRadius="6" Padding="6">
        <ListBox x:Name="ModuleList" Background="Transparent" BorderThickness="0"
                 Foreground="{StaticResource Fg}" FontFamily="Segoe UI" FontSize="13"/>
      </Border>

      <Border Grid.Column="1" Background="{StaticResource Panel}" CornerRadius="6"
              Padding="16" Margin="12,0,0,0">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel x:Name="ActionPanel"/>
        </ScrollViewer>
      </Border>
    </Grid>

    <!-- buttons -->
    <Grid Grid.Row="3" Margin="0,14,0,0">
      <StackPanel Orientation="Horizontal">
        <Button x:Name="BtnOptimize" Style="{StaticResource BtnPrimary}" Content="OPTIMIZE NOW"
                FontSize="14" Padding="22,12" Margin="0,0,10,0"/>
        <Button x:Name="BtnRun"      Style="{StaticResource Btn}" Content="Run selected" Margin="0,0,10,0"/>
        <Button x:Name="BtnDry"      Style="{StaticResource Btn}" Content="Dry run"      Margin="0,0,10,0"/>
      </StackPanel>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <Button x:Name="BtnSafe"  Style="{StaticResource Btn}" Content="Select safe"   Margin="0,0,8,0"/>
        <Button x:Name="BtnNone"  Style="{StaticResource Btn}" Content="Clear all"/>
      </StackPanel>
    </Grid>

    <!-- log -->
    <Border Grid.Row="4" Background="#FF101012" CornerRadius="6" Padding="10" Margin="0,12,0,0">
      <ScrollViewer x:Name="LogScroll" VerticalScrollBarVisibility="Auto">
        <TextBox x:Name="LogBox" Background="Transparent" Foreground="#FFC8C8CD"
                 BorderThickness="0" FontFamily="Consolas" FontSize="12"
                 IsReadOnly="True" TextWrapping="NoWrap" AcceptsReturn="True"/>
      </ScrollViewer>
    </Border>
  </Grid>
</Window>
'@

    try {
        $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
        $win = [Windows.Markup.XamlReader]::Load($reader)
    } catch {
        Write-PolishLine "could not build the window: $($_.Exception.Message)" 'warn'
        return
    }

    # grab named elements
    $ui = @{}
    foreach ($n in @('VerText', 'SysText', 'WarnText', 'ModuleList', 'ActionPanel', 'LogBox', 'LogScroll',
                     'BtnOptimize', 'BtnRun', 'BtnDry', 'BtnSafe', 'BtnNone',
                     'BtnProcs', 'BtnUndo', 'BtnRuns')) {
        $ui[$n] = $win.FindName($n)
    }

    $ui.VerText.Text = "v$script:PolishVersion"
    $ui.SysText.Text = (Get-PolishSystemSummary -Sys $Sys) -join '   |   '

    $warnings = @()
    if (-not $Sys.IsAdmin) {
        $warnings += 'Not running as administrator: actions marked (admin) are hidden or skipped, and no system restore point can be created. Right-click Polish and Run as administrator for the full set.'
    }
    if ($Sys.MemoryLayout -eq 'SingleChannel') {
        $warnings += 'This machine has one memory stick in a multi-slot board. Adding a matching stick would do more for performance than anything in this tool.'
    }
    if ($Sys.IsVM) { $warnings += 'Virtual machine detected: hardware actions are hidden.' }
    if ($warnings.Count -gt 0) {
        $ui.WarnText.Text = ($warnings -join "`n")
        $ui.WarnText.Visibility = 'Visible'
    }

    # ---- logging into the TextBox, with a pump so it repaints -----------
    $script:PolishUiWin = $win
    $script:PolishUiLog = $ui.LogBox
    $script:PolishUiScroll = $ui.LogScroll

    $uiLogger = {
        param([string]$Message, [string]$Level = 'info')

        $tag = '       '
        switch ($Level) {
            'ok'    { $tag = '  ok   ' }
            'warn'  { $tag = '  !    ' }
            'skip'  { $tag = '  -    ' }
            'head'  { $tag = '' }
            'title' { $tag = '' }
        }
        $script:PolishUiLog.AppendText($tag + $Message + "`r`n")
        $script:PolishUiScroll.ScrollToEnd()

        # also to the day log on disk
        if ($script:PolishLogFile) {
            Add-Content -LiteralPath $script:PolishLogFile -Value ((Get-Date -Format 'HH:mm:ss') + ' ' + $tag + $Message) -Encoding utf8 -ErrorAction SilentlyContinue
        }

        # let WPF process pending paint messages
        $script:PolishUiWin.Dispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Background, [action] {}) | Out-Null
    }

    # ---- build the action rows -----------------------------------------
    $script:PolishChecks = @{}   # action id -> CheckBox

    $riskBrush = @{
        'Safe'     = '#FF4ADE80'
        'Moderate' = '#FFFACC15'
        'Advanced' = '#FFF87171'
    }

    $renderModule = {
        param([string]$ModuleName)

        $ui.ActionPanel.Children.Clear()
        $list = @($Actions | Where-Object { $_.Module -eq $ModuleName })

        foreach ($a in $list) {
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.FontSize = 13
            $cb.FontWeight = 'SemiBold'

            # reuse an existing tick state if the user already set one
            if ($script:PolishChecks.ContainsKey($a.Id)) {
                $cb.IsChecked = $script:PolishChecks[$a.Id].IsChecked
            } else {
                $cb.IsChecked = [bool]$a.Default
            }

            $header = New-Object System.Windows.Controls.StackPanel
            $header.Orientation = 'Horizontal'

            $t = New-Object System.Windows.Controls.TextBlock
            $t.Text = $a.Name
            $t.Foreground = 'White'
            $header.Children.Add($t) | Out-Null

            $badge = New-Object System.Windows.Controls.TextBlock
            $bits = @($a.Risk, "undo: $($a.Undo)")
            if ($a.Reboot)     { $bits += 'needs restart' }
            if ($a.NeedsAdmin) { $bits += 'admin' }
            $badge.Text = '   ' + ($bits -join ' / ')
            $badge.FontSize = 11
            $badge.FontWeight = 'Normal'
            $badge.Foreground = $riskBrush[$a.Risk]
            $badge.VerticalAlignment = 'Center'
            $header.Children.Add($badge) | Out-Null

            $cb.Content = $header
            $ui.ActionPanel.Children.Add($cb) | Out-Null

            $d = New-Object System.Windows.Controls.TextBlock
            $d.Text = $a.Detail
            $d.FontSize = 11.5
            $d.Foreground = '#FF9A9AA4'
            $d.TextWrapping = 'Wrap'
            $d.Margin = '26,3,0,10'
            $ui.ActionPanel.Children.Add($d) | Out-Null

            $script:PolishChecks[$a.Id] = $cb
        }
    }

    foreach ($m in (Get-PolishModules -Actions $Actions)) { [void]$ui.ModuleList.Items.Add($m) }
    $ui.ModuleList.Add_SelectionChanged({
        if ($ui.ModuleList.SelectedItem) { & $renderModule $ui.ModuleList.SelectedItem }
    })
    $ui.ModuleList.SelectedIndex = 0

    # ---- helpers --------------------------------------------------------
    $getSelected = {
        $ids = @()
        foreach ($k in $script:PolishChecks.Keys) {
            if ($script:PolishChecks[$k].IsChecked) { $ids += $k }
        }
        return @($Actions | Where-Object { $ids -contains $_.Id })
    }

    $setBusy = {
        param([bool]$Busy)
        foreach ($b in @('BtnOptimize', 'BtnRun', 'BtnDry', 'BtnUndo', 'BtnProcs', 'BtnSafe', 'BtnNone', 'BtnRuns')) {
            $ui[$b].IsEnabled = -not $Busy
        }
    }

    $runThese = {
        param($Selected, [bool]$Dry, [string]$ModeName)

        if ($Selected.Count -eq 0) {
            $ui.LogBox.AppendText("  !    nothing ticked`r`n")
            return
        }
        $ui.LogBox.Clear()
        & $setBusy $true
        try {
            [void](Invoke-PolishRun -Sys $Sys -Selected $Selected -DryRun:$Dry -Logger $uiLogger -Mode $ModeName)
        } catch {
            & $uiLogger ("run failed: " + $_.Exception.Message) 'warn'
        } finally {
            & $setBusy $false
        }
    }

    # ---- wiring ---------------------------------------------------------
    $ui.BtnOptimize.Add_Click({
        # the one-click, no-restart path: close idle background apps, free RAM,
        # flush DNS, make sure Game Mode is on. Nothing destructive.
        $ids = @('optimize.closebg', 'optimize.trimram', 'optimize.flushdns', 'gaming.gamemode')
        $sel = @($Actions | Where-Object { $ids -contains $_.Id })
        & $runThese $sel $false 'optimize-now'
    })

    $ui.BtnRun.Add_Click({ & $runThese (& $getSelected) $false 'gui-custom' })
    $ui.BtnDry.Add_Click({ & $runThese (& $getSelected) $true  'gui-dryrun' })

    $ui.BtnSafe.Add_Click({
        foreach ($a in $Actions) {
            if ($script:PolishChecks.ContainsKey($a.Id)) {
                $script:PolishChecks[$a.Id].IsChecked = ($a.Risk -eq 'Safe' -and -not $a.Reboot)
            }
        }
    })
    $ui.BtnNone.Add_Click({
        foreach ($k in $script:PolishChecks.Keys) { $script:PolishChecks[$k].IsChecked = $false }
    })

    $ui.BtnProcs.Add_Click({
        $ui.LogBox.Clear()
        & $setBusy $true
        try {
            $rows = Get-PolishProcessReport
            $reap = Get-PolishReapSummary -Rows $rows
            & $uiLogger '=== What is running ===' 'head'
            & $uiLogger ('{0,-30} {1,5} {2,10}  {3}' -f 'PROCESS', '#', 'RAM', 'VERDICT') 'info'
            foreach ($r in $rows) {
                $v = switch ($r.Class) {
                    'Reapable'  { 'will close' }
                    'Protected' { 'protected' }
                    'Service'   { 'service, use Services module' }
                    'InUse'     { 'in use, left alone' }
                    'Sync'      { 'cloud sync' }
                    default     { 'background' }
                }
                $lvl = 'info'
                if ($r.Class -eq 'Reapable')  { $lvl = 'ok' }
                if ($r.Class -eq 'Protected' -or $r.Class -eq 'Service') { $lvl = 'skip' }
                & $uiLogger ('{0,-30} {1,5} {2,10}  {3}' -f $r.Name, $r.Count, (Format-PolishSize $r.Bytes), $v) $lvl
            }
            & $uiLogger '' 'head'
            if ($reap.Count -gt 0) {
                & $uiLogger ("OPTIMIZE NOW would close {0} app(s) holding {1}" -f $reap.Count, (Format-PolishSize $reap.Bytes)) 'ok'
            } else {
                & $uiLogger 'nothing reapable is running' 'ok'
            }
        } finally { & $setBusy $false }
    })

    $ui.BtnUndo.Add_Click({
        $runs = Get-PolishRuns
        if ($runs.Count -eq 0) {
            $ui.LogBox.Clear()
            & $uiLogger 'no Polish runs recorded yet, nothing to undo' 'warn'
            return
        }
        $m = Import-PolishRun -Path $runs[0].FullName
        $n = 0
        if ($m) { $n = @($m.Entries).Count }
        $r = [System.Windows.MessageBox]::Show(
            "Undo the most recent Polish run?`n`nRun: $($m.RunId)`nReversible items: $n`n`nStore apps that were removed and caches that were deleted cannot be restored this way; everything else goes back exactly as it was.",
            'Polish - undo', 'YesNo', 'Question')
        if ($r -ne 'Yes') { return }

        $ui.LogBox.Clear()
        & $setBusy $true
        try { Invoke-PolishUndo -Which 'Last' -Logger $uiLogger }
        finally { & $setBusy $false }
    })

    $ui.BtnRuns.Add_Click({
        $ui.LogBox.Clear()
        & $uiLogger '=== Run history ===' 'head'
        $runs = Get-PolishRuns
        if ($runs.Count -eq 0) { & $uiLogger 'none yet' 'skip'; return }
        foreach ($r in $runs) {
            $m = Import-PolishRun -Path $r.FullName
            if (-not $m) { continue }
            $undone = ''
            if ($m.PSObject.Properties.Name -contains 'UndoneAt' -and $m.UndoneAt) { $undone = '   (already undone)' }
            & $uiLogger ('{0}   {1,-14} {2,3} item(s){3}' -f $m.RunId, $m.Mode, @($m.Entries).Count, $undone) 'info'
        }
        & $uiLogger '' 'head'
        & $uiLogger ('manifests live in ' + (Join-Path (Get-PolishDataDir) 'runs')) 'skip'
    })

    # opening message
    $ui.LogBox.AppendText("Polish is ready.`r`n")
    $ui.LogBox.AppendText("OPTIMIZE NOW closes idle background apps and frees RAM. No restart, nothing deleted.`r`n")
    $ui.LogBox.AppendText("Everything else is opt-in. Tick what you want and use Dry run first if unsure.`r`n")
    $ui.LogBox.AppendText("Every reversible change is recorded, so Undo last run puts it back.`r`n")

    [void]$win.ShowDialog()
}

#endregion POLISH_BUNDLED_SOURCES

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
