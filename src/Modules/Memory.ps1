<#
    Polish - memory cache operations

    Windows keeps three distinct pools that people collectively call "RAM cache",
    and clearing each has a different cost. Polish exposes them separately with
    honest labels instead of one magic "Boost RAM" button:

      Standby list     File data cached in RAM. Shows as "Cached" in Task
                       Manager. Purging it frees physical RAM immediately, and
                       everything that needed that data re-reads it from disk.
      Modified list    Pages changed in RAM but not yet written to disk.
                       Flushing writes them out, which is a disk burst but
                       loses nothing.
      Working sets     Each process's resident pages. Trimming pushes them to
                       standby or the page file.

    The useful case for purging standby is real: you are about to launch
    something that wants a lot of contiguous physical memory (a large game, a
    VM, a render) and you would rather pay the disk re-read now than mid-task.
    Outside that, Windows manages this better than you can, and purging on a
    schedule just means re-reading from disk forever.

    Polish states that, does not pre-tick it, and then does exactly what it is
    asked. These calls need SeProfileSingleProcessPrivilege and administrator.
#>

function Initialize-PolishMemApi {
    if ('PolishMemApi' -as [type]) { return $true }
    try {
        Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class PolishMemApi
{
    [StructLayout(LayoutKind.Sequential)]
    public struct LUID { public uint LowPart; public int HighPart; }

    [StructLayout(LayoutKind.Sequential)]
    public struct LUID_AND_ATTRIBUTES { public LUID Luid; public uint Attributes; }

    [StructLayout(LayoutKind.Sequential)]
    public struct TOKEN_PRIVILEGES { public uint PrivilegeCount; public LUID_AND_ATTRIBUTES Privilege; }

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool OpenProcessToken(IntPtr h, uint access, out IntPtr token);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool LookupPrivilegeValue(string host, string name, out LUID luid);

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll,
        ref TOKEN_PRIVILEGES newState, uint len, IntPtr prev, IntPtr retLen);

    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr h);

    [DllImport("ntdll.dll")]
    static extern int NtSetSystemInformation(int infoClass, IntPtr info, int length);

    [DllImport("psapi.dll", SetLastError = true)]
    public static extern bool EmptyWorkingSet(IntPtr hProcess);

    // SYSTEM_INFORMATION_CLASS.SystemMemoryListInformation
    const int SystemMemoryListInformation = 0x50;
    const uint TOKEN_ADJUST_PRIVILEGES = 0x0020;
    const uint TOKEN_QUERY             = 0x0008;
    const uint SE_PRIVILEGE_ENABLED    = 0x0002;

    // SYSTEM_MEMORY_LIST_COMMAND
    public const int EmptyWorkingSets       = 2;
    public const int FlushModifiedList      = 3;
    public const int PurgeStandbyList       = 4;
    public const int PurgeLowPriorityStandby= 5;

    public static bool EnablePrivilege(string name)
    {
        IntPtr token;
        if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out token))
            return false;
        try
        {
            LUID luid;
            if (!LookupPrivilegeValue(null, name, out luid)) return false;

            TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
            tp.PrivilegeCount = 1;
            tp.Privilege.Luid = luid;
            tp.Privilege.Attributes = SE_PRIVILEGE_ENABLED;

            if (!AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero)) return false;
            // AdjustTokenPrivileges reports success even when it assigned nothing,
            // so the real answer is in the last error.
            return Marshal.GetLastWin32Error() == 0;
        }
        finally { CloseHandle(token); }
    }

    // Returns the NTSTATUS. 0 is success; anything else means nothing happened.
    public static int MemoryCommand(int command)
    {
        IntPtr p = Marshal.AllocHGlobal(sizeof(int));
        try
        {
            Marshal.WriteInt32(p, command);
            return NtSetSystemInformation(SystemMemoryListInformation, p, sizeof(int));
        }
        finally { Marshal.FreeHGlobal(p); }
    }
}
'@
        return $true
    } catch {
        return $false
    }
}

<#
  Language-neutral memory figures. Performance counter NAMES are localised, so
  this reads the raw perf class instead of Get-Counter with English strings.
