<#
.SYNOPSIS
    The gpu-heap suite: what a graphics user-mode driver does to the heap it
    shares with the player.

.DESCRIPTION
    A user-mode display driver is loaded into the application's process and,
    on the evidence below, allocates from the application's own heap. So its
    blocks and the player's land in the same size classes, and a stray write
    on either side is a write into the other's object. This suite measures
    that boundary instead of reasoning about it.

    It drives amd-driver-emulator, which plays the Direct3D runtime's side of
    the driver interface: it hands the driver its callback table, answers the
    adapter queries, and hooks the driver's own heap imports so every
    allocation is attributed, counted by size, and optionally padded with
    guard zones. The same probe builds as a DLL that is injected into a
    running player, where the heap under the driver is the player's heap with
    the player's own themed-menu vectors in it.

    Two cases need no driver at all and run anywhere the probe builds: the
    damage detector has to prove it fires, and the heap stride of the class
    under study is measured rather than assumed. Two more host the legacy D3D9
    driver and report Skipped, saying so, when its binaries are not present.

    Where the probe is: $env:MPC_TEST_AMDPROBE, else AmdProbeRoot in
    testbed.config.psd1, else the amd-driver submodule of this repository,
    else C:\dev\amd-driver-emulator if that exists.

    Host only, no rig. The driver cases start a player on the interactive
    desktop and close it again; nothing is installed, and no kernel call is
    forwarded.

.PARAMETER ExpectedStride
    The distance the 152-byte class is expected to put between consecutive
    blocks, in bytes. Default 160 (0xA0): a 152-byte request plus an 8-byte
    x64 LFH entry header, already 16-aligned. This is a property of the
    running Windows build, so a mismatch is reported as a failure to be looked
    at rather than quietly accepted -- the figure that neighbour analysis of a
    damaged block depends on must not be taken on trust.

    The suite asserts on its own live measurement. The field dumps constrain
    the figure rather than measure it (the stride must divide the gap between
    two capacity-19 buffers in one region), and the README records those
    constraints as what they are.

.EXAMPLE
    .\Invoke-MpcTests.ps1 -Suite gpu-heap
    & .\suites\gpu-heap\Invoke-Suite.ps1 -Case damage-detector,heap-stride
#>
[CmdletBinding()]
param(
    [switch]   $Probe,
    [string]   $VMName = '',
    [string]   $OutDir = (Join-Path $PSScriptRoot 'results'),
    [Alias('Exe')]
    [string]   $PlayerBinary,
    [string[]] $Case,
    [int]      $ExpectedStride = 160,
    [int]      $Rounds = 12,
    # What the device phase needs invented about hardware nobody here has: the record fields the driver
    # validates, the flag that selects the WDDM 2 memory model, and a GPU address base it will accept. The
    # probe's README explains each one. Update these as more of the record is worked out.
    [string]   $DeviceProbeArgs = '--device --gpu-va-base 0x10000 --qai-set 0=0x260,0xc=0,0x3c=8,0x30=0x5a,0x34=0x3c,0x1f4=0x80'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$description = 'What a graphics user-mode driver does to the heap it shares with the player: the damage detector, the measured size-class stride, and the legacy D3D9 driver hosted inside the player; host only, no rig'
$testsRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$repoRoot  = Split-Path $testsRoot -Parent

$allCases = 'damage-detector', 'heap-stride', 'legacy-umd-shared-heap', 'legacy-umd-guard-zones', 'legacy-umd-device'

# --- where the probe is ------------------------------------------------------

function Find-ProbeRoot {
    if ($env:MPC_TEST_AMDPROBE) { return $env:MPC_TEST_AMDPROBE }
    $dir = $testsRoot
    while ($dir) {
        $cand = Join-Path $dir 'testbed.config.psd1'
        if (Test-Path $cand) {
            $cfg = Import-PowerShellDataFile $cand
            if ($cfg.ContainsKey('AmdProbeRoot') -and $cfg.AmdProbeRoot) { return $cfg.AmdProbeRoot }
            break
        }
        $dir = Split-Path $dir -Parent
    }
    $sub = Join-Path $testsRoot 'amd-driver'
    if (Test-Path (Join-Path $sub 'src\legacy9.cpp')) { return $sub }
    if (Test-Path 'C:\dev\amd-driver-emulator\src\legacy9.cpp') { return 'C:\dev\amd-driver-emulator' }
    $null
}

$probeRoot = Find-ProbeRoot
$probeExe  = if ($probeRoot) { Join-Path $probeRoot 'build\legacy9.exe' } else { $null }
$hookDll   = if ($probeRoot) { Join-Path $probeRoot 'build\legacy9hook.dll' } else { $null }
$injectPs  = if ($probeRoot) { Join-Path $probeRoot 'tools\inject.ps1' } else { $null }
$findDrv   = if ($probeRoot) { Join-Path $probeRoot 'tools\Find-LegacyDriver.ps1' } else { $null }
$legacyDll = if ($findDrv -and (Test-Path $findDrv)) { & $findDrv } else { $null }

function Test-Toolchain {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) { return $false }
    [bool](& $vswhere -version '[17.0,18.0)' -products * -latest -property installationPath)
}

