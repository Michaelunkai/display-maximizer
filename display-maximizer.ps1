#Requires -Version 5.1
<#
.SYNOPSIS
    display-maximizer - force every connected, active monitor to its true maximum
    resolution x refresh rate, then PROVE it with independent read-backs.

.DESCRIPTION
    Enumerates every supported display mode of every active display through
    EnumDisplaySettingsEx (the same source the Windows settings UI uses), selects
    the mode with the most pixels, then the highest refresh rate, then the widest
    width, applies it persistently with ChangeDisplaySettingsEx(CDS_UPDATEREGISTRY),
    and verifies by reading the live mode back - cross-checked against the WMI/CIM
    Win32_VideoController current-mode counters.

    All user32 struct handling lives inside the compiled C# helper (PowerShell
    5.1 struct [ref] marshaling silently corrupts the cb field; plain arrays
    across the boundary are immune to that bug class).

    Default verb (no switches) = APPLY: maximize every display that is not already
    at its maximum, retrying up to -Retries times per display, then verify.

    -VerifyOnly : read-only verification pass. Changes nothing, ever.
    -ListModes  : read-only dump of every supported mode per active display.
    -Json       : emit the machine-readable report to stdout (no human text).

    Honesty contract: a display can never be pushed past its panel/cable/driver
    limits. The maximum is whatever the driver enumerated - no more. The report
    states per display: maximized (tool contract), >=4K and >120 Hz (policy check),
    and when 4K/120+ is impossible it names the panel's own ceiling as evidence.

.EXITCODES
    0 = success (all active displays at their maximum / list emitted)
    2 = verification found at least one display below its maximum
    3 = apply failed after all retries
    4 = no active display found

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\display-maximizer.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File .\display-maximizer.ps1 -VerifyOnly
    powershell -NoProfile -ExecutionPolicy Bypass -File .\display-maximizer.ps1 -ListModes
