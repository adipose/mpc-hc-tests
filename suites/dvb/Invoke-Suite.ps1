<#
.SYNOPSIS
    The dvb suite's entry point for the orchestrator.

.DESCRIPTION
    Runs a headless tuner scan (/dvbscan, in the tree since #4138) per
    standard the rig provides, and asserts the DVB-T results against the
    emulator's encoding matrix with Test-MpcDecode. The headless scan writes
    the channel record JSON to a file and quits, so the assertions depend on
    neither the web API nor the scan-dialog window driving -- those remain
    available as the deeper standalone scripts in this directory.

    Tuners are resolved from the rig itself: the emulator's driver instances
    under DeviceClasses, classified by the standard named in each device's
    FriendlyName. Nothing about device monikers is assumed, because the
    trailing interface GUID differs per device and per install.

    Scan ranges per standard live in scan-ranges.psd1 beside this script and
    match the emulator's default provisioning; a rig provisioned differently
    overrides with -RangesPath.
#>
[CmdletBinding()]
param(
    [switch] $Probe,
    [string] $VMName = '',
    [string] $OutDir = (Join-Path $PSScriptRoot 'results'),
    [string] $PlayerBinary,
    [string] $RangesPath = (Join-Path $PSScriptRoot 'scan-ranges.psd1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$description = 'Digital TV: headless tuner scans against the virtual BDA tuner, channel records asserted against the encoding matrix'

if ($Probe) {
    $ready = $true; $reason = ''
    if (-not (Test-Path (Join-Path $PSScriptRoot '..\..\emulator\tools\GuestTransport.ps1'))) {
        $ready = $false; $reason = 'emulator submodule not initialised (git submodule update --init)'
    } else {
        . (Join-Path $PSScriptRoot '..\..\emulator\tools\GuestTransport.ps1')
        if (-not (Test-GuestTransportAvailable)) {
            $ready = $false; $reason = 'no usable transport -- create testbed.config.psd1 (see the emulator README)'
        }
    }
    return [pscustomobject]@{ Suite = 'dvb'; Description = $description; Ready = $ready; Reason = $reason }
}

. (Join-Path $PSScriptRoot '..\..\emulator\tools\RigClaim.ps1')
New-Item -ItemType Directory -Force $OutDir | Out-Null
$ranges = Import-PowerShellDataFile $RangesPath

$passed = 0; $failed = 0; $skipped = 0; $notes = [System.Collections.Generic.List[string]]::new()
function Note { param([string] $Colour, [string] $Text) $notes.Add($Text); Write-Host "  $Text" -ForegroundColor $Colour }

function Invoke-MatrixScan {
    <#
    .SYNOPSIS
        Map the encoding-matrix streams onto free DVB-T frequencies, scan only
        those, assert the result with Test-MpcDecode, then unmap them.
    .OUTPUTS
        State 'pass', 'fail' or 'skip', and a one-line Detail.
    #>
    param([string] $Guest, $Tuner, [string] $OutDir, [string] $PlayerBinary)

    $streamDir = Join-Path $PSScriptRoot 'results\matrix-streams'
    $matrixPath = Join-Path $PSScriptRoot '..\..\emulator\tools\encoding-matrix.psd1'
    $want = @((Import-PowerShellDataFile $matrixPath).Entries | ForEach-Object { $_.File })
    $have = @($want | Where-Object { Test-Path (Join-Path $streamDir $_) })
    if ($have.Count -ne $want.Count) {
        try {
            & (Join-Path $PSScriptRoot '..\..\emulator\tools\New-MatrixStreams.ps1') -OutDir $streamDir *> (Join-Path $OutDir 'matrix-streams.log')
        } catch {
            return [pscustomobject]@{ State = 'skip'; Detail = "the matrix streams could not be built ($($_.Exception.Message.Split([char]10)[0])); emulator\tools\Install-TestBed.ps1 -Phase Tsduck,FFmpeg fetches what they need" }
        }
    }
    $files = @($want | ForEach-Object { Get-Item (Join-Path $streamDir $_) })

    # One stream per 8 MHz DVB-T channel, in a contiguous block nothing on the
    # rig uses, so the scan covers exactly these and the rig's own muxes are
    # left alone. An unmapped frequency inside the block would be served the
    # driver's DefaultStreamLocation and add a channel nobody declared.
    $instance = $Tuner.Instance -replace '\\', '_'
    $session = Connect-TestGuest -Guest $Guest
    try {
        $mapped = @(Invoke-Command -Session $session -ArgumentList $instance -ScriptBlock {
            param($instance)
            Get-ChildItem "HKLM:\SYSTEM\PSWTuner\$instance\Device Parameters" -ErrorAction SilentlyContinue | ForEach-Object { [int]$_.PSChildName }
        })
        $r = $ranges['DVBT']
        $first = $null
        for ($top = $r.FreqEnd - ($r.FreqEnd - $r.FreqStart) % 8000; $top - 8000 * ($files.Count - 1) -ge $r.FreqStart; $top -= 8000) {
            $block = @(0..($files.Count - 1) | ForEach-Object { $top - 8000 * ($files.Count - 1) + 8000 * $_ })
            if (-not @($block | Where-Object { $mapped -contains $_ }).Count) { $first = $block[0]; break }
        }
        if ($null -eq $first) {
            return [pscustomobject]@{ State = 'skip'; Detail = "no block of $($files.Count) free DVB-T frequencies in $($r.FreqStart)-$($r.FreqEnd) kHz" }
        }
        $map = @{}
        for ($i = 0; $i -lt $files.Count; $i++) { $map[[string]($first + 8000 * $i)] = $files[$i].Name }

        Invoke-Command -Session $session { New-Item -ItemType Directory -Force C:\ts\matrix-scan | Out-Null }
        foreach ($f in $files) { Copy-Item $f.FullName -Destination "C:\ts\matrix-scan\$($f.Name)" -ToSession $session -Force }
        try {
            Invoke-Command -Session $session -ArgumentList $instance, $map -ScriptBlock {
                param($instance, $map)
                foreach ($khz in $map.Keys) {
                    $k = "HKLM:\SYSTEM\PSWTuner\$instance\Device Parameters\$khz"
                    New-Item -Path $k | Out-Null
                    Set-ItemProperty $k -Name StreamLocation -Value "\??\C:\ts\matrix-scan\$($map[$khz])" -Type String
                    Set-ItemProperty $k -Name FriendlyName   -Value $map[$khz] -Type String
                    Set-ItemProperty $k -Name SignalLocked   -Value 1   -Type DWord
                    Set-ItemProperty $k -Name SignalPresent  -Value 1   -Type DWord
                    Set-ItemProperty $k -Name SignalQuality  -Value 100 -Type DWord
                    Set-ItemProperty $k -Name SignalStrength -Value 63  -Type DWord
                }
            }
            $job = @{
                label = 'headless-dvbt-matrix'; headless = $true; tuner = $Tuner.Moniker
                freqStart = $first; freqEnd = $first + 8000 * ($files.Count - 1)
                bandwidth = 8000; symbolRate = 0; ignoreEncrypted = 0; clearChannels = $true
                timeoutSec = $r.TimeoutSec
            }
            $scanArgs = @{ Job = $job; VMName = $Guest; WaitSec = ($r.TimeoutSec + 300) }
            if ($PlayerBinary) { $scanArgs.HostBinary = $PlayerBinary } else { $job.allowExistingBinary = $true }
            $raw = & (Join-Path $PSScriptRoot 'Invoke-MpcScan.ps1') @scanArgs
        } finally {
            Invoke-Command -Session $session -ArgumentList $instance, $map -ScriptBlock {
                param($instance, $map)
                foreach ($khz in $map.Keys) { Remove-Item "HKLM:\SYSTEM\PSWTuner\$instance\Device Parameters\$khz" -ErrorAction SilentlyContinue }
                Remove-Item C:\ts\matrix-scan -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    } finally { Remove-PSSession $session }

    $resultFile = Join-Path $OutDir 'headless-dvbt-matrix.json'
    $raw | Set-Content $resultFile
    $log = Join-Path $OutDir 'decode-assert.log'
    # Test-MpcDecode exits 1 on a mismatch and throws on a precondition it
    # will not guess past. Both are a failure here: the streams are the
    # matrix's own, so neither can be blamed on how the rig is provisioned.
    try {
        & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Test-MpcDecode.ps1') -JsonPath $resultFile *> $log
        $code = $LASTEXITCODE
    } catch { $code = -1; "$($_.Exception.Message)" | Add-Content $log }
    $summary = @(Get-Content $log | Where-Object { $_ -match 'entries decoded as declared' }) | Select-Object -Last 1
    if ($code -eq 0) { return [pscustomobject]@{ State = 'pass'; Detail = "$summary ($($first)-$($first + 8000 * ($files.Count - 1)) kHz)" } }
    [pscustomobject]@{ State = 'fail'; Detail = "$(if ($summary) { $summary } else { 'the assertion did not run' }) -- see $log" }
}

# --- resolve the rig's tuners ----------------------------------------------

$claim = Enter-RigClaim -VMName $VMName
$guest = $claim.Guest
try {
    $session = Connect-TestGuest -Guest $guest
    try {
        $tuners = Invoke-Command -Session $session -ScriptBlock {
            # KSCATEGORY_BDA_NETWORK_TUNER interface instances of the virtual
            # devices. The moniker MPC-HC stores is the device interface path
            # plus the KS reference string, both read from the registry rather
            # than assumed: the reference-string subkey is named #{guid} and
            # its Device Parameters carries the filter's FriendlyName
            # (e.g. 'BDA DVBT Sample Tuner'). Lowercased because that is how
            # MPC-HC's device enumeration spells the moniker it compares
            # against.
            $cat = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceClasses\{71985f48-1ca1-11d3-9cc8-00c04f7971e0}'
            # -LiteralPath throughout: the interface name contains '?', which
            # the provider otherwise treats as a wildcard -- and a wildcard
            # leaf makes Get-ChildItem return the matching key itself instead
            # of its children, silently.
            foreach ($ifaceName in (Get-ChildItem -LiteralPath $cat -Name | Where-Object { $_ -match '#ROOT#MEDIA#' })) {
                $inst = ($ifaceName -split '#')[3..5] -join '\'   # ROOT\MEDIA\000n
                foreach ($refName in (Get-ChildItem -LiteralPath "$cat\$ifaceName" -Name | Where-Object { $_ -match '^#\{' })) {
                    $friendly = (Get-ItemProperty -LiteralPath "$cat\$ifaceName\$refName\Device Parameters" -Name FriendlyName -ErrorAction SilentlyContinue).FriendlyName
                    [pscustomobject]@{
                        Moniker  = ('@device:pnp:\\?\' + ($ifaceName -replace '^##\?#', '') + '\' + $refName.TrimStart('#')).ToLowerInvariant()
                        Friendly = $friendly
                        Instance = $inst
                    }
                }
            }
        }
    } finally { Remove-PSSession $session }

    $byStandard = @{}
    foreach ($t in $tuners) {
        foreach ($std in 'DVBT', 'DVBC', 'DVBS', 'ATSC') {
            if ($t.Friendly -and $t.Friendly -replace '[- ]', '' -match $std) { $byStandard[$std] = $t; break }
        }
    }
    if (-not $byStandard.Count) {
        throw "No virtual tuners resolved on $guest. Deploy the driver first (emulator: Build-And-Deploy.ps1). Found: $(@($tuners).Count) unclassified device(s)."
    }
    Note DarkGray "tuners on ${guest}: $(($byStandard.Keys | Sort-Object) -join ', ')"

    # --- one headless scan per standard, decode assertion on DVB-T ----------

    foreach ($std in ($byStandard.Keys | Sort-Object)) {
        if (-not $ranges.ContainsKey($std)) { $skipped++; Note Yellow "${std}: no scan range declared -- skipped"; continue }
        $r = $ranges[$std]
        $job = @{
            label      = "headless-$($std.ToLower())"
            headless   = $true
            tuner      = $byStandard[$std].Moniker
            freqStart  = $r.FreqStart; freqEnd = $r.FreqEnd
            bandwidth  = $r.Bandwidth; symbolRate = $r.SymbolRate
            ignoreEncrypted = 0; clearChannels = $true
            timeoutSec = $r.TimeoutSec
        }
        $scanArgs = @{ Job = $job; VMName = $guest; WaitSec = ($r.TimeoutSec + 300) }
        if ($PlayerBinary) { $scanArgs.HostBinary = $PlayerBinary }
        else {
            # No build under test on the host: measure what the rig carries,
            # and say so -- the harness refuses an unnamed binary otherwise.
            $job.allowExistingBinary = $true
        }

        try {
            $raw = & (Join-Path $PSScriptRoot 'Invoke-MpcScan.ps1') @scanArgs
        } catch {
            $failed++; Note Red "${std}: scan could not run -- $($_.Exception.Message.Split([char]10)[0])"
            continue
        }
        $raw | Set-Content (Join-Path $OutDir "$($job.label).json")
        $result = $raw | ConvertFrom-Json

        $channels = @()
        if ($result.PSObject.Properties['channelsJson'] -and $result.channelsJson) {
            $channels = @(($result.channelsJson | ConvertFrom-Json).channels)
        }
        if ($channels.Count -gt 0) {
            $passed++; Note Green "${std}: headless scan found $($channels.Count) channel(s)"
        } else {
            $failed++; Note Red "${std}: headless scan found no channels ($(if ($result.PSObject.Properties['error']) { $result.error } else { 'empty result' }))"
            continue
        }

        if ($std -eq 'ATSC') {
            # Every ATSC service is known by the two-part virtual channel number in its VCT, and the player
            # orders by originNumber = major * 1000 + minor (CBDAChannel::SetATSCNumber). Before #4136
            # (425a3b1d75) ParseVCT read the numbers and dropped them, so every service came out 0 and
            # the list stayed in discovery order. This holds for whatever the rig carries, so it needs no
            # declaration of the rig's services. The encrypted count is a note: access_controlled is
            # read since the same fix, but which services set it is the rig's business.
            $unnumbered = @($channels | Where-Object { -not $_.atscMajor -or $_.originNumber -ne ($_.atscMajor * 1000 + $_.atscMinor) })
            if ($unnumbered.Count) {
                $failed++; Note Red ("ATSC: {0} of {1} channel(s) carry no virtual channel number (e.g. '{2}': atscMajor {3}, atscMinor {4}, originNumber {5})" -f
                    $unnumbered.Count, $channels.Count, $unnumbered[0].name, $unnumbered[0].atscMajor, $unnumbered[0].atscMinor, $unnumbered[0].originNumber)
            } else {
                $passed++; Note Green "ATSC: every channel carries its VCT virtual number ($((@($channels | ForEach-Object { "$($_.atscMajor).$($_.atscMinor)" }) | Sort-Object -Unique) -join ', '))"
            }
            Note DarkGray "      $(@($channels | Where-Object encrypted).Count) of $($channels.Count) ATSC channel(s) report access-controlled"
        }

    }

    # --- the encoding matrix on the DVB-T tuner -------------------------------
    #
    # The rig's own DVB-T streams are the colour test muxes and some off-air
    # captures, which share service identifiers and declare nothing, so the
    # matrix cannot be asserted against them. This used to be a skip on every
    # rig, because nothing provisioned the matrix streams. The suite now does:
    # it builds them (cached under results\), maps each onto a free DVB-T
    # frequency for the length of one scan, asserts that scan, and removes the
    # mapping and the files again whatever happens.
    if ($byStandard.ContainsKey('DVBT')) {
        $assert = Invoke-MatrixScan -Guest $guest -Tuner $byStandard['DVBT'] -OutDir $OutDir -PlayerBinary $PlayerBinary
        switch ($assert.State) {
            'pass'    { $passed++;  Note Green  "DVBT matrix: $($assert.Detail)" }
            'fail'    { $failed++;  Note Red    "DVBT matrix: $($assert.Detail)" }
            default   { $skipped++; Note Yellow "DVBT matrix: skipped -- $($assert.Detail)" }
        }
    }
} finally {
    Exit-RigClaim -Claim $claim
}

[pscustomobject]@{ Suite = 'dvb'; Passed = $passed; Failed = $failed; Skipped = $skipped; Notes = $notes }