if ($Probe) {
    $ready = $true; $reason = ''
    if (-not $probeRoot) {
        $ready = $false
        $reason = 'amd-driver-emulator not found (fetch the amd-driver submodule, or set MPC_TEST_AMDPROBE or AmdProbeRoot in testbed.config.psd1)'
    } elseif (-not (Test-Path $probeExe) -and -not (Test-Toolchain)) {
        $ready = $false
        $reason = "the probe is not built ($probeExe) and Visual Studio 2022 with the C++ toolset was not found to build it"
    }
    return [pscustomobject]@{ Suite = 'gpu-heap'; Description = $description; Ready = $ready; Reason = $reason; NeedsRig = $false }
}

if (-not $probeRoot) { throw 'amd-driver-emulator not found; see the suite README' }
if ($Case) {
    $unknown = $Case | Where-Object { $_ -notin $allCases }
    if ($unknown) { throw "Unknown case(s): $($unknown -join ', '). Available: $($allCases -join ', ')" }
} else {
    $Case = $allCases
}

New-Item -ItemType Directory -Force $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path
$passed = 0; $failed = 0; $skipped = 0
$notes = [System.Collections.Generic.List[string]]::new()
function Note { param([string] $Colour, [string] $Text) $notes.Add($Text); Write-Host "  $Text" -ForegroundColor $Colour }
function Pass { param([string] $Case, [string] $Text) $script:passed++; Note Green  "PASS $Case -- $Text" }
function Fail { param([string] $Case, [string] $Text) $script:failed++; Note Red    "FAIL $Case -- $Text" }
function Skip { param([string] $Case, [string] $Text) $script:skipped++; Note Yellow "SKIP $Case -- $Text" }

# --- build the probe if it is not built --------------------------------------

# Rebuilt when the binaries are missing OR older than the sources. Building only when missing meant that after
# the submodule was bumped the suite silently ran the previous build, which did not have the options the newer
# cases pass, and reported the resulting silence as the case's own failure.
$built = @($probeExe, $hookDll) | Where-Object { Test-Path $_ } |
         ForEach-Object { (Get-Item $_).LastWriteTime } | Sort-Object | Select-Object -First 1
$newestSource = Get-ChildItem (Join-Path $probeRoot 'src') -File -Filter *.cpp -ErrorAction SilentlyContinue |
                ForEach-Object { $_.LastWriteTime } | Sort-Object -Descending | Select-Object -First 1
if (-not (Test-Path $probeExe) -or -not (Test-Path $hookDll) -or
    ($built -and $newestSource -and $newestSource -gt $built)) {
    Note Cyan "building the probe in $probeRoot"
    $buildLog = Join-Path $OutDir 'probe-build.log'
    & (Join-Path $probeRoot 'build.ps1') *>&1 | Tee-Object -FilePath $buildLog | Out-Null
    if (-not (Test-Path $probeExe)) { throw "the probe did not build; see $buildLog" }
}

# --- the player under test ---------------------------------------------------

if (-not $PlayerBinary) {
    $cand = Join-Path $repoRoot 'bin\mpc-hc_x64\mpc-hc64.exe'
    if (Test-Path $cand) { $PlayerBinary = $cand }
}

# --- cases that need no driver ------------------------------------------------