#>
function Get-PolishMemoryDetail {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $m  = Get-CimInstance Win32_PerfRawData_PerfOS_Memory -ErrorAction SilentlyContinue

    $total = 0
    if ($os) { $total = [long]$os.TotalVisibleMemorySize * 1024 }

    $avail = 0
    if ($m -and $m.AvailableBytes) { $avail = [long]$m.AvailableBytes }
    elseif ($os) { $avail = [long]$os.FreePhysicalMemory * 1024 }

    $sbNormal = 0; $sbCore = 0; $sbReserve = 0; $modified = 0; $cache = 0
    if ($m) {
        if ($m.StandbyCacheNormalPriorityBytes) { $sbNormal  = [long]$m.StandbyCacheNormalPriorityBytes }
        if ($m.StandbyCacheCoreBytes)           { $sbCore    = [long]$m.StandbyCacheCoreBytes }
        if ($m.StandbyCacheReserveBytes)        { $sbReserve = [long]$m.StandbyCacheReserveBytes }
        if ($m.ModifiedPageListBytes)           { $modified  = [long]$m.ModifiedPageListBytes }
        if ($m.CacheBytes)                      { $cache     = [long]$m.CacheBytes }
    }
    $standby = $sbNormal + $sbCore + $sbReserve

    # "Free" in the Task Manager sense is available minus what is standby.
    $free = $avail - $standby
    if ($free -lt 0) { $free = 0 }

    [pscustomobject]@{
        TotalBytes     = $total
        AvailableBytes = $avail
        FreeBytes      = $free
        StandbyBytes   = $standby
        StandbyNormal  = $sbNormal
        StandbyCore    = $sbCore
        StandbyReserve = $sbReserve
        ModifiedBytes  = $modified
        CacheBytes     = $cache
        InUseBytes     = $total - $avail
    }
}