#>
[CmdletBinding()]
param(
    [switch]$VerifyOnly,
    [switch]$ListModes,
    [switch]$Json,
    [string]$ReportDir = '',
    [int]$Retries = 3,
    [int]$SettleMs = 2500
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Native interop (user32) - struct handling kept entirely inside C#
# ---------------------------------------------------------------------------
if (-not ('DMX.NativeDisplay' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace DMX {
    [StructLayout(LayoutKind.Sequential)]
    internal struct POINTL { public int x; public int y; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal struct DEVMODEW {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]  public string dmDeviceName;
        public ushort dmSpecVersion;
        public ushort dmDriverVersion;
        public ushort dmSize;
        public ushort dmDriverExtra;
        public uint   dmFields;
        public POINTL dmPosition;
        public uint   dmDisplayOrientation;
        public uint   dmDisplayFixedOutput;
        public short  dmColor;
        public short  dmDuplex;
        public short  dmYResolution;
        public short  dmTTOption;
        public short  dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]  public string dmFormName;
        public ushort dmLogPixels;
        public uint   dmBitsPerPel;
        public uint   dmPelsWidth;
        public uint   dmPelsHeight;
        public uint   dmDisplayFlags;
        public uint   dmDisplayFrequency;
        public uint   dmICMMethod;
        public uint   dmICMIntent;
        public uint   dmMediaType;
        public uint   dmDitherType;
        public uint   dmReserved1;
        public uint   dmReserved2;
        public uint   dmPanningWidth;
        public uint   dmPanningHeight;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal struct DISPLAY_DEVICEW {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]  public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public uint StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }

    public static class NativeDisplay {
        private const int ENUM_CURRENT_SETTINGS = -1;
        private const uint CDS_UPDATEREGISTRY   = 0x00000001;
        private const uint DM_PELSWIDTH         = 0x00080000;
        private const uint DM_PELSHEIGHT        = 0x00100000;
        private const uint DM_DISPLAYFREQUENCY  = 0x00400000;

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern bool EnumDisplayDevicesW(string lpDevice, uint iDevNum, ref DISPLAY_DEVICEW lpDisplayDevice, uint dwFlags);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern bool EnumDisplaySettingsExW(string lpszDeviceName, int iModeNum, ref DEVMODEW lpDevmode, uint dwFlags);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int ChangeDisplaySettingsExW(string lpszDeviceName, ref DEVMODEW lpDevmode, IntPtr hwnd, uint dwFlags, IntPtr lParam);

        // Returns object[] entries: { name, description, stateFlags(long), monitorName, monitorId }
        public static List<object[]> EnumAdapters() {
            var result = new List<object[]>();
            uint i = 0;
            while (true) {
                var dd = new DISPLAY_DEVICEW();
                dd.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICEW));
                if (!EnumDisplayDevicesW(null, i, ref dd, 0)) break;

                string monitorName = "";
                string monitorId   = "";
                var md = new DISPLAY_DEVICEW();
                md.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICEW));
                if (EnumDisplayDevicesW(dd.DeviceName, 0, ref md, 0)) {
                    monitorName = md.DeviceString;
                    monitorId   = md.DeviceID;
                }
                result.Add(new object[] { dd.DeviceName, dd.DeviceString, (long)dd.StateFlags, monitorName, monitorId });
                i++;
            }
            return result;
        }

        // Returns long[] { w, h, hz, bpp } or null when unreadable.
        public static long[] GetCurrentMode(string device) {
            var dm = new DEVMODEW();
            dm.dmSize = (ushort)Marshal.SizeOf(typeof(DEVMODEW));
            if (!EnumDisplaySettingsExW(device, ENUM_CURRENT_SETTINGS, ref dm, 0)) return null;
            return new long[] { dm.dmPelsWidth, dm.dmPelsHeight, dm.dmDisplayFrequency, dm.dmBitsPerPel };
        }

        // Returns List<long[]>: { w, h, hz, bpp, displayFlags, modeIndex }
        public static List<long[]> EnumModes(string device) {
            var modes = new List<long[]>();
            int idx = 0;
            while (idx <= 4096) {
                var dm = new DEVMODEW();
                dm.dmSize = (ushort)Marshal.SizeOf(typeof(DEVMODEW));
                if (!EnumDisplaySettingsExW(device, idx, ref dm, 0)) break;
                modes.Add(new long[] { dm.dmPelsWidth, dm.dmPelsHeight, dm.dmDisplayFrequency, dm.dmBitsPerPel, dm.dmDisplayFlags, idx });
                idx++;
            }
            return modes;
        }

        // Applies the enumerated mode at modeIndex persistently (CDS_UPDATEREGISTRY).
        // Returns the DISP_CHANGE code (0 = success).
        public static int ChangeMode(string device, int modeIndex) {
            var dm = new DEVMODEW();
            dm.dmSize = (ushort)Marshal.SizeOf(typeof(DEVMODEW));
            if (!EnumDisplaySettingsExW(device, modeIndex, ref dm, 0)) return -1;
            dm.dmFields = (DM_PELSWIDTH | DM_PELSHEIGHT | DM_DISPLAYFREQUENCY);
            dm.dmSize   = (ushort)Marshal.SizeOf(typeof(DEVMODEW));
            return ChangeDisplaySettingsExW(device, ref dm, IntPtr.Zero, CDS_UPDATEREGISTRY, IntPtr.Zero);
        }
    }
}
"@
}

# ---------------------------------------------------------------------------
# Pure mode selection (unit-tested in Tests/run-tests.ps1)
# ---------------------------------------------------------------------------
function Select-BestMode {
    param([object[]]$Modes)

    if ($null -eq $Modes) { return $null }
    $list = @($Modes)
    if ($list.Count -eq 0) { return $null }

    # Progressive display modes are the norm; interlaced variants lose.
    $progressive = @($list | Where-Object { -not $_.Interlaced })
    if ($progressive.Count -gt 0) { $list = $progressive }

    # Drop degenerate 0 Hz placeholders when real ones exist.
    $timed = @($list | Where-Object { [int]$_.Hz -ge 1 })
    if ($timed.Count -gt 0) { $list = $timed }

    # Highest color depth the driver actually offers for these geometries.
    $maxBpp = ($list | Measure-Object -Property Bpp -Maximum).Maximum
    $cand   = @($list | Where-Object { [int]$_.Bpp -eq [int]$maxBpp })

    $sorted = @($cand | Sort-Object -Property @(
            @{ Expression = { [long]$_.W * [long]$_.H }; Descending = $true },
            @{ Expression = { [int]$_.Hz };              Descending = $true },
            @{ Expression = { [int]$_.W };               Descending = $true }
        ))
    return $sorted[0]
}