# One probe run answers both: it plants decoy blocks shaped like the victim, measures the stride from their
# addresses, then damages one decoy in the exact pattern and requires the heap walk to find it.
$plain = $null
if ('damage-detector' -in $Case -or 'heap-stride' -in $Case) {
    $json = Join-Path $OutDir 'no-driver.json'
    & $probeExe --no-driver --decoys 256 --log (Join-Path $OutDir 'no-driver.log') --json $json *> $null
    $code = $LASTEXITCODE
    if (-not (Test-Path $json)) { throw "the probe wrote no result file (exit $code); see $OutDir\no-driver.log" }
    $plain = Get-Content $json -Raw | ConvertFrom-Json
}

if ('damage-detector' -in $Case) {
    $c = 'damage-detector'
    if (-not $plain.selfTestRun) {
        Skip $c 'the probe did not run its self-test'
    } elseif ($plain.selfTestPassed) {
        Pass $c "the heap walk found the planted 0x64..0x6B damage among $($plain.vectorShapedBlocks) vector-shaped blocks"
    } else {
        Fail $c 'the heap walk did not find damage planted in a decoy, so a quiet run from this probe would mean nothing'
    }
}

if ('heap-stride' -in $Case) {
    $c = 'heap-stride'
    $s = [int] $plain.stride
    if ($s -eq $ExpectedStride) {
        Pass $c ("the 152-byte class puts 0x{0:x} ({1}) bytes between consecutive blocks, as expected" -f $s, $s)
    } else {
        Fail $c ("the 152-byte class puts 0x{0:x} ({1}) bytes between consecutive blocks, expected 0x{2:x} ({3}); neighbour analysis of a damaged block depends on this figure" -f $s, $s, $ExpectedStride, $ExpectedStride)
    }
}

# --- cases that host the legacy driver inside the player ---------------------

