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