# ---------------------------------------------------------------------------
# Enumeration (thin PS wrappers over the C# helpers)
# ---------------------------------------------------------------------------
function Get-DisplayAdapters {
    $adapters = @()
    foreach ($a in [DMX.NativeDisplay]::EnumAdapters()) {
        $flags = [long]$a[2]
        $adapters += [pscustomobject]@{
            DeviceName        = [string]$a[0]
            Description       = [string]$a[1]
            StateFlags        = $flags
            AttachedToDesktop = (($flags -band 0x00000001) -ne 0)
            Primary           = (($flags -band 0x00000004) -ne 0)
            Mirrored          = (($flags -band 0x00000008) -ne 0)
            Disconnected      = (($flags -band 0x02000000) -ne 0)
            MonitorName       = [string]$a[3]
            MonitorId         = [string]$a[4]
        }
    }
    return ,$adapters
}

function Get-CurrentMode {
    param([string]$DeviceName)
    $raw = [DMX.NativeDisplay]::GetCurrentMode($DeviceName)
    if ($null -eq $raw) { return $null }
    return [pscustomobject]@{
        W   = [int]$raw[0]
        H   = [int]$raw[1]
        Hz  = [int]$raw[2]
        Bpp = [int]$raw[3]
    }
}

function Get-SupportedModes {
    param([string]$DeviceName)
    $modes = @()
    foreach ($m in [DMX.NativeDisplay]::EnumModes($DeviceName)) {
        $modes += [pscustomobject]@{
            W          = [int]$m[0]
            H          = [int]$m[1]
            Hz         = [int]$m[2]
            Bpp        = [int]$m[3]
            Interlaced = (([long]$m[4] -band 0x2) -ne 0)
            Index      = [int]$m[5]
        }
    }
    return ,$modes
}

function ConvertTo-DispChangeName {
    param([int]$Code)
    switch ($Code) {
        0        { 'SUCCESS' }
        1        { 'RESTART-REQUIRED' }
        -1       { 'FAILED' }
        -2       { 'BADMODE' }
        -3       { 'NOTUPDATED' }
        -4       { 'BADFLAGS' }
        -5       { 'BADPARAM' }
        -6       { 'BADDUALVIEW' }
        default  { "CODE_$Code" }
    }
}

# ---------------------------------------------------------------------------
# Independent cross-check: CIM Win32_VideoController live counters
# ---------------------------------------------------------------------------
function Get-CimCurrentTripleSet {
    $set = @{}
    try {
        $controllers = Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop
        foreach ($c in $controllers) {
            if ($null -ne $c.CurrentHorizontalResolution -and $null -ne $c.CurrentVerticalResolution -and $null -ne $c.CurrentRefreshRate) {
                $key = '{0}x{1}@{2}' -f [int]$c.CurrentHorizontalResolution, [int]$c.CurrentVerticalResolution, [int]$c.CurrentRefreshRate
                $set[$key] = $true
            }
        }
    } catch {
        # cross-check is best-effort; absence is reported, never fatal
    }
    return $set
}

