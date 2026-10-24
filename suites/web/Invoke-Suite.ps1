<#
.SYNOPSIS
    The web suite: the web interface's JSON answers while the player is busy underneath them, and
    requests that arrive in more than one read.

.DESCRIPTION
    remote.html polls /status.json and /playlist.json once a second for as long as it is open. Those
    answers used to be built on the web server's own thread straight from lists the UI thread rebuilds
    whenever a file opens or the playlist changes (m_pSubStreams, the playlist), with no lock the web
    thread could take (ledger 29). After the fix the builders run on the UI thread, reached with a
    bounded SendMessageTimeout, and a frame that does not answer in time gets a 503.

    Cases (a .guest.ps1 on the target, in the console session, one launch each):

      json-under-file-changes    two clients poll both documents in tight loops for -Seconds while a
                                 command line alternates a long playlist of a plain clip with a clip
                                 that has two embedded subtitle tracks, every 700 ms. The player must
                                 survive and exit 0 on close, every 200 body must parse, no request may
                                 fail, the pollers must have seen both playlist sizes and both subtitle
                                 track counts (or the opens never raced the reads), and no other size:
                                 a playlist of 0 or 261 entries when it was only ever 1 or 150 is a walk
                                 over nodes being freed and reused (Run-WebStressCase.guest.ps1)
      header-split-across-reads  one request per split, its "\r\n\r\n" with 1, 2 or 3 bytes held back
                                 and sent 200 ms later, plus the whole terminator in either read as the
                                 control. Every split must get its 200: before the fix (ledger 30) the
                                 next search for the terminator started past the bytes that held its
                                 start, and the connection sat unanswered (Run-WebSplitHeaderCase.guest.ps1)

    A torn walk does not have to fault: in 120 s runs the unfixed build survived on the host and on a
    guest while reporting sizes it never had, so the sizes are what separates the builds. The 503 count
    and the refused connections (the listen backlog overflowing under the tight loops) are reported, not
    asserted.
