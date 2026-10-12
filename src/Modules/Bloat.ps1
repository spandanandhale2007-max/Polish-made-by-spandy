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
