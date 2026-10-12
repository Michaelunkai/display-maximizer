# display-maximizer

![PowerShell](https://img.shields.io/badge/Windows%20PowerShell-5.1+-blue)
![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-lightgrey)
![Tests](https://img.shields.io/badge/tests-17%2F17-brightgreen)
![License](https://img.shields.io/badge/license-MIT-green)

**One command. Every monitor at its true maximum resolution × refresh rate. Proven, not assumed.**

`display-maximizer` enumerates **every display mode the driver declares for every active
monitor** (through the same `EnumDisplaySettingsEx` source the Windows settings UI uses),
picks the mode with the **most pixels → highest refresh → widest width**, applies it
**persistently** (`ChangeDisplaySettingsEx` + `CDS_UPDATEREGISTRY`), then **proves the
result** by reading the live mode back and cross-checking it against the independent
WMI/CIM `Win32_VideoController` counters.

On its first real run on the author's PC it found a **4K panel running at 1080p@160 Hz**
(Windows had never been told to use the panel's real ceiling) and pushed it to
**3840×2160 @ 120 Hz** — the exact case this tool exists for.

## Download

- **[display-maximizer.ps1 v1.0.0](https://github.com/Michaelunkai/display-maximizer/releases/download/v1.0.0/display-maximizer.ps1)** — the tool, single file, no dependencies.
- **[display-maximizer-v1.0.0.zip](https://github.com/Michaelunkai/display-maximizer/releases/download/v1.0.0/display-maximizer-v1.0.0.zip)** — script + double-click launcher.

## Install (one line)

```powershell
irm https://github.com/Michaelunkai/display-maximizer/releases/download/v1.0.0/display-maximizer.ps1 -OutFile "$env:USERPROFILE\display-maximizer.ps1"
```

Run it:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\display-maximizer.ps1"
```

## Usage

| Command | What it does | Changes anything? |
|---|---|---|
| `display-maximizer.ps1` | **Apply** — maximize every active display, retrying up to 3× per display, then verify | Yes (mode changes only) |
| `... -VerifyOnly` | Read-only proof pass: current vs maximum per display + 4K/120 Hz policy | **No, ever** |
| `... -ListModes` | Dump every driver-enumerated mode per display (the evidence) | **No, ever** |
| `... -Json` | Machine-readable report on stdout (combine with the above) | — |
| `-Retries N` | Apply attempts per display (default 3) | — |
| `-ReportDir path` | Where reports are written (default: `.\reports` if it exists) | — |

Every apply/verify run writes a timestamped `.txt` + `.json` report pair into
`reports/` — that folder doubles as a permanent evidence trail (see
[reports/](reports/) for real runs on real hardware).

### Real output (this machine, after maximize)

```text
  \\.\DISPLAY1  [NVIDIA GeForce RTX 5080]  monitor: Generic PnP Monitor  [PRIMARY]
    current: 3840x2160 @ 160 Hz (32 bpp)   of 719 driver-enumerated modes
    maximum: 3840x2160 @ 160 Hz
    maximized: YES    >=4K: YES    >=120Hz: YES    CIM-cross-check: OK

  \\.\DISPLAY5  [AMD Radeon(TM) Graphics]  monitor: Generic PnP Monitor
    current: 3840x2160 @ 120 Hz (32 bpp)   of 570 driver-enumerated modes
    maximum: 3840x2160 @ 120 Hz
    maximized: YES    >=4K: YES    >=120Hz: YES    CIM-cross-check: OK

OVERALL: MAXIMIZED
policy all->120Hz+: PASS      policy all->4K: PASS
```

## What "maximized" means here — the honesty contract

A display can never be forced past its **panel + cable + driver** limits. The maximum
is exactly what the driver enumerates — nothing more, nothing invented. Therefore the
report separates two verdicts:

1. **MAXIMIZED** (the tool's contract): every active display runs at the highest
   pixel count its driver declares, and among those, the highest refresh rate.
   Exit code 0 ⇔ this is true.
2. **Policy checks** (your goals, reported truthfully): `>=4K` and `>=120Hz` per
   display. When a panel's own EDID ceiling is below 4K, the report names that
   ceiling (e.g. `NO (panel ceiling is 1920x1080)`) instead of pretending.

Selection rule: **most pixels first, then highest Hz, then widest width**, at the
highest color depth offered, ignoring interlaced and 0 Hz placeholder variants.
That matches the intent "maximum possible resolution, and among equals maximum Hz".

## How the proof works

- **Read-back**: after every apply, the live mode is re-queried through
  `ENUM_CURRENT_SETTINGS` and must equal the target exactly (W × H × Hz).
- **Independent cross-check**: the same current mode must appear in the
  `Win32_VideoController` CIM counters (`CurrentHorizontalResolution` etc.) — a
  second, unrelated Windows subsystem reporting the same mode.
- **Idempotency**: running apply twice changes nothing the second time; an
  already-maximized display is never touched.
- **Multiple fresh processes**: each run re-enumerates from scratch, so a
  "MAXIMIZED" verdict from `-VerifyOnly` (exit 0) is a fresh proof every time.

## Example — a confidence loop

```powershell
$f = "$env:USERPROFILE\display-maximizer.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File $f          # maximize
1..3 | ForEach-Object {
    powershell -NoProfile -ExecutionPolicy Bypass -File $f -VerifyOnly -Json | ConvertFrom-Json |
        Select-Object -ExpandProperty overall
}
```

Three `{"maximized": true, "allAbove120": true, "all4k": true}` lines in a row = every
connected, active monitor is at its maximum and meets the 4K / 120 Hz policy.

## Multi-monitor & invisible devices

`EnumDisplayDevices` may list more adapter endpoints (e.g. `\\.\DISPLAY2…`) than you
have screens — those are GPU heads with no active desktop attachment. The tool reports
them under `Non-desktop devices seen` and deliberately leaves them untouched: attaching
inactive outputs automatically could mirror your desktop and destroy your layout.
Every display **actively driven** right now is maximized; nothing silently escapes.

## Build from source

Nothing to build — it is one PowerShell script. Run the test suite:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Tests\run-tests.ps1
```

17 checks: parse gate, 9 unit tests on the mode-selection core (pixel priority,
Hz tie-break, width tie-break, color-depth filter, interlace exclusion, 0 Hz
exclusion, degenerate lists), and a live read-only smoke test.

## Troubleshooting

| Symptom | Meaning / fix |
|---|---|
| `maximized: NO` persists after apply | Another app (NVIDIA/AMD overlay, ICC loader) is resetting modes; re-run apply after closing it. |
| Black screen after a mode change | Press `Win+Ctrl+Shift+B` (restarts the graphics driver). Modes only ever come from the driver's own EDID-filtered list. |
| 4K/120 Hz listed as `NO (panel ceiling ...)` | That is the monitor's own hardware limit per its EDID — the tool cannot and will not invent modes. Custom-resolution tools (CRU) can add modes; re-run apply afterwards and the tool picks them up. |
| `NOT UPDATED` / `BADMODE` in `-Verbose` | The driver rejected a transition mid-flight; the retry loop (default 3) handles it. |

## Requirements

- Windows 10 / 11, Windows PowerShell **5.1** or later (built into Windows — no installs).
- No admin rights needed for standard mode changes on displays you own.

## License

[MIT](LICENSE) © 2026 Michaelunkai