#>
[CmdletBinding()]
param(
    [switch] $Probe,
    [string] $VMName = '',
    [string] $OutDir = (Join-Path $PSScriptRoot 'results'),
    [string] $PlayerBinary,
    [string[]] $Case,         # wildcards against case names; empty runs everything
    [int] $Seconds = 60,      # how long the pollers and the opener run
    [int] $Clients = 2,
    [int] $OpenEveryMs = 700,
    [int] $PlaylistItems = 150
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$description = 'Web interface JSON answers (status, playlist) polled while files open and close under them: the player must not fault and every body must parse (ledger 29); a request header whose end is split across two reads must be answered (ledger 30)'
$testsRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$repoRoot = Split-Path $testsRoot -Parent
$transport = Join-Path $testsRoot 'emulator\tools\GuestTransport.ps1'
$media = Join-Path $testsRoot 'suites\playback\media'
$clips = @('stereo.mkv', 'subs.mkv')

if ($Probe) {
    $ready = $true; $reason = ''
    if (-not (Test-Path $transport)) { $ready = $false; $reason = 'emulator submodule not initialised (git submodule update --init tests/emulator)' }
    elseif (@($clips | Where-Object { -not (Test-Path (Join-Path $media $_)) }).Count) { $ready = $false; $reason = 'playback clips missing: run suites\playback\New-PlaybackClips.ps1 first' }
    return [pscustomobject]@{ Suite = 'web'; Description = $description; Ready = $ready; Reason = $reason }
}

New-Item -ItemType Directory -Force $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path
$passed = 0; $failed = 0; $skipped = 0
$notes = [System.Collections.Generic.List[string]]::new()
function Note { param([string] $Colour, [string] $Text) $notes.Add($Text); Write-Host "  $Text" -ForegroundColor $Colour }
function Finish { [pscustomobject]@{ Suite = 'web'; Passed = $passed; Failed = $failed; Skipped = $skipped; Notes = $notes } }
function Complete-Case {
    param([string] $Name, [string[]] $Problems)
    $Problems = @($Problems | Where-Object { $_ })
    if ($Problems.Count -eq 0) { $script:passed++; Note Green "PASS $Name" }
    else { $script:failed++; Note Red "FAIL ${Name}: $($Problems -join ' | ')" }
}
function Wanted {
    param([string] $Name)
    if (-not $Case) { return $true }
    foreach ($c in $Case) { if ($Name -like $c) { return $true } }
    $script:skipped++
    $false
}

$playerDir = if ($PlayerBinary) { Split-Path (Resolve-Path $PlayerBinary).Path -Parent }
             elseif (Test-Path (Join-Path $repoRoot 'bin\mpc-hc_x64\mpc-hc64.exe')) { Join-Path $repoRoot 'bin\mpc-hc_x64' }
             else { $null }
if (-not $playerDir) { throw 'No player build: pass -PlayerBinary or build this repository (bin\mpc-hc_x64\mpc-hc64.exe).' }

. $transport
$cfg = Get-TestBedConfig -Guest $VMName
$session = Connect-TestGuest -Guest $VMName
try {
    $console = Invoke-Command -Session $session { (Get-CimInstance Win32_ComputerSystem).UserName }
    $consoleUser = if ($cfg.GuestConsoleUser) { $cfg.GuestConsoleUser } else { ("$console" -split '\\')[-1] }
    if (-not $consoleUser) { throw 'Nobody is logged on at the guest console; the player needs a desktop.' }

    # Deploy: the exe, its icon library, the LAV filters (the clips are Matroska) and D3DX9_43.dll for
    # EVR-CP, the default renderer, which is the one that keeps the internal subtitle renderer and so
    # the subtitle stream list the case is about. A build tree has the DLL only in distrib\x64.
    $stage = Join-Path $OutDir 'player-stage'
    if (Test-Path $stage) { Get-ChildItem $stage -Recurse -File | ForEach-Object { [IO.File]::Delete($_.FullName) } }
    New-Item -ItemType Directory -Force $stage, (Join-Path $stage 'LAVFilters64') | Out-Null
    Copy-Item (Join-Path $playerDir 'mpc-hc64.exe') $stage
    if (Test-Path (Join-Path $playerDir 'mpciconlib.dll')) { Copy-Item (Join-Path $playerDir 'mpciconlib.dll') $stage }
    Get-ChildItem (Join-Path $playerDir 'LAVFilters64') -File | Where-Object { $_.Extension -in '.ax', '.dll', '.manifest' } | Copy-Item -Destination (Join-Path $stage 'LAVFilters64')
    $d3dx = @((Join-Path $playerDir 'D3DX9_43.dll'), (Join-Path $playerDir '..\..\distrib\x64\D3DX9_43.dll'), (Join-Path $repoRoot 'distrib\x64\D3DX9_43.dll')) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($d3dx) { Copy-Item $d3dx (Join-Path $stage 'D3DX9_43.dll') }
    else { Note Yellow 'no D3DX9_43.dll beside the player or in distrib\x64; EVR-CP will fail to load on a clean guest' }
    $zip = Join-Path $OutDir 'player.zip'
    if (Test-Path $zip) { [IO.File]::Delete($zip) }
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip

    Invoke-Command -Session $session {
        Get-Process mpc-hc64 -ErrorAction SilentlyContinue | Stop-Process -Force
        foreach ($d in 'C:\mpc-test', 'C:\mpc-test\web', 'C:\mpc-test\web\media', 'C:\mpc-test\web\out') { if (-not (Test-Path $d)) { New-Item -ItemType Directory $d | Out-Null } }
    }
    Copy-Item -ToSession $session $zip 'C:\mpc-test\web\player.zip' -Force
    foreach ($guestScript in 'Run-WebStressCase.guest.ps1', 'Run-WebSplitHeaderCase.guest.ps1') { Copy-Item -ToSession $session (Join-Path $PSScriptRoot $guestScript) 'C:\mpc-test\web\' -Force }
    foreach ($clip in $clips) { Copy-Item -ToSession $session (Join-Path $media $clip) 'C:\mpc-test\web\media\' -Force }
    Invoke-Command -Session $session {
        if (Test-Path 'C:\mpc-test\web\player') { Remove-Item 'C:\mpc-test\web\player' -Recurse -Force }
        Expand-Archive 'C:\mpc-test\web\player.zip' 'C:\mpc-test\web\player' -Force
        # the case runs as the console user, who writes its results and the player's ini here
        & icacls 'C:\mpc-test\web' /grant 'Users:(OI)(CI)M' /T | Out-Null
    }
    $version = Invoke-Command -Session $session { (Get-Item 'C:\mpc-test\web\player\mpc-hc64.exe').VersionInfo.ProductVersion }
    Note Gray "player under test: $version from $playerDir"

    # One launch per case, from a fresh portable ini, in the console session through a scheduled task.
    function Invoke-WebJob {
        param([string] $Name, [hashtable] $Job, [string] $IniText, [int] $TimeoutSec, [string] $Script = 'Run-WebStressCase.guest.ps1')
        $guestOut = "C:\mpc-test\web\out\$Name"
        $Job.Exe = 'C:\mpc-test\web\player\mpc-hc64.exe'
        $Job.OutDir = $guestOut
        $jobJson = $Job | ConvertTo-Json -Depth 4
        $json = Invoke-Command -Session $session -ArgumentList $jobJson, $guestOut, $IniText, $consoleUser, $TimeoutSec, $Script {
            param($job, $out, $iniText, $user, $timeoutSec, $guestScript)
            $ErrorActionPreference = 'Continue'
            Get-Process mpc-hc64 -ErrorAction SilentlyContinue | Stop-Process -Force
            if (Test-Path $out) { Remove-Item $out -Recurse -Force }
            New-Item -ItemType Directory $out | Out-Null
            & icacls $out /grant 'Users:(OI)(CI)M' | Out-Null
            Get-ChildItem 'C:\mpc-test\web\player' -Filter '*.ini' | ForEach-Object { [IO.File]::Delete($_.FullName) }
            Remove-Item 'C:\mpc-test\web\player\default.mpcpl' -Force -ErrorAction SilentlyContinue
            [IO.File]::WriteAllText('C:\mpc-test\web\player\mpc-hc64.ini', $iniText, [Text.Encoding]::Unicode)
            [IO.File]::WriteAllText('C:\mpc-test\web\job.json', $job)

            $taskArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\mpc-test\web\$guestScript -Job C:\mpc-test\web\job.json"
            $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $taskArgs
            $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive
            Register-ScheduledTask -TaskName 'MpcWebCase' -Action $action -Principal $principal -Force | Out-Null
            Start-ScheduledTask -TaskName 'MpcWebCase'
            $deadline = (Get-Date).AddSeconds($timeoutSec)
            while (-not (Test-Path "$out\result.json") -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
            Unregister-ScheduledTask -TaskName 'MpcWebCase' -Confirm:$false
            Get-Process mpc-hc64 -ErrorAction SilentlyContinue | Stop-Process -Force
            if (Test-Path "$out\result.json") { Get-Content "$out\result.json" -Raw } else { $null }
        }
        if (-not $json) { throw "case $Name produced no result on the guest within $TimeoutSec s" }
        $local = Join-Path $OutDir $Name
        New-Item -ItemType Directory -Force $local | Out-Null
        Set-Content (Join-Path $local 'result.json') $json
        if ($Job.ContainsKey('Clients')) {
            foreach ($n in 1..$Job.Clients) {
                try { Copy-Item -FromSession $session "$guestOut\poller-$n.log" $local -ErrorAction Stop } catch { }
            }
        }
        $run = $json | ConvertFrom-Json
        if ($run.error) { throw "case $Name failed on the guest: $($run.error)" }
        $run
    }

    # The web server on, muted, no history, and command lines never merged into one Explorer selection:
    # two arriving within a second are otherwise appended rather than replacing the playlist.
    $port = 13579
    $ini = @(
        '[Settings]', 'UpdaterAutoCheck=0', 'KeepHistory=0', 'DefaultCapture=1',
        'EnableWebServer=1', "WebServerPort=$port", 'WebServerLocalhostOnly=1',
        'Volume=0', 'Mute=1', 'ShowOSD=0', 'RememberWindowPos=0', 'AllowMultipleInstances=1',
        'RedirectOpenToAppendThreshold=0'
    ) -join "`r`n"

    if (Wanted 'json-under-file-changes') {
        $job = @{
            ClipPlain = 'C:\mpc-test\web\media\stereo.mkv'; ClipSubs = 'C:\mpc-test\web\media\subs.mkv'
            Port = $port; Seconds = $Seconds; Clients = $Clients; OpenEveryMs = $OpenEveryMs; PlaylistItems = $PlaylistItems
        }
        $run = Invoke-WebJob -Name 'json-under-file-changes' -Job $job -IniText ($ini + "`r`n") -TimeoutSec ($Seconds + 90)
        $p = @()
        if (-not $run.survived) { $p += ('the player died during the run, exit code 0x{0:X8}' -f [uint32]$run.exitCode) }
        elseif (-not $run.closed) { $p += 'the player did not close within 20 s of WM_CLOSE' }
        elseif ($run.exitCode -ne 0) { $p += ('exit code 0x{0:X8}' -f [uint32]$run.exitCode) }
        if ($run.malformed) { $p += "$($run.malformed) answers with a body that does not parse" }
        if ($run.other) { $p += "$($run.other) answers with an unexpected status or a failed request" }
        if ($run.sendFailures) { $p += "$($run.sendFailures) command lines were not delivered" }
        if ($run.ok -lt 1000) { $p += "only $($run.ok) good answers in $Seconds s" }
        # The sizes the pollers reported, as "size:answers". The playlist is only ever 1 or $PlaylistItems
        # entries long, so any other size is a torn walk. The subtitle count is 0 for stereo.mkv and 3 for
        # subs.mkv (its two tracks plus the splitter's "no subtitles" entry), and the same holds there.
        $sizes = @($run.playlistSizes.PSObject.Properties | ForEach-Object { [int]$_.Name } | Sort-Object)
        $subs = @($run.subtitleCounts.PSObject.Properties | ForEach-Object { [int]$_.Name } | Sort-Object)
        $sizesText = ($run.playlistSizes.PSObject.Properties | Sort-Object { [int]$_.Name } | ForEach-Object { "$($_.Name):$($_.Value)" }) -join ' '
        $subsText = ($run.subtitleCounts.PSObject.Properties | Sort-Object { [int]$_.Name } | ForEach-Object { "$($_.Name):$($_.Value)" }) -join ' '
        if (1 -notin $sizes -or $PlaylistItems -notin $sizes) { $p += "the pollers did not see both playlist sizes 1 and ${PlaylistItems}: $sizesText" }
        $torn = @($sizes | Where-Object { $_ -ne 1 -and $_ -ne $PlaylistItems })
        if ($torn.Count) { $p += "playlist sizes the player never had: $($torn -join ', ') (seen as $sizesText)" }
        if (0 -notin $subs -or -not @($subs | Where-Object { $_ -ge 2 }).Count) { $p += "the pollers did not see both subtitle track counts 0 and 3: $subsText" }
        $torn = @($subs | Where-Object { $_ -notin 0, 2, 3 })
        if ($torn.Count) { $p += "subtitle track counts the player never had: $($torn -join ', ') (seen as $subsText)" }
        # Refused connections are the listen backlog overflowing under the tight loops, so they are
        # reported, not asserted; a build that answered nothing fails on the good-answer floor above.
        Note Gray ("  {0} good answers, {1} x 503, {2} refused, {3} opens, playlist sizes [{4}], subtitle counts [{5}], survived={6}, exit={7}" -f $run.ok, $run.s503, $run.refused, $run.opens, $sizesText, $subsText, $run.survived, $run.exitCode)
        Complete-Case 'json-under-file-changes' $p
    }

    if (Wanted 'header-split-across-reads') {
        $job = @{ Port = $port; GapMs = 200; ReadTimeoutMs = 3000 }
        $run = Invoke-WebJob -Name 'header-split-across-reads' -Job $job -IniText ($ini + "`r`n") -TimeoutSec 90 -Script 'Run-WebSplitHeaderCase.guest.ps1'
        $p = @()
        # Keyed by how many bytes of the request were held back for the second write: 1 to 3 split the
        # "\r\n\r\n", 0 and 4 keep it whole in one read and are the controls.
        foreach ($holdBack in 0..4) {
            $line = $run.answers."$holdBack"
            if ($line -notmatch '^HTTP/1\.[01] 200') {
                $p += "with $holdBack bytes held back: $(if ($line) { $line } else { 'no answer within 3 s' })"
            }
        }
        if (-not $run.survived) { $p += ('the player died during the run, exit code 0x{0:X8}' -f [uint32]$run.exitCode) }
        elseif (-not $run.closed) { $p += 'the player did not close within 20 s of WM_CLOSE' }
        Note Gray ("  answers by bytes held back: {0}" -f (($run.answers.PSObject.Properties | ForEach-Object { "$($_.Name)=[$($_.Value)]" }) -join ' '))
        Complete-Case 'header-split-across-reads' $p
    }
}
finally {
    Remove-PSSession $session -ErrorAction SilentlyContinue
}

Finish