function Invoke-InPlayer {
    param([string] $Name, [string] $ExtraProbeArgs)

    $json = Join-Path $OutDir "$Name.json"
    $log  = Join-Path $OutDir "$Name.log"
    $injectLog = Join-Path $OutDir "$Name-inject.log"
    $probeArgs = "--rounds $Rounds --decoys 32 --qai-set 0=0x260,0x3c=8,0x30=0x5a,0x34=0x3c $ExtraProbeArgs".Trim()
    & $injectPs -Player $PlayerBinary -ProbeArgs $probeArgs -LogPath $log -JsonPath $json `
                -SettleSeconds 12 -RunSeconds 120 *> $injectLog
    if (-not (Test-Path $json)) { return $null }
    Get-Content $json -Raw | ConvertFrom-Json
}

$driverCases = @($Case | Where-Object { $_ -like 'legacy-umd-*' })
if ($driverCases) {
    if (-not $legacyDll) {
        foreach ($c in $driverCases) { Skip $c "the legacy driver binaries are not present (put atiumd64.dll in $probeRoot\drivers or set MPC_TEST_AMDUMD)" }
    } elseif (-not $PlayerBinary -or -not (Test-Path $PlayerBinary)) {
        foreach ($c in $driverCases) { Skip $c 'no built player to host the driver in (pass -PlayerBinary)' }
    } else {
        Note Cyan "driver under test: $legacyDll"
        Note Cyan "host: $PlayerBinary"

        if ('legacy-umd-shared-heap' -in $Case) {
            $c = 'legacy-umd-shared-heap'
            $r = Invoke-InPlayer -Name $c -ExtraProbeArgs ''
            if (-not $r) {
                Fail $c "the probe produced no result inside the player; see $OutDir\$c-inject.log"
            } elseif ($r.roundsDone -lt 1 -or $r.lastOpenAdapterHr -ne 0) {
                Fail $c ("the driver did not open inside the player: {0} of {1} rounds, last OpenAdapter 0x{2:x8}" -f $r.roundsDone, $Rounds, $r.lastOpenAdapterHr)
            } elseif ($r.victimClassAllocs -lt 1) {
                # Not a pass: the premise every heap-neighbour argument rests on would have stopped being true.
                Fail $c ("the driver took {0} blocks from the player's process heap but none in the 152-byte class, so it is no longer a neighbour of the menu vectors" -f $r.processHeapAllocs)
            } elseif ($r.signatureHits -gt 0 -or $r.decoyHits -gt 0) {
                Fail $c ("damage appeared: {0} blocks matching the 0x64..0x6B pattern, {1} decoys changed" -f $r.signatureHits, $r.decoyHits)
            } else {
                Pass $c ("{0} rounds in the player: {1} process-heap allocations, {2} in the 152-byte class, {3} of them within 4 strides of a vector-shaped block, no damage" -f $r.roundsDone, $r.processHeapAllocs, $r.victimClassAllocs, $r.driverBlocksNearVector)
            }
        }

        if ('legacy-umd-guard-zones' -in $Case) {
            $c = 'legacy-umd-guard-zones'
            $r = Invoke-InPlayer -Name $c -ExtraProbeArgs '--redzone'
            if (-not $r) {
                Fail $c "the probe produced no result inside the player; see $OutDir\$c-inject.log"
            } elseif ($r.guardZoneChecks -lt 1) {
                # Zero hits out of zero checks is not evidence of anything.
                Fail $c 'no guard zone was ever checked, so the result has no denominator'
            } elseif ($r.guardZoneHits -gt 0) {
                Fail $c ("the driver wrote outside its own allocations: {0} guard-zone hits in {1} checks" -f $r.guardZoneHits, $r.guardZoneChecks)
            } else {
                Pass $c ("no write outside the driver's own allocations in {0} guard-zone checks over {1} rounds" -f $r.guardZoneChecks, $r.roundsDone)
            }
        }

        # The window the field dumps actually point at: the driver had been through CreateDevice and teardown by
        # the time every damaged dump was written. The probe can reach into CreateDevice but cannot yet complete
        # it, because that needs a plausible description of hardware nobody here has. Until it can, this case
        # reports Skipped with how far the driver got: that is a limitation of the harness, not a finding about
        # the player, and must not read as a pass.
        if ('legacy-umd-device' -in $Case) {
            $c = 'legacy-umd-device'
            $r = Invoke-InPlayer -Name $c -ExtraProbeArgs $DeviceProbeArgs
            $deviceLog = Join-Path $OutDir "$c.log"
            $fault = if (Test-Path $deviceLog) { (Get-Content $deviceLog | Select-String '!! exception' | Select-Object -First 1).Line } else { $null }
            if (-not $r) {
                if ($fault) {
                    Skip $c "the driver faulted inside the player under the invented adapter record ($($fault -replace '!! ','')); that is the harness's hardware, not the player"
                } else {
                    Fail $c "the probe produced no result inside the player; see $OutDir\$c-inject.log"
                }
            } elseif (-not $r.PSObject.Properties['lastCreateDeviceHr']) {
                Skip $c 'this build of the probe does not report the device phase'
            } elseif ($r.lastCreateDeviceHr -ne 0) {
                Skip $c ("CreateDevice does not succeed yet (0x{0:x8} after {1} kernel callbacks of the fake kernel), so the window after it is not covered" -f $r.lastCreateDeviceHr, $r.fakeKernelSubmissions + $r.victimClassAllocs)
            } elseif ($r.signatureHits -gt 0 -or $r.decoyHits -gt 0 -or $r.guardZoneHits -gt 0) {
                Fail $c ("damage during the device phase: {0} blocks matching the 0x64..0x6B pattern, {1} decoys changed, {2} guard-zone hits" -f $r.signatureHits, $r.decoyHits, $r.guardZoneHits)
            } else {
                Pass $c ("the device phase ran clean: {0} process-heap allocations, {1} in the 152-byte class, no damage" -f $r.processHeapAllocs, $r.victimClassAllocs)
            }
        }
    }
}

# --- what this run did not cover ---------------------------------------------

if ($failed -eq 0 -and ('legacy-umd-shared-heap' -in $Case) -and $legacyDll -and $PlayerBinary) {
    Note DarkGray 'bound: the driver was taken through OpenAdapter, GetCaps and CloseAdapter only. CreateDevice and everything after it is where the driver does its work, and is not covered.'
}

[pscustomobject]@{ Suite = 'gpu-heap'; Passed = $passed; Failed = $failed; Skipped = $skipped; Notes = $notes }