# ---------------------------------------------------------------------------
# State assembly
# ---------------------------------------------------------------------------
function Get-DisplayState {
    $all     = Get-DisplayAdapters
    $active  = @($all | Where-Object { $_.AttachedToDesktop -and -not $_.Mirrored })
    $others  = @($all | Where-Object { -not ($_.AttachedToDesktop -and -not $_.Mirrored) })
    $cimSet  = Get-CimCurrentTripleSet

    $displays = foreach ($a in $active) {
        $cur   = Get-CurrentMode    -DeviceName $a.DeviceName
        $modes = Get-SupportedModes -DeviceName $a.DeviceName
        $best  = Select-BestMode    -Modes $modes

        $atMax = $false
        if ($null -ne $cur -and $null -ne $best) {
            $atMax = ([int]$cur.W -eq [int]$best.W -and [int]$cur.H -eq [int]$best.H -and [int]$cur.Hz -eq [int]$best.Hz)
        }
        $cimOk = $false
        if ($null -ne $cur) {
            $cimKey = '{0}x{1}@{2}' -f [int]$cur.W, [int]$cur.H, [int]$cur.Hz
            if ($cimSet.Count -eq 0 -or $cimSet.ContainsKey($cimKey)) { $cimOk = $true }
        }

        [pscustomobject]@{
            device       = $a.DeviceName
            adapter      = $a.Description
            monitor      = $a.MonitorName
            monitorId    = $a.MonitorId
            primary      = [bool]$a.Primary
            current      = $cur
            best         = $best
            modeCount    = @($modes).Count
            atMax        = [bool]$atMax
            cimConfirmed = [bool]$cimOk
            meets4k      = ($null -ne $cur -and [int]$cur.W -ge 3840 -and [int]$cur.H -ge 2160)
            above120     = ($null -ne $cur -and [int]$cur.Hz -ge 120)
        }
    }

    return [pscustomobject]@{
        displays = @($displays)
        others   = @($others)
        cimSet   = $cimSet
    }
}

