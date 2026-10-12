#Requires -Version 5.1
<#
.SYNOPSIS
    display-maximizer test suite.
    1. Parse gate          - the main script must tokenize with zero errors.
    2. Unit tests          - Select-BestMode fixtures (pixel priority, Hz
                             tie-break, bpp filter, interlace exclusion,
                             degenerate Hz exclusion).
    3. Live read-only smoke- run the real script -VerifyOnly -Json against this
                             machine and validate the report shape. Changes
                             nothing.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$projectRoot = Split-Path -Parent $PSScriptRoot
$main        = Join-Path $projectRoot 'display-maximizer.ps1'
$PS5         = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

$global:pass = 0
$global:fail = 0
function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) {
        $global:pass++
        Write-Output ("  PASS  " + $Name)
    } else {
        $global:fail++
        Write-Output ("  FAIL  " + $Name)
    }
}

Write-Output '=== 1. parse gate ==='
$tokens = $null
$parseErrors = $null
$null = [System.Management.Automation.PSParser]::Tokenize((Get-Content $main -Raw), [ref]$parseErrors)
Assert-True ($null -ne $parseErrors -and @($parseErrors).Count -eq 0) "main script tokenizes with 0 errors (got $(@($parseErrors).Count))"

Write-Output '=== 2. unit tests: Select-BestMode ==='
. $main   # dot-import: function definitions only, main block returns early

function New-FixtureMode { param([int]$W,[int]$H,[int]$Hz,[int]$Bpp=32,[bool]$Interlaced=$false,[int]$Index=0)
    [pscustomobject]@{ W=$W; H=$H; Hz=$Hz; Bpp=$Bpp; Interlaced=$Interlaced; Index=$Index }
}

# pixels beat refresh
$m = Select-BestMode -Modes @(
    (New-FixtureMode 3840 2160 120 32 $false 0),
    (New-FixtureMode 3840 2160 60  32 $false 1),
    (New-FixtureMode 2560 1440 240 32 $false 2),
    (New-FixtureMode 1920 1080 240 32 $false 3)
)
Assert-True ($m.W -eq 3840 -and $m.H -eq 2160 -and $m.Hz -eq 120) 'most pixels wins over higher Hz on smaller panel'

# Hz breaks pixel ties
$m = Select-BestMode -Modes @(
    (New-FixtureMode 1920 1080 60  32 $false 0),
    (New-FixtureMode 1920 1080 240 32 $false 1),
    (New-FixtureMode 1920 1080 144 32 $false 2)
)
Assert-True ($m.Hz -eq 240) 'highest Hz wins pixel ties'

# width breaks pixel+Hz ties (e.g. ultrawide equal-pixel variants)
$m = Select-BestMode -Modes @(
    (New-FixtureMode 3440 1440 100 32 $false 0),
    (New-FixtureMode 2560 1080 100 32 $false 1)
)
Assert-True ($m.W -eq 3440) 'wider mode wins equal-pixel equal-Hz ties'

# bpp filter: 32bpp preferred over 16bpp at same geometry
$m = Select-BestMode -Modes @(
    (New-FixtureMode 1920 1080 144 16 $false 0),
    (New-FixtureMode 1920 1080 144 32 $false 1)
)
Assert-True ($m.Bpp -eq 32) 'highest color depth selected'

# interlaced excluded when progressive exists
$m = Select-BestMode -Modes @(
    (New-FixtureMode 3840 2160 24  32 $true  0),
    (New-FixtureMode 3840 2160 30  32 $true  1),
    (New-FixtureMode 1920 1080 120 32 $false 2)
)
Assert-True ($m.Interlaced -eq $false -and $m.Hz -eq 120) 'interlaced max-res variant not chosen over progressive'

# 0 Hz placeholder dropped
$m = Select-BestMode -Modes @(
    (New-FixtureMode 1920 1080 0   32 $false 0),
    (New-FixtureMode 1920 1080 144 32 $false 1)
)
Assert-True ($m.Hz -eq 144) '0 Hz placeholder never selected'

# single mode passthrough
$m = Select-BestMode -Modes @((New-FixtureMode 1024 768 60 32 $false 0))
Assert-True ($null -ne $m -and $m.W -eq 1024) 'single-mode list returns that mode'

# empty list
$m = Select-BestMode -Modes @()
Assert-True ($null -eq $m) 'empty mode list returns null'
$m = Select-BestMode -Modes $null
Assert-True ($null -eq $m) 'null mode list returns null'

Write-Output '=== 3. live read-only smoke (-VerifyOnly -Json) ==='
$out = & $PS5 -NoProfile -ExecutionPolicy Bypass -File $main -VerifyOnly -Json 2>&1
$liveCode = $LASTEXITCODE
$jsonText = ($out | Out-String).Trim()
$report = $null
try { $report = $jsonText | ConvertFrom-Json } catch { $report = $null }
Assert-True ($null -ne $report)                       'live run emits parseable JSON'
Assert-True ($liveCode -eq 0 -or $liveCode -eq 2)     "live verify exit code sane (got $liveCode)"
if ($null -ne $report) {
    Assert-True ($report.tool -eq 'display-maximizer')                    'report identifies the tool'
    Assert-True (@($report.displays).Count -ge 1)                         'at least one active display discovered'
    Assert-True ($null -ne $report.displays[0].current.W)                 'current mode captured'
    Assert-True ($null -ne $report.displays[0].best.W)                    'best mode computed'
    Assert-True ($null -ne $report.overall.maximized)                     'overall verdict present'
} else {
    Write-Output "    raw output was: $jsonText"
}

Write-Output ''
Write-Output ("RESULT: {0} passed, {1} failed" -f $global:pass, $global:fail)
if ($global:fail -gt 0) { exit 1 }
exit 0