function Write-PolishMemoryReport {
    param($Ctx, $Detail, [string]$Label)

    Write-PolishCtx $Ctx ("{0,-22} total {1,10}   in use {2,10}   standby/cached {3,10}   free {4,10}" -f `
        $Label, (Format-PolishSize $Detail.TotalBytes), (Format-PolishSize $Detail.InUseBytes),
        (Format-PolishSize $Detail.StandbyBytes), (Format-PolishSize $Detail.FreeBytes)) 'info'
}

<#
  The operation people mean by "clear the RAM cache".

  $Mode:
    Standby      purge the whole standby list
    LowPriority  purge only the low-priority portion. Far gentler: it drops the
                 speculative read-ahead data first and leaves the cache that is
                 actually earning its keep. This is the sane default.
    Modified     flush modified pages to disk (writes, loses nothing)
    WorkingSets  ask every process to give up its resident pages
#>
function Invoke-PolishMemoryPurge {
    param($Ctx, [ValidateSet('Standby','LowPriority','Modified','WorkingSets')][string]$Mode = 'LowPriority')

    if (-not (Initialize-PolishMemApi)) {
        Write-PolishCtx $Ctx 'could not load the memory API on this system' 'warn'
        return [long]0
    }

    if (-not $Ctx.Sys.IsAdmin) {
        Write-PolishCtx $Ctx 'this needs administrator; nothing done' 'skip'
        return [long]0
    }

    $before = Get-PolishMemoryDetail
    Write-PolishMemoryReport -Ctx $Ctx -Detail $before -Label 'before'

    if ($Ctx.DryRun) {
        Write-PolishCtx $Ctx ("would run the '{0}' memory command" -f $Mode) 'ok'
        return [long]0
    }

    # These commands are privileged. Without this the call returns
    # STATUS_PRIVILEGE_NOT_HELD and silently does nothing.
    if (-not [PolishMemApi]::EnablePrivilege('SeProfileSingleProcessPrivilege')) {
        Write-PolishCtx $Ctx 'could not enable SeProfileSingleProcessPrivilege' 'warn'
        Write-PolishCtx $Ctx 'the kernel will refuse the purge, so stopping here' 'warn'
        return [long]0
    }

    $cmd = switch ($Mode) {
        'Standby'     { [PolishMemApi]::PurgeStandbyList }
        'LowPriority' { [PolishMemApi]::PurgeLowPriorityStandby }
        'Modified'    { [PolishMemApi]::FlushModifiedList }
        'WorkingSets' { [PolishMemApi]::EmptyWorkingSets }
    }

    $status = [PolishMemApi]::MemoryCommand($cmd)
    if ($status -ne 0) {
        # Report the real NTSTATUS rather than claiming a win.
        Write-PolishCtx $Ctx ("the kernel refused the request: NTSTATUS 0x{0:X8}" -f $status) 'warn'
        if ($status -eq -1073741727) { Write-PolishCtx $Ctx 'that status is STATUS_PRIVILEGE_NOT_HELD' 'warn' }
        return [long]0
    }

    Start-Sleep -Milliseconds 900
    $after = Get-PolishMemoryDetail
    Write-PolishMemoryReport -Ctx $Ctx -Detail $after -Label 'after'

    $standbyDrop = $before.StandbyBytes - $after.StandbyBytes
    $freeGain    = $after.FreeBytes - $before.FreeBytes

    switch ($Mode) {
        'Modified' {
            $drop = $before.ModifiedBytes - $after.ModifiedBytes
            Write-PolishCtx $Ctx ("modified pages written out: {0}" -f (Format-PolishSize $drop)) 'ok'
            Write-PolishCtx $Ctx 'nothing was lost; this only moved pending writes to disk' 'info'
        }
        default {
            if ($standbyDrop -gt 0) {
                Write-PolishCtx $Ctx ("cached memory released: {0}" -f (Format-PolishSize $standbyDrop)) 'ok'
            } else {
                Write-PolishCtx $Ctx 'cached memory barely moved; there was little worth purging' 'info'
            }
            if ($freeGain -gt 0) {
                Write-PolishCtx $Ctx ("free physical RAM gained: {0}" -f (Format-PolishSize $freeGain)) 'ok'
            }
            Write-PolishCtx $Ctx 'that data now comes from disk again the next time it is needed.' 'info'
            Write-PolishCtx $Ctx 'useful right before launching something big. Not useful repeatedly.' 'info'
        }
    }

    if ($standbyDrop -gt 0) { $Ctx.RamFreed += $standbyDrop }
    return [long]$standbyDrop
}

function Show-PolishMemory {
    $d = Get-PolishMemoryDetail
    Write-PolishLine '' 'head'
    Write-PolishLine '=== Memory ===' 'head'
    Write-PolishLine ('  total              {0,12}' -f (Format-PolishSize $d.TotalBytes)) 'info'
    Write-PolishLine ('  in use by apps     {0,12}' -f (Format-PolishSize $d.InUseBytes)) 'info'
    Write-PolishLine ('  free               {0,12}' -f (Format-PolishSize $d.FreeBytes)) 'info'
    Write-PolishLine '' 'head'
    Write-PolishLine ('  standby / cached   {0,12}   <- this is the "RAM cache"' -f (Format-PolishSize $d.StandbyBytes)) 'ok'
    Write-PolishLine ('    normal priority  {0,12}   earning its keep' -f (Format-PolishSize $d.StandbyNormal)) 'info'
    Write-PolishLine ('    low priority     {0,12}   speculative, cheapest to drop' -f (Format-PolishSize $d.StandbyReserve)) 'info'
    Write-PolishLine ('    core             {0,12}' -f (Format-PolishSize $d.StandbyCore)) 'info'
    Write-PolishLine ('  modified (pending) {0,12}   not yet written to disk' -f (Format-PolishSize $d.ModifiedBytes)) 'info'
    Write-PolishLine '' 'head'
    Write-PolishLine '  Standby is not wasted memory. It is file data kept in RAM so Windows does' 'info'
    Write-PolishLine '  not have to read it from disk again, and Windows hands it back instantly' 'info'
    Write-PolishLine '  when a program asks for memory. Purging it frees RAM now and costs disk' 'info'
    Write-PolishLine '  reads later, which is a good trade only right before a big launch.' 'info'
    Write-PolishLine '' 'head'
    Write-PolishLine '  Clear it with:  Polish.ps1 -Only cache.ramlow    (gentle, recommended)' 'info'
    Write-PolishLine '                  Polish.ps1 -Only cache.ram       (purge everything)' 'info'
}
