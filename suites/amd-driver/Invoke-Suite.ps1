<#
.SYNOPSIS
    AMD legacy driver regression tests (no player, no rig).

.DESCRIPTION
    Runs the amd-driver probe (legacy9.exe) against the AMD TeraScale user-mode
    driver (atiumd64.dll + atiumd6a.dll) and checks that known crash signatures
    are reproducible.  No player process and no test rig are needed.

    Currently registered:

      710465-crash  drdump ProblemID 710465 -- EVR crash in atiumd6a.dll at
                    RVA 0x3758A, reading [obj+0x68] where obj is a 152-byte
                    object with vtable at RVA 0x2CEB90.  The destructor reads
                    the high half of a 64-bit pointer stored at obj+0x64 instead
                    of obj+0x60 or obj+0x68.  Reproduced by:
                      1. Creating a D3D9 device (fires mmobj.init with the
                         crashing vtable variant).
                      2. Calling pfnCreateResource to reach the rendering code
                         path that sets the mmobj live.
                      3. Injecting a misaligned pointer at obj+0x64 to simulate
                         the field corruption, then tearing down the device.
                    Pass criterion: log contains both the right vtable and the
                    access violation at atiumd6a+0x3758A.

.PARAMETER Probe
    Emit a readiness object and return; do not run anything.
#>
[CmdletBinding()]
param(
    [switch] $Probe,
    [string] $VMName    = '',
    [string] $OutDir    = (Join-Path $PSScriptRoot 'results'),
    [string] $PlayerBinary
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$suiteName  = 'amd-driver'
$description = 'AMD TeraScale driver regression tests: known crash signatures, no player and no rig'
$root       = Resolve-Path (Join-Path $PSScriptRoot '..\..\amd-driver')
$exe        = Join-Path $root 'build\legacy9.exe'
$finder     = Join-Path $root 'tools\Find-LegacyDriver.ps1'
$runner     = Join-Path $root 'tools\legacy9.ps1'

if ($Probe) {
    $ready = $true; $reason = ''
    if (-not (Test-Path $exe)) {
        $ready = $false; $reason = "legacy9.exe not built -- run amd-driver\build.ps1"
    } elseif (-not (& $finder -ErrorAction SilentlyContinue)) {
        $ready = $false; $reason = "no AMD legacy driver found -- put atiumd64.dll in amd-driver\drivers\ or set MPC_TEST_AMDUMD"
    }
    return [pscustomobject]@{
        Suite       = $suiteName
        Description = $description
        Ready       = $ready
        Reason      = $reason
        NeedsRig    = $false
    }
}

New-Item -ItemType Directory -Force $OutDir | Out-Null

$passed  = 0
$failed  = 0
$skipped = 0
$notes   = [System.Collections.Generic.List[string]]::new()
function Note { param([string]$Colour, [string]$Text) $notes.Add($Text); Write-Host "  $Text" -ForegroundColor $Colour }

# --- test 710465-crash ---
# Run the device probe with BP and clear-write instrumentation.  Expected
# outcome: the crash function (atiumd6a:0x37510, vtable+0x40 on the crashing
# object) fires after the bad pointer injection, the driver dereferences it,
# and the process exits 0xC0000005.
$logFile = Join-Path $OutDir '710465-crash.log'
& $runner -Extra @('--device', '--bp', '--bp-clear') -Rounds 1 -Log $logFile | Out-Null
$exitCode = $LASTEXITCODE
$log = if (Test-Path $logFile) { Get-Content $logFile -Raw } else { '' }

$hasVtable = $log -match 'vtable=atiumd6a\.dll\+0x2ceb90'
$hasCrash  = $log -match 'exception c0000005 at atiumd6a\.dll\+0x3758a'

if ($hasVtable -and $hasCrash) {
    $passed++
    Note Green '710465-crash: PASS -- crashing vtable created and AV at atiumd6a+0x3758A confirmed'
} elseif ($hasVtable -and -not $hasCrash) {
    $failed++
    Note Red   '710465-crash: FAIL -- crashing vtable created but no AV at atiumd6a+0x3758A'
} elseif (-not $hasVtable) {
    $failed++
    Note Red   '710465-crash: FAIL -- crashing vtable (atiumd6a+0x2CEB90) was not created'
} else {
    $failed++
    Note Red   "710465-crash: FAIL -- exit $exitCode, no matching log entries"
}

[pscustomobject]@{ Suite = $suiteName; Passed = $passed; Failed = $failed; Skipped = $skipped; Notes = $notes }