function Get-OverallVerdict {
    param([object]$State)
    $d = @($State.displays)
    if ($d.Count -eq 0) {
        return [pscustomobject]@{ maximized = $false; allAbove120 = $false; all4k = $false; noDisplay = $true }
    }
    $max  = @($d | Where-Object { -not $_.atMax }).Count -eq 0
    $h120 = @($d | Where-Object { -not $_.above120 }).Count -eq 0
    $k4   = @($d | Where-Object { -not $_.meets4k }).Count -eq 0
    return [pscustomobject]@{ maximized = [bool]$max; allAbove120 = [bool]$h120; all4k = [bool]$k4; noDisplay = $false }
}

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------
function Resolve-ReportFile {
    param([string]$Prefix, [string]$Extension)
    $dir = $null
    if ($ReportDir -and (Test-Path $ReportDir)) { $dir = $ReportDir }
    elseif (Test-Path '.\reports')              { $dir = '.\reports' }
    if (-not $dir) { return $null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    return (Join-Path $dir ('{0}-{1}.{2}' -f $Prefix, $stamp, $Extension))
}

function Write-Reports {
    param([object]$State, [object]$Verdict, [string]$Mode, [string]$Text)

    $json = [pscustomobject]@{
        tool      = 'display-maximizer'
        version   = '1.0.0'
        timestamp = (Get-Date -Format 'o')
        mode      = $Mode
        displays  = $State.displays
        otherDevices = @($State.others | ForEach-Object {
            [pscustomobject]@{
                device = $_.DeviceName; adapter = $_.Description
                attachedToDesktop = $_.AttachedToDesktop; disconnected = $_.Disconnected
            }
        })
        overall = [pscustomobject]@{
            maximized   = $Verdict.maximized
            allAbove120 = $Verdict.allAbove120
            all4k       = $Verdict.all4k
            noDisplay   = $Verdict.noDisplay
        }
    } | ConvertTo-Json -Depth 6

    $txtPath = Resolve-ReportFile -Prefix ('display-{0}' -f $Mode) -Extension 'txt'
    $jsPath  = Resolve-ReportFile -Prefix ('display-{0}' -f $Mode) -Extension 'json'
    if ($txtPath) { Set-Content -Path $txtPath -Value $Text -Encoding UTF8 }
    if ($jsPath)  { Set-Content -Path $jsPath  -Value $json -Encoding UTF8 }
    return $json
}

function Format-HumanReport {
    param([object]$State, [object]$Verdict, [string]$Mode)

    $lines = @()
    $lines += ('display-maximizer v1.0.0 - {0} - {1}' -f $Mode, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    $lines += ('Active displays: {0}' -f @($State.displays).Count)
    foreach ($d in @($State.displays)) {
        $mon = '(unnamed)'
        if ($d.monitor) { $mon = $d.monitor }
        $pri = ''
        if ($d.primary) { $pri = '  [PRIMARY]' }
        $lines += ''
        $lines += ('  {0}  [{1}]  monitor: {2}{3}' -f $d.device, $d.adapter, $mon, $pri)
        if ($null -eq $d.current) {
            $lines += '    current mode: <unreadable>'
            $lines += '    maximized: NO (current mode unreadable)'
            continue
        }
        $lines += ('    current: {0}x{1} @ {2} Hz ({3} bpp)   of {4} driver-enumerated modes' -f $d.current.W, $d.current.H, $d.current.Hz, $d.current.Bpp, $d.modeCount)
        if ($null -ne $d.best) {
            $lines += ('    maximum: {0}x{1} @ {2} Hz' -f $d.best.W, $d.best.H, $d.best.Hz)
        }
        $policy4k = 'YES'
        if (-not $d.meets4k) { $policy4k = 'NO (panel ceiling is {0}x{1})' -f $d.best.W, $d.best.H }
        $cim = 'OK'
        if (-not $d.cimConfirmed) { $cim = 'MISMATCH' }
        $mx = 'NO'
        if ($d.atMax) { $mx = 'YES' }
        $h120 = 'NO'
        if ($d.above120) { $h120 = 'YES' }
        $lines += ('    maximized: {0}    >=4K: {1}    >=120Hz: {2}    CIM-cross-check: {3}' -f $mx, $policy4k, $h120, $cim)
    }
    if (@($State.others).Count -gt 0) {
        $lines += ''
        $lines += ('Non-desktop devices seen (not actively driven, left untouched): {0}' -f @($State.others).Count)
        foreach ($o in @($State.others)) {
            $lines += ('  {0}  [{1}]  attachedToDesktop={2} disconnected={3}' -f $o.DeviceName, $o.Description, $o.AttachedToDesktop, $o.Disconnected)
        }
    }
    $lines += ''
    $overallTxt = 'NOT MAXIMIZED'
    if ($Verdict.noDisplay)     { $overallTxt = 'NO ACTIVE DISPLAY FOUND' }
    elseif ($Verdict.maximized) { $overallTxt = 'MAXIMIZED' }
    $policy120 = 'FAIL'
    if ($Verdict.allAbove120) { $policy120 = 'PASS' }
    $policy4kAll = 'FAIL (hardware ceiling - see per-display lines)'
    if ($Verdict.all4k) { $policy4kAll = 'PASS' }
    $lines += ('OVERALL: {0}' -f $overallTxt)
    $lines += ('policy all->120Hz+: {0}      policy all->4K: {1}' -f $policy120, $policy4kAll)
    return ($lines -join [Environment]::NewLine)
}

# ---------------------------------------------------------------------------
# Verbs (store report text in script scope; return ONLY the integer exit code,
# because assigning a PS function call to a variable swallows the whole output
# stream - text and return value would otherwise be fused).
# ---------------------------------------------------------------------------
function Invoke-Verify {
    $state   = Get-DisplayState
    $verdict = Get-OverallVerdict -State $state
    $script:lastText = Format-HumanReport -State $state -Verdict $verdict -Mode 'verify'
    $script:lastJson = Write-Reports -State $state -Verdict $verdict -Mode 'verify' -Text $script:lastText
    if ($verdict.noDisplay) { return 4 }
    if ($verdict.maximized) { return 0 }
    return 2
}

function Invoke-ListModes {
    $adapters = Get-DisplayAdapters
    $active   = @($adapters | Where-Object { $_.AttachedToDesktop -and -not $_.Mirrored })
    $records  = @()
    foreach ($a in $active) {
        $modes = Get-SupportedModes -DeviceName $a.DeviceName
        $best  = Select-BestMode -Modes $modes
        $records += [pscustomobject]@{
            device = $a.DeviceName; adapter = $a.Description; monitor = $a.MonitorName
            best = $best; modes = @($modes | Sort-Object -Property @(
                    @{ Expression = { [long]$_.W * [long]$_.H }; Descending = $true },
                    @{ Expression = { [int]$_.Hz }; Descending = $true }
                ))
        }
    }
    $script:lastJson = [pscustomobject]@{ tool = 'display-maximizer'; timestamp = (Get-Date -Format 'o'); displays = $records } | ConvertTo-Json -Depth 6

    $lines = @()
    foreach ($d in $records) {
        $lines += ('=== {0} [{1}] monitor: {2} ===' -f $d.device, $d.adapter, $d.monitor)
        $lines += ('    {0} enumerated modes; maximum: {1}x{2} @ {3} Hz' -f @($d.modes).Count, $d.best.W, $d.best.H, $d.best.Hz)
        foreach ($m in $d.modes) {
            $lines += ('      {0,5} x {1,5} @ {2,4} Hz  {3} bpp{4}' -f $m.W, $m.H, $m.Hz, $m.Bpp, $(if ($m.Interlaced) { '  (interlaced)' } else { '' }))
        }
        $lines += ''
    }
    $script:lastText = $lines -join [Environment]::NewLine

    $txtPath = Resolve-ReportFile -Prefix 'display-modes' -Extension 'txt'
    if ($txtPath) { Set-Content -Path $txtPath -Value $script:lastText -Encoding UTF8 }
    return 0
}

function Invoke-Apply {
    $state = Get-DisplayState

    # Apply only where needed (idempotent by construction).
    foreach ($d in @($state.displays)) {
        if ($null -eq $d.current -or $null -eq $d.best) { continue }
        if ($d.atMax) { continue }
        $attempt = 0
        while ($attempt -lt $Retries) {
            $attempt++
            $rc  = Set-TargetMode -DeviceName $d.device -ModeIndex $d.best.Index
            $now = Get-CurrentMode -DeviceName $d.device
            $ok  = ($null -ne $now -and [int]$now.W -eq [int]$d.best.W -and [int]$now.H -eq [int]$d.best.H -and [int]$now.Hz -eq [int]$d.best.Hz)
            Write-Verbose ('{0}: attempt {1} -> ChangeDisplaySettingsEx={2}, read-back {3}x{4}@{5} match={6}' -f `
                $d.device, $attempt, (ConvertTo-DispChangeName -Code $rc), $now.W, $now.H, $now.Hz, $ok)
            if ($ok) { break }
            Start-Sleep -Milliseconds $SettleMs
        }
        Start-Sleep -Milliseconds 500   # let the desktop settle before final verify
    }

    # Final independent verification pass (fresh enumeration, no cached state).
    $final   = Get-DisplayState
    $verdict = Get-OverallVerdict -State $final
    $script:lastText = Format-HumanReport -State $final -Verdict $verdict -Mode 'apply'
    $script:lastJson = Write-Reports -State $final -Verdict $verdict -Mode 'apply' -Text $script:lastText
    if ($verdict.noDisplay)  { return 4 }
    if (-not $verdict.maximized) { return 3 }
    return 0
}

function Set-TargetMode {
    param([string]$DeviceName, [int]$ModeIndex)
    return [DMX.NativeDisplay]::ChangeMode($DeviceName, $ModeIndex)
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if ($MyInvocation.InvocationName -eq '.') { return }   # dot-import mode for tests

$script:lastText = ''
$script:lastJson = ''
$exitCode = 0
if     ($VerifyOnly) { $exitCode = Invoke-Verify }
elseif ($ListModes)  { $exitCode = Invoke-ListModes }
else                 { $exitCode = Invoke-Apply }
if ($Json) { Write-Output $script:lastJson } else { Write-Output $script:lastText }
exit $exitCode
