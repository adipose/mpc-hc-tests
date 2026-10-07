<#
.SYNOPSIS
    The playback suite: plays generated clips in the player under test and
    asserts on what reached the (virtual) speakers and the (virtual) monitor.

.DESCRIPTION
    Every case starts the player from the command line with a fresh portable
    profile, lets it play a clip whose content is declared in clips.json, and
    checks evidence the player has no hand in producing:

      sound    the WAV the virtual audio endpoint wrote -- which tones, on
               which channels, for how long;
      picture  the frame the virtual monitor was sent -- which colour is in
               which corner of where the video should be;
      process  whether the player exited by itself, and with what code.

    It needs two virtual devices on the target, from sibling repositories of
    the tuner emulator, both submodules here: tests\vaudio (vaudio-endpoint,
    a sound card that records) and tests\vdisplay (idd-vdisplay, a monitor
    that can be plugged and read back). $env:MPC_TEST_VAUDIO and
    $env:MPC_TEST_VDISPLAY point the suite at other checkouts, for working on
    a driver and the suite together.

    Installing a driver changes what a guest is, so the suite does not do it
    unasked: if the devices are absent it reports not-ready-on-this-guest and
    skips. -InstallDrivers installs them first (use it on a guest you hold
    and will revert, or as part of provisioning the pool).

.PARAMETER InstallDrivers
    Install or update both virtual devices on the target before running.
#>
[CmdletBinding()]
param(
    [switch] $Probe,
    [string] $VMName = '',
    [string] $OutDir = (Join-Path $PSScriptRoot 'results'),
    [string] $PlayerBinary,
    [switch] $InstallDrivers,
    # Run only the cases whose name matches one of these -like patterns; empty runs everything, which is how the
    # orchestrator calls the suite.
    [string[]] $Case = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$description = 'Plays generated clips; asserts on the audio and the frames that reached virtual output devices'
$testsRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$repoRoot = Split-Path $testsRoot -Parent
$vaudio = if ($env:MPC_TEST_VAUDIO) { $env:MPC_TEST_VAUDIO } else { Join-Path $testsRoot 'vaudio' }
$vdisplay = if ($env:MPC_TEST_VDISPLAY) { $env:MPC_TEST_VDISPLAY } else { Join-Path $testsRoot 'vdisplay' }
$transport = Join-Path $testsRoot 'emulator\tools\GuestTransport.ps1'

function Resolve-PlayerDir {
    param([string] $Binary)
    if ($Binary) { return (Split-Path (Resolve-Path $Binary).Path -Parent) }
    $own = Join-Path $repoRoot 'bin\mpc-hc_x64\mpc-hc64.exe'
    if (Test-Path $own) { return (Split-Path $own -Parent) }
    return $null
}

if ($Probe) {
    $ready = $true; $reason = ''
    if (-not (Test-Path $transport)) { $ready = $false; $reason = 'emulator submodule not initialised (git submodule update --init tests/emulator)' }
    elseif (-not (Test-Path (Join-Path $vaudio 'tests\wavcheck.py'))) { $ready = $false; $reason = 'vaudio submodule not initialised (git submodule update --init tests/vaudio)' }
    elseif (-not (Test-Path (Join-Path $vdisplay 'tools\Install-VDisplay.ps1'))) { $ready = $false; $reason = 'vdisplay submodule not initialised (git submodule update --init tests/vdisplay)' }
    elseif (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { $ready = $false; $reason = 'ffmpeg not on PATH' }
    elseif (-not (Get-Command python -ErrorAction SilentlyContinue)) { $ready = $false; $reason = 'python (with numpy) not on PATH' }
    return [pscustomobject]@{ Suite = 'playback'; Description = $description; Ready = $ready; Reason = $reason }
}

New-Item -ItemType Directory -Force $OutDir | Out-Null
# Absolute from here on: .NET file APIs resolve against the process directory, not PowerShell's location.
$OutDir = (Resolve-Path $OutDir).Path
$passed = 0; $failed = 0; $skipped = 0
$notes = [System.Collections.Generic.List[string]]::new()
function Note { param([string] $Colour, [string] $Text) $notes.Add($Text); Write-Host "  $Text" -ForegroundColor $Colour }
function Finish { [pscustomobject]@{ Suite = 'playback'; Passed = $passed; Failed = $failed; Skipped = $skipped; Notes = $notes } }

# --- media and player ---------------------------------------------------------

& (Join-Path $PSScriptRoot 'New-PlaybackClips.ps1') | Out-Null
$media = Join-Path $PSScriptRoot 'media'
$clips = (Get-Content (Join-Path $media 'clips.json') -Raw | ConvertFrom-Json)

$playerDir = Resolve-PlayerDir $PlayerBinary
if (-not $playerDir) { throw 'No player build: pass -PlayerBinary or build this repository (bin\mpc-hc_x64\mpc-hc64.exe).' }

# --- target -------------------------------------------------------------------

. $transport
$cfg = Get-TestBedConfig
$session = Connect-TestGuest -Guest $VMName
try {
    if ($InstallDrivers) {
        # Running against a provisioned guest needs nothing built here; installing does.
        foreach ($need in (Join-Path $vaudio 'build\out\x64\vaudio.sys'), (Join-Path $vdisplay 'build\out\x64\vdisplay.dll')) {
            if (-not (Test-Path $need)) { throw "-InstallDrivers needs the drivers built: $need is missing (tools\Build.ps1 in that submodule)." }
        }
        & (Join-Path $vaudio 'tools\Install-VAudio.ps1') -Session $session 6>&1 | Out-Null
        & (Join-Path $vdisplay 'tools\Install-VDisplay.ps1') -Session $session 6>&1 | Out-Null
    }

    $devices = Invoke-Command -Session $session {
        [pscustomobject]@{
            Audio   = [bool](Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.HardwareID -contains 'ROOT\VAudioEndpoint' -and $_.Status -eq 'OK' })
            Display = [bool](Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.HardwareID -contains 'Root\VDisplay' -and $_.Status -eq 'OK' })
            Console = (Get-CimInstance Win32_ComputerSystem).UserName
        }
    }
    if (-not $devices.Audio -or -not $devices.Display) {
        $skipped = 1
        Note Yellow "not run: this guest lacks the virtual audio endpoint and/or virtual display (audio=$($devices.Audio) display=$($devices.Display)); provision it, or run with -InstallDrivers on a guest you will revert"
        return (Finish)
    }
    $consoleUser = if ($cfg.GuestConsoleUser) { $cfg.GuestConsoleUser } else { ($devices.Console -split '\\')[-1] }
    if (-not $consoleUser) { throw 'Nobody is logged on at the guest console; the player needs a desktop.' }

    # Deploy the player as one archive: exe, icon library, LAV Filters, MPC Video Renderer and D3DX9.
    # No symbols, no import libraries.
    $stage = Join-Path $OutDir 'player-stage'
    if (Test-Path $stage) { Get-ChildItem $stage -Recurse -File | ForEach-Object { [IO.File]::Delete($_.FullName) } }
    New-Item -ItemType Directory -Force $stage, (Join-Path $stage 'LAVFilters64') | Out-Null
    Copy-Item (Join-Path $playerDir 'mpc-hc64.exe') $stage
    foreach ($f in 'mpciconlib.dll') { if (Test-Path (Join-Path $playerDir $f)) { Copy-Item (Join-Path $playerDir $f) $stage } }
    Get-ChildItem (Join-Path $playerDir 'LAVFilters64') -File | Where-Object { $_.Extension -in '.ax', '.dll', '.manifest' } | Copy-Item -Destination (Join-Path $stage 'LAVFilters64')
    # The installer puts MPC Video Renderer in MPCVR\ beside the exe, which is where the player loads it from.
    $mpcvrDir = Join-Path $playerDir 'MPCVR'
    if (Test-Path $mpcvrDir) {
        New-Item -ItemType Directory -Force (Join-Path $stage 'MPCVR') | Out-Null
        Get-ChildItem $mpcvrDir -File -Filter '*.ax' | Copy-Item -Destination (Join-Path $stage 'MPCVR')
    }
    # EVR-CP, the default renderer, needs D3DX9_43.dll. A clean Windows has none and the player stops on a
    # modal "missing d3dx9_43.dll" box, so every case runs into its timeout. The installer ships it from
    # distrib\x64; a build tree has it only there, two levels above bin\mpc-hc_x64.
    $d3dx = @((Join-Path $playerDir 'D3DX9_43.dll'), (Join-Path $playerDir '..\..\distrib\x64\D3DX9_43.dll')) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($d3dx) { Copy-Item $d3dx (Join-Path $stage 'D3DX9_43.dll') }
    else { Note Yellow "no D3DX9_43.dll beside the player or in its distrib\x64; EVR-CP will fail to load on a clean guest" }
    $zip = Join-Path $OutDir 'player.zip'
    if (Test-Path $zip) { [IO.File]::Delete($zip) }
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip

    Invoke-Command -Session $session {
        foreach ($d in 'C:\mpc-test', 'C:\mpc-test\media', 'C:\mpc-test\out') { if (-not (Test-Path $d)) { New-Item -ItemType Directory $d | Out-Null } }
        Get-Process mpc-hc64 -ErrorAction SilentlyContinue | Stop-Process -Force
    }
    Copy-Item -ToSession $session $zip 'C:\mpc-test\player.zip' -Force
    Copy-Item -ToSession $session (Join-Path $PSScriptRoot 'Run-PlayerCase.guest.ps1') 'C:\mpc-test\' -Force
    Get-ChildItem $media -File | Where-Object { $_.Extension -in '.mkv', '.mp4', '.ass', '.wav', '.png' } | ForEach-Object { Copy-Item -ToSession $session $_.FullName 'C:\mpc-test\media\' -Force }
    Invoke-Command -Session $session {
        Expand-Archive 'C:\mpc-test\player.zip' 'C:\mpc-test\player' -Force
        # A folder of two clips with different tones, for "next file in folder": a.mkv is stereo.mkv, b.mkv is
        # twotracks.mkv (its default track is 1200 Hz), and nothing else is in there.
        if (Test-Path 'C:\mpc-test\media\folder') { Remove-Item 'C:\mpc-test\media\folder' -Recurse -Force }
        New-Item -ItemType Directory 'C:\mpc-test\media\folder' | Out-Null
        Copy-Item 'C:\mpc-test\media\stereo.mkv' 'C:\mpc-test\media\folder\a.mkv'
        Copy-Item 'C:\mpc-test\media\twotracks.mkv' 'C:\mpc-test\media\folder\b.mkv'
    }

    $version = Invoke-Command -Session $session { (Get-Item 'C:\mpc-test\player\mpc-hc64.exe').VersionInfo.ProductVersion }
    Note Gray "player under test: $version from $playerDir"

    # --- one case ---------------------------------------------------------------

    function Invoke-PlayerCase {
        param(
            [string] $Name,
            [string] $Clip,
            [string] $Switches = '/play /close',
            [hashtable] $Settings = @{},
            [string] $PlugModes = '',          # non-empty: plug the virtual monitor with these modes for the case
            [double] $CaptureAtSec = 0,
            [double] $CloseAtSec = 0,          # non-zero: close the player's window at this time instead of /close
            [ValidateSet('WM_CLOSE', 'SC_CLOSE')] [string] $CloseKind = 'WM_CLOSE',
            [switch] $CloseWhenWindowAppears,  # close the moment a main window exists, not at CloseAtSec
            [int] $CloseRepeat = 1,            # send the close this many times, 50 ms apart
            [int] $RedirectStorm = 0,          # launch this many redirecting second instances mid-playback
            [string[]] $RedirectFiles = @(),   # the files they carry, in rotation
            [double] $StormAtSec = 2,
            [int] $StormIntervalMs = 150,
            [string[]] $SecondArgumentLine = @(), # at SecondAtSec the guest launches one more instance per command line,
                                               # 300 ms apart: close enough to arrive as one selection
            [double] $SecondAtSec = 2,
            [string] $PostCommands = '',         # comma-separated <seconds>:<command id>, posted as WM_COMMAND to the
                                               # player's window at each time (e.g. '2:895,8:887')
            [switch] $KeepProfile,             # keep the history file of the previous case: this case is its second run
            [hashtable] $Renderer = @{},       # MPC Video Renderer's own settings, which live in the registry
            [hashtable] $IniSections = @{}     # whole ini sections besides [Settings], for the internal filters
        )
        $tag = '{0}-{1}' -f $Name, (Get-Date -Format 'HHmmss')
        $guestOut = "C:\mpc-test\out\$tag.json"
        $guestPng = "C:\mpc-test\out\$tag.png"

        # A fresh portable profile: an ini beside the exe puts the player in ini mode, and nothing of the last
        # case -- or of whoever used this guest before -- carries over. UpdaterAutoCheck must be present or
        # the first-run prompt blocks an unattended player.
        $ini = [ordered]@{ UpdaterAutoCheck = 0; KeepHistory = 0; RememberFilePos = 0; Loop = 0; AllowMultipleInstances = 0; LogoFile = ''; ShowOSD = 0 }
        foreach ($k in $Settings.Keys) { $ini[$k] = $Settings[$k] }
        $iniText = "[Settings]`r`n" + (($ini.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`r`n") + "`r`n"
        foreach ($section in $IniSections.Keys) {
            $body = $IniSections[$section]
            $iniText += "`r`n[$section]`r`n" + (($body.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`r`n") + "`r`n"
        }
        $rendererJson = if ($Renderer.Count) { $Renderer | ConvertTo-Json -Compress } else { '' }

        $argumentLine = ('"C:\mpc-test\media\{0}" {1}' -f $Clip, $Switches).Trim()
        # Each later command line carries quoted paths, and no quoting survives the hand-built task line: each goes
        # over as base64 of the UTF-8 string (nothing but [A-Za-z0-9+/=]), comma-joined, and the guest decodes them.
        $secondEncoded = (@($SecondArgumentLine | Where-Object { $_ } | ForEach-Object { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($_)) })) -join ','
        # The casts are parenthesised: in a command's argument list a bare [bool]$x is the string "[bool]False",
        # which is true on the other side.
        $guest = Invoke-Command -Session $session -ArgumentList $iniText, $PlugModes, $argumentLine, $guestOut, $guestPng, $CaptureAtSec, $CloseAtSec, ([bool]$KeepProfile), $consoleUser, $CloseKind, ([bool]$CloseWhenWindowAppears), $CloseRepeat, $RedirectStorm, ($RedirectFiles -join ','), $StormAtSec, $StormIntervalMs, $rendererJson, $secondEncoded, $SecondAtSec, $PostCommands {
            param($iniText, $plugModes, $argumentLine, $out, $png, $captureAt, $closeAt, $keepProfile, $user, $closeKind, $closeOnWindow, $closeRepeat, $redirectStorm, $redirectFiles, $stormAtSec, $stormIntervalMs, $rendererJson, $secondEncoded, $secondAtSec, $postCommands)
            # The session is shared with the driver install scripts, which leave it on 'Stop'; a native tool
            # writing to stderr would then end the case instead of being a result.
            $ErrorActionPreference = 'Continue'
            Get-Process mpc-hc64 -ErrorAction SilentlyContinue | Stop-Process -Force
            # The settings are always this case's own; the history (mpc-hc64.history.ini, where positions and
            # track choices live) is kept only when the case says it is a second run.
            Get-ChildItem 'C:\mpc-test\player' -Filter '*.ini' |
                Where-Object { -not ($keepProfile -and $_.Name -like '*.history.ini') } |
                ForEach-Object { [IO.File]::Delete($_.FullName) }
            [IO.File]::WriteAllText('C:\mpc-test\player\mpc-hc64.ini', $iniText, [Text.Encoding]::Unicode)
            # The renderer's settings go to the guest as a file: the runner applies them as the console
            # user, whose hive is the one the player reads, and puts them back when the case ends.
            $rendererFile = 'C:\mpc-test\renderer.json'
            Remove-Item $rendererFile -ErrorAction SilentlyContinue
            if ($rendererJson) { [IO.File]::WriteAllText($rendererFile, $rendererJson) }

            $plug = $null
            if ($plugModes) {
                $status = & 'C:\vdisplay\vdisplayctl.exe' status | ConvertFrom-Json
                if ($status.connectors[0].plugged) { & 'C:\vdisplay\vdisplayctl.exe' unplug 0 | Out-Null; Start-Sleep -Seconds 2 }
                & 'C:\vdisplay\vdisplayctl.exe' plug 0 --modes $plugModes --name MPCTEST | Out-Null
                $plug = (& 'C:\vdisplay\vdisplayctl.exe' wait 0 --timeout 30000 | Out-String)
                Start-Sleep -Seconds 2      # let the shell settle on the new desktop before a window is placed on it
            }

            $taskArgs = "-NoProfile -ExecutionPolicy Bypass -File C:\mpc-test\Run-PlayerCase.guest.ps1 -Exe C:\mpc-test\player\mpc-hc64.exe -ArgumentLine `"$($argumentLine.Replace('"','\"'))`" -Out $out -CaptureAtSec $captureAt -CapturePath $png -CloseAtSec $closeAt$(if ($rendererJson) { ' -RendererFile C:\mpc-test\renderer.json' })"
            # Only the non-defaults go on the line: it is built by hand, and a plain case should read as one.
            # The redirect files are paths under C:\mpc-test\media (no commas, no spaces), joined for the ride and
            # split again on the guest.
            if ($closeKind -ne 'WM_CLOSE') { $taskArgs += " -CloseKind $closeKind" }
            if ($closeOnWindow) { $taskArgs += ' -CloseWhenWindowAppears' }
            if ($closeRepeat -gt 1) { $taskArgs += " -CloseRepeat $closeRepeat" }
            if ($redirectStorm -gt 0) {
                $taskArgs += " -RedirectStorm $redirectStorm -StormAtSec $stormAtSec -StormIntervalMs $stormIntervalMs"
                if ($redirectFiles) { $taskArgs += (' -RedirectFiles "{0}"' -f $redirectFiles) }
            }
            if ($secondEncoded) {
                $taskArgs += " -SecondArgumentLine $secondEncoded"
                if ($secondAtSec -ne 2) { $taskArgs += " -SecondAtSec $secondAtSec" }
            }
            # Digits, dots, colons and commas only: survives the hand-built line with plain quoting.
            if ($postCommands) { $taskArgs += (' -PostCommands "{0}"' -f $postCommands) }
            $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $taskArgs
            $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive
            Register-ScheduledTask -TaskName 'MpcPlaybackCase' -Action $action -Principal $principal -Force | Out-Null
            Start-ScheduledTask -TaskName 'MpcPlaybackCase'
            $deadline = (Get-Date).AddSeconds(90)
            while (-not (Test-Path $out) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
            Unregister-ScheduledTask -TaskName 'MpcPlaybackCase' -Confirm:$false
            Get-Process mpc-hc64 -ErrorAction SilentlyContinue | Stop-Process -Force

            if ($plugModes) {
                & 'C:\vdisplay\vdisplayctl.exe' unplug 0 | Out-Null
                # Windows plays its device-disconnect chord for the unplug. It opens the shared engine stream, and
                # the next case's player would join that same stream and have the chord at the start of its
                # capture. Let it finish and the stream close first.
                Start-Sleep -Seconds 4
            }

            [pscustomobject]@{
                Json = if (Test-Path $out) { Get-Content $out -Raw } else { $null }
                Plug = $plug
                HasPng = Test-Path $png
                History = if (Test-Path 'C:\mpc-test\player\mpc-hc64.history.ini') { Get-Content 'C:\mpc-test\player\mpc-hc64.history.ini' -Raw } else { $null }
                # The settings as the player's own shutdown left them; ReadAllText detects the UTF-16 BOM.
                Ini = if (Test-Path 'C:\mpc-test\player\mpc-hc64.ini') { [IO.File]::ReadAllText('C:\mpc-test\player\mpc-hc64.ini') } else { $null }
            }
        }
        if (-not $guest.Json) { throw "case $Name produced no result on the guest" }
        $run = $guest.Json | ConvertFrom-Json
        Set-Content (Join-Path $OutDir "$Name.guest.json") $guest.Json

        # The audio captures for this case: written by the driver between the case's start and finish, one per
        # render stream. A case that plays one file has one; a case whose player opens another file (next file in
        # folder) has one per file, in time order. Wav is the largest, Wavs all of them oldest first.
        $from = [datetime]$run.started; $to = ([datetime]$run.finished).AddSeconds(1)
        $wav = $null; $wavs = @()
        $hits = @(Invoke-Command -Session $session -ArgumentList $from, $to {
            param($from, $to)
            Get-ChildItem 'C:\Windows\System32\drivers\DriverData\Audio_Samples\SimpleAudioSample' -Filter *.wav -ErrorAction SilentlyContinue |
                Where-Object { $_.Length -gt 1000 -and $_.LastWriteTime -ge $from -and $_.LastWriteTime -le $to } |
                Sort-Object LastWriteTime | Select-Object FullName, Length
        })
        for ($i = 0; $i -lt $hits.Count; $i++) {
            $local = Join-Path $OutDir ('{0}.{1}.wav' -f $Name, ($i + 1))
            Copy-Item -FromSession $session $hits[$i].FullName $local -Force
            $wavs += $local
        }
        if ($hits.Count) {
            $largest = $hits | Sort-Object Length | Select-Object -Last 1
            $wav = $wavs[[array]::IndexOf(@($hits.FullName), $largest.FullName)]
        }

        $png = $null
        if ($guest.HasPng) { $png = Join-Path $OutDir "$Name.png"; Copy-Item -FromSession $session $guestPng $png -Force }

        if ($guest.History) { Set-Content (Join-Path $OutDir "$Name.history.ini") $guest.History }
        if ($guest.Ini) { Set-Content (Join-Path $OutDir "$Name.ini") $guest.Ini }

        [pscustomobject]@{ Run = $run; Wav = $wav; Wavs = $wavs; Png = $png; Plug = $guest.Plug; History = $guest.History; Ini = $guest.Ini }
    }

    # The value of a key in one section of an ini read as text; $null when the ini, the section or the key
    # is absent. Split on the section headers like Get-RememberedPosition does.
    function Get-IniValue {
        param([string] $Ini, [string] $Section, [string] $Key)
        if (-not $Ini) { return $null }
        foreach ($s in ($Ini -split '(?m)^\[')) {
            if ($s -match ('^' + [regex]::Escape($Section) + '\]') -and $s -match ('(?m)^' + [regex]::Escape($Key) + '=(.*)$')) {
                return $Matches[1].Trim()
            }
        }
        $null
    }

    # The position the history file holds for a clip, in seconds; $null when there is no entry. An entry is a
    # section with a Filename line ending in the clip's name and a FilePosition line in milliseconds.
    function Get-RememberedPosition {
        param([string] $History, [string] $Clip)
        if (-not $History) { return $null }
        foreach ($section in ($History -split '(?m)^\[')) {
            if ($section -match ('(?m)^Filename=.*\\' + [regex]::Escape($Clip) + '\s*$') -and $section -match '(?m)^FilePosition=(\d+)') {
                return [int]$Matches[1] / 1000.0
            }
        }
        $null
    }

    function Test-Audio {
        param([string] $Wav, [int[]] $Tones, [double] $Seconds, [double] $Tolerance = 0.4, [double] $SkipSeconds = 0.1)
        if (-not $Wav) { return 'no audio reached the endpoint' }
        # Shared mode: the engine resamples to the mix format, so rate and depth are the engine's, not the
        # clip's. The player starting and stopping the graph costs a little at each end, hence the tolerance.
        # The tones are read from one second starting -SkipSeconds into the signal; no tones checks the
        # duration alone, for a capture whose pitch the case makes no claim about.
        $checkArgs = @()
        if ($Tones) { $checkArgs += '--expect', ($Tones -join ',') }
        $output = & python (Join-Path $vaudio 'tests\wavcheck.py') $Wav @checkArgs --seconds $Seconds --duration-tolerance $Tolerance --skip-seconds $SkipSeconds 2>&1
        if ($LASTEXITCODE -eq 0) { return $null }
        return (($output | Where-Object { "$_" -match '^FAIL' }) -join '; ')
    }

    Add-Type -AssemblyName System.Drawing
    function Get-ColourName {
        param($c)
        if ($c.R -gt 180 -and $c.G -gt 180 -and $c.B -gt 180) { 'white' }
        elseif ($c.R -gt 180 -and $c.G -lt 90 -and $c.B -lt 90) { 'red' }
        elseif ($c.G -gt 180 -and $c.R -lt 90 -and $c.B -lt 90) { 'green' }
        elseif ($c.B -gt 180 -and $c.R -lt 90 -and $c.G -lt 90) { 'blue' }
        elseif ($c.R -gt 180 -and $c.B -gt 180 -and $c.G -lt 90) { 'magenta' }
        elseif ($c.G -gt 180 -and $c.B -gt 180 -and $c.R -lt 90) { 'cyan' }
        elseif ($c.R -lt 40 -and $c.G -lt 40 -and $c.B -lt 40) { 'black' }
        else { "($($c.R),$($c.G),$($c.B))" }
    }

    # Where a picture of the given shape lands when it is fitted, centred, into the screen; then the colour a
    # quarter of the way in from each of its corners.
    function Test-Picture {
        param([string] $Png, $Picture)
        if (-not $Png) { return 'no frame was captured' }
        $bmp = [System.Drawing.Bitmap]::FromFile($Png)
        try {
            $scale = [math]::Min($bmp.Width / $Picture.width, $bmp.Height / $Picture.height)
            $w = $Picture.width * $scale; $h = $Picture.height * $scale
            $x0 = ($bmp.Width - $w) / 2; $y0 = ($bmp.Height - $h) / 2
            $points = [ordered]@{
                topLeft = @(0.25, 0.25); topRight = @(0.75, 0.25); bottomLeft = @(0.25, 0.75); bottomRight = @(0.75, 0.75)
            }
            $wrong = foreach ($corner in $points.Keys) {
                $p = $points[$corner]
                $got = Get-ColourName $bmp.GetPixel([int]($x0 + $w * $p[0]), [int]($y0 + $h * $p[1]))
                $want = $Picture.corners.$corner
                if ($got -ne $want) { "$corner is $got, expected $want" }
            }
            if ($wrong) { return ($wrong -join '; ') }
            return $null
        } finally { $bmp.Dispose() }
    }

    # Which subtitle band is in the captured frame. The subtitle clips draw one solid magenta or cyan band; the
    # frame is scanned for those two colours (the quadrant picture has neither) rather than sampled at one point,
    # because where the renderer puts a drawing is not what this case is about.
    function Test-Band {
        param([string] $Png, [string] $Expected, [hashtable] $Meaning = @{})
        if (-not $Png) { return 'no frame was captured' }
        $bmp = [System.Drawing.Bitmap]::FromFile($Png)
        $count = @{ magenta = 0; cyan = 0 }
        try {
            for ($y = 0; $y -lt $bmp.Height; $y += 6) {
                for ($x = 0; $x -lt $bmp.Width; $x += 6) {
                    $name = Get-ColourName $bmp.GetPixel($x, $y)
                    if ($count.ContainsKey($name)) { $count[$name]++ }
                }
            }
        } finally { $bmp.Dispose() }
        $found = @($count.Keys | Where-Object { $count[$_] -ge 200 })   # 200 samples at step 6 is 7200 px, a band is far more
        if ($found -contains $Expected) { return $null }
        if ($found.Count -eq 0) { return "no subtitle band in the frame, expected $Expected" }
        $other = $found[0]
        if ($Meaning.ContainsKey($other)) { return "the band is $other, expected ${Expected}: $($Meaning[$other])" }
        return "the band is $other, expected $Expected"
    }

    # A case runs when -Case was not given or its name matches one of the patterns. A case the filter skips is
    # not counted at all: its Complete-Case never runs, so it is neither a pass, a fail, nor a skip.
    function Test-CaseSelected {
        param([string] $Name)
        foreach ($pattern in $Case) { if ($Name -like $pattern) { return $true } }
        return ($Case.Count -eq 0)
    }

    # What a flat field should come out as, worked out from the file: PQ to nits, the conversion's
    # fixed curve at the display target, then the sRGB transfer. Checking a renderer against another
    # renderer only says they agree; this says whether the arithmetic is right.
    function Get-FieldLevel {
        param($Field, [double] $DisplayNits)
        $peak = if ($Field.depth -eq 10) { 1023.0 } else { 255.0 }
        $black = if ($Field.depth -eq 10) { 64.0 } else { 16.0 }
        $white = if ($Field.depth -eq 10) { 940.0 } else { 235.0 }
        $signal = if ($Field.range -eq 'limited') { ($Field.code - $black) / ($white - $black) } else { $Field.code / $peak }
        if ($Field.transfer -ne 'pq') { return [math]::Round($signal * 255.0, 1) }   # SDR: the expansion, no curve

        $m1 = 0.1593017578125; $m2 = 78.84375
        $c1 = 0.8359375; $c2 = 18.8515625; $c3 = 18.6875
        $ep = [math]::Pow($signal, 1.0 / $m2)
        $linear = [math]::Pow([math]::Max($ep - $c1, 0.0) / ($c2 - $c3 * $ep), 1.0 / $m1)   # 1.0 is 10000 nits
        $x = $linear * (10000.0 / $DisplayNits)
        $hable = {
            param([double] $v)
            $a = 0.15; $b = 0.50; $cc = 0.10; $d = 0.20; $e = 0.02; $f = 0.30
            (($v * ($a * $v + $cc * $b) + $d * $e) / ($v * ($a * $v + $b) + $d * $f)) - $e / $f
        }
        $mapped = (& $hable $x) / (& $hable 4.8)
        $mapped = [math]::Min([math]::Max($mapped, 0.0), 1.0)
        [math]::Round([math]::Pow($mapped, 1.0 / 2.2) * 255.0, 1)
    }

    # The field fills the screen, so the middle of it is the picture wherever it was fitted.
    function Test-FlatField {
        param([string] $Png, $Field, [double] $DisplayNits, [double] $Tolerance = 4.0)
        if (-not $Png) { return 'no frame was captured' }
        $want = Get-FieldLevel $Field $DisplayNits
        $bmp = [System.Drawing.Bitmap]::FromFile($Png)
        try {
            $sum = 0.0; $n = 0
            for ($y = [int]($bmp.Height * 0.4); $y -lt [int]($bmp.Height * 0.6); $y += 4) {
                for ($x = [int]($bmp.Width * 0.4); $x -lt [int]($bmp.Width * 0.6); $x += 4) {
                    $p = $bmp.GetPixel($x, $y)
                    $sum += ($p.R + $p.G + $p.B) / 3.0; $n++
                }
            }
            $got = [math]::Round($sum / $n, 1)
        } finally { $bmp.Dispose() }
        if ([math]::Abs($got - $want) -gt $Tolerance) {
            return "the picture is $got, expected $want from the file (tolerance $Tolerance)"
        }
        return $null
    }

    function Complete-Case {
        param([string] $Name, [string[]] $Problems)
        $Problems = @($Problems | Where-Object { $_ })
        if ($Problems.Count -eq 0) { $script:passed++; Note Green "PASS $Name" }
        else { $script:failed++; Note Red "FAIL ${Name}: $($Problems -join ' | ')" }
    }

    function Get-ProcessProblem {
        param($Run)
        if ($Run.timedOut) { return 'the player did not exit by itself (/close) and had to be killed' }
        if ($Run.exitCode -ne 0) { return "the player exited with code $($Run.exitCode)" }
        return $null
    }

    $seconds = [double]$clips.seconds

    # --- cases ------------------------------------------------------------------

    # 1. The baseline every other case stands on: open, play to the end, close, exit 0; the whole clip's audio
    #    arrives, left on the left.
    if (Test-CaseSelected 'plays-to-end-and-exits') {
        $c = Invoke-PlayerCase -Name 'plays-to-end-and-exits' -Clip 'stereo.mkv'
        Complete-Case 'plays-to-end-and-exits' @(
            (Get-ProcessProblem $c.Run),
            (Test-Audio $c.Wav $clips.clips.'stereo.mkv'.audio[0].tones $seconds)
        )
    }

    # 2. The container's default flag picks the audio track: track 2 here, not track 1.
    #    (#99, #1551, #2093, #2673, #3935 -- the most re-reported behaviour in the tracker after file position.)
    if (Test-CaseSelected 'default-audio-track') {
        $c = Invoke-PlayerCase -Name 'default-audio-track' -Clip 'twotracks.mkv'
        $default = @($clips.clips.'twotracks.mkv'.audio | Where-Object default)[0]
        Complete-Case 'default-audio-track' @(
            (Get-ProcessProblem $c.Run),
            (Test-Audio $c.Wav $default.tones $seconds)
        )
    }

    # 3. Fullscreen on a second monitor: the picture fills the monitor it was sent to, the right way up.
    if (Test-CaseSelected 'fullscreen-second-monitor') {
        $c = Invoke-PlayerCase -Name 'fullscreen-second-monitor' -Clip 'stereo.mkv' -Switches '/play /close /fullscreen /monitor 2' -PlugModes '1920x1080@60' -CaptureAtSec 2.5
        Complete-Case 'fullscreen-second-monitor' @(
            (Get-ProcessProblem $c.Run),
            (Test-Picture $c.Png $clips.clips.'stereo.mkv'.picture)
        )
    }

    # 4. Display rotation metadata is honoured, in the direction ffmpeg's own autorotation takes as correct.
    #    (#375, #3832, then #3909 "[Regression bug 3832]".)
    if (Test-CaseSelected 'rotation-metadata') {
        $c = Invoke-PlayerCase -Name 'rotation-metadata' -Clip 'rotated90.mp4' -Switches '/play /close /fullscreen /monitor 2' -PlugModes '1920x1080@60' -CaptureAtSec 2.5
        Complete-Case 'rotation-metadata' @(
            (Get-ProcessProblem $c.Run),
            (Test-Picture $c.Png $clips.clips.'rotated90.mp4'.picture)
        )
    }

    # 5. Remember file position, the most re-reported behaviour in the tracker (#1595, #1805, #2287, #2659,
    #    #3182, #3352, #3847). Three runs on one profile: play and close the window part-way, so the player's
    #    own shutdown writes the position; open again, which must resume there; open once more with the
    #    option off, which must start from the beginning although the position is still on file.
    $long = $clips.clips.'long.mkv'
    $remember = @{ RememberFilePos = 1; KeepHistory = 1; RememberPosForLongerThan = 0 }
    $closeAt = 8.0
    $stored = $null     # written by the first run; a filter can run any of the three without the others
    if (Test-CaseSelected 'remember-position-first-run') {
        $a = Invoke-PlayerCase -Name 'remember-position-first-run' -Clip 'long.mkv' -Switches '/play' -Settings $remember -CloseAtSec $closeAt
        $stored = Get-RememberedPosition $a.History 'long.mkv'
        Complete-Case 'remember-position-first-run' @(
            (Get-ProcessProblem $a.Run),
            $(if (-not $a.Run.closeSent) { 'the close request did not reach a window' }),
            (Test-Audio $a.Wav $long.audio[0].tones $closeAt 1.0),
            $(if ($null -eq $stored) { 'no position for the clip in mpc-hc64.history.ini' }
              elseif ([math]::Abs($stored - $closeAt) -gt 1.5) { "history holds position ${stored}s, closed at ${closeAt}s" })
        )
    }

    if (Test-CaseSelected 'remember-position-resumes') {
        $b = Invoke-PlayerCase -Name 'remember-position-resumes' -Clip 'long.mkv' -Settings $remember -KeepProfile
        Complete-Case 'remember-position-resumes' @(
            (Get-ProcessProblem $b.Run),
            $(if ($null -ne $stored) { Test-Audio $b.Wav $long.audio[0].tones ([double]$long.seconds - $stored) 1.5 } else { 'no stored position to resume from' })
        )
    }

    if (Test-CaseSelected 'remember-position-off-starts-over') {
        $c = Invoke-PlayerCase -Name 'remember-position-off-starts-over' -Clip 'long.mkv' -Settings @{ RememberFilePos = 0; KeepHistory = 1 } -KeepProfile
        Complete-Case 'remember-position-off-starts-over' @(
            (Get-ProcessProblem $c.Run),
            (Test-Audio $c.Wav $long.audio[0].tones ([double]$long.seconds) 1.0)
        )
    }

    # 6. Repeat forever, per file: the 4 s clip is still playing when the window is closed at 10 s, and it is the
    #    same tones on the second time round. (#1691, #1850, #2488, #3324, #3738.)
    $stereo = $clips.clips.'stereo.mkv'     # case 7 asserts on it too, so it is defined outside the filters
    if (Test-CaseSelected 'repeat-file-forever') {
        $c = Invoke-PlayerCase -Name 'repeat-file-forever' -Clip 'stereo.mkv' -Switches '/play' -Settings @{ Loop = 1; LoopMode = 0 } -CloseAtSec 10
        Complete-Case 'repeat-file-forever' @(
            (Get-ProcessProblem $c.Run),
            (Test-Audio $c.Wav $stereo.audio[0].tones 10 1.0),
            (Test-Audio $c.Wav $stereo.audio[0].tones 10 1.0 -SkipSeconds 6)
        )
    }

    # 7. After playback: play the next file in the folder. a.mkv (440/880) is followed by b.mkv (1200 on its
    #    default track); with nothing after b the player closes the file and waits, and the window is closed at
    #    12 s. Each file is its own graph, so its own render stream and its own capture: two, in that order,
    #    each the whole clip. The setting is used rather than /playnext because it is the option the reports
    #    are about, and /close would outrank it. (#414, #697, #1419, #2200, #2209, #2579.)
    if (Test-CaseSelected 'next-file-in-folder') {
        $c = Invoke-PlayerCase -Name 'next-file-in-folder' -Clip 'folder\a.mkv' -Switches '/play' -Settings @{ AfterPlayback = 1 } -CloseAtSec 12
        $second = @($clips.clips.'twotracks.mkv'.audio | Where-Object default)[0]
        $problems = @((Get-ProcessProblem $c.Run))
        if ($c.Wavs.Count -ne 2) {
            $problems += "$($c.Wavs.Count) audio stream(s) reached the endpoint, expected 2 (one per file)"
        } else {
            $problems += (Test-Audio $c.Wavs[0] $stereo.audio[0].tones $seconds)
            $problems += (Test-Audio $c.Wavs[1] $second.tones $seconds)
        }
        Complete-Case 'next-file-in-folder' $problems
    }

    # 8. The container's default flag picks the subtitle track: track 2's cyan band at the centre, not track 1's
    #    magenta one, with the internal renderer. (#1551, #2452, #2876, #3283, #3914.)
    if (Test-CaseSelected 'default-subtitle-track') {
        $subs = $clips.clips.'subs.mkv'
        $defaultSub = @($subs.subtitles | Where-Object default)[0]
        $otherSub = @($subs.subtitles | Where-Object { -not $_.default })[0]
        $c = Invoke-PlayerCase -Name 'default-subtitle-track' -Clip 'subs.mkv' -Switches '/play /close /fullscreen /monitor 2' -PlugModes '1920x1080@60' -CaptureAtSec 2.5
        Complete-Case 'default-subtitle-track' @(
            (Get-ProcessProblem $c.Run),
            (Test-Picture $c.Png $subs.picture),
            (Test-Band $c.Png $defaultSub.band @{ $otherSub.band = "track $($otherSub.track) was rendered, which is not the default" })
        )
    }

    # 9. A subtitle file beside the clip, same base name, is loaded by itself and shown. (#1121, #1164, #1894,
    #    #3152.)
    if (Test-CaseSelected 'external-subtitle-autoload') {
        $ext = $clips.clips.'ext.mkv'
        $c = Invoke-PlayerCase -Name 'external-subtitle-autoload' -Clip 'ext.mkv' -Switches '/play /close /fullscreen /monitor 2' -PlugModes '1920x1080@60' -CaptureAtSec 2.5
        Complete-Case 'external-subtitle-autoload' @(
            (Get-ProcessProblem $c.Run),
            (Test-Picture $c.Png $ext.picture),
            (Test-Band $c.Png $ext.sidecar.band)
        )
    }

    # 10-13. MPC Video Renderer, which ships with the player and is picked by DSVidRen 14. Its own
    #    settings are not in the ini: they are in the registry, under the user that runs the player,
    #    which is why these cases pass -Renderer instead of putting them in -Settings.
    #
    #    What is asserted is the level the file implies, worked out by Get-FieldLevel -- not what some
    #    other renderer produces. The two 0.65 cases are each other's control: the same clip at two
    #    display targets must come out at two different levels, so neither can pass on a stuck value.
    #
    #    The capture is late and the clips are long because the renderer takes several seconds to get
    #    going on a guest with no GPU, where it also compiles its shaders. At 3 s the frame is still
    #    the player's logo.
    $rendererIni = @{ DSVidRen = 14; LastGPUCheck = 500000 }
    $rendererLav = @{ 'Internal Filters\LAVVideo\HWAccel' = @{ HWAccel = 0 } }
    $rendererBase = @{ UseD3D11 = 1; ConvertToSdr = 1; SdrToneMapping = 0; HdrPassthrough = 0 }

    # A player built from source has no MPCVR\ folder: only the installer and the release zips make one. Without
    # it these cases do not fail, they hang to a kill on a dark frame, which says nothing about the player. So
    # they are skipped, and the note says where the renderer comes from.
    $mpcvrCases = @('mpcvr-sdr-range', 'mpcvr-hdr-to-sdr-125', 'mpcvr-hdr-to-sdr-200', 'mpcvr-hdr-to-sdr-dark')
    $mpcvrMissing = -not (Test-Path (Join-Path $playerDir 'MPCVR\MpcVideoRenderer64.ax'))
    if ($mpcvrMissing) {
        $wanted = @($mpcvrCases | Where-Object { Test-CaseSelected $_ })
        if ($wanted.Count) {
            $skipped += $wanted.Count
            Note Yellow "skipped $($wanted -join ', '): the player under test has no MPCVR\MpcVideoRenderer64.ax beside it ($playerDir). Copy the MPCVR folder from a release zip (https://github.com/clsid2/mpc-hc/releases) next to mpc-hc64.exe."
        }
        $mpcvrCases = @()
    }

    if ($mpcvrCases -contains 'mpcvr-sdr-range' -and (Test-CaseSelected 'mpcvr-sdr-range')) {
        $field = $clips.clips.'flat_sdr.mkv'.field
        $c = Invoke-PlayerCase -Name 'mpcvr-sdr-range' -Clip 'flat_sdr.mkv' `
            -Switches '/play /close /fullscreen /monitor 2' -PlugModes '1920x1080@60' -CaptureAtSec 12 `
            -Settings $rendererIni -IniSections $rendererLav -Renderer ($rendererBase + @{ DisplayNits = 200 })
        Complete-Case 'mpcvr-sdr-range' @(
            (Get-ProcessProblem $c.Run),
            (Test-FlatField $c.Png $field 200)
        )
    }

    if ($mpcvrCases -contains 'mpcvr-hdr-to-sdr-125' -and (Test-CaseSelected 'mpcvr-hdr-to-sdr-125')) {
        $field = $clips.clips.'flat_pq065.mkv'.field
        $c = Invoke-PlayerCase -Name 'mpcvr-hdr-to-sdr-125' -Clip 'flat_pq065.mkv' `
            -Switches '/play /close /fullscreen /monitor 2' -PlugModes '1920x1080@60' -CaptureAtSec 12 `
            -Settings $rendererIni -IniSections $rendererLav -Renderer ($rendererBase + @{ DisplayNits = 125 })
        Complete-Case 'mpcvr-hdr-to-sdr-125' @(
            (Get-ProcessProblem $c.Run),
            (Test-FlatField $c.Png $field 125)
        )
    }

    if ($mpcvrCases -contains 'mpcvr-hdr-to-sdr-200' -and (Test-CaseSelected 'mpcvr-hdr-to-sdr-200')) {
        $field = $clips.clips.'flat_pq065.mkv'.field
        $c = Invoke-PlayerCase -Name 'mpcvr-hdr-to-sdr-200' -Clip 'flat_pq065.mkv' `
            -Switches '/play /close /fullscreen /monitor 2' -PlugModes '1920x1080@60' -CaptureAtSec 12 `
            -Settings $rendererIni -IniSections $rendererLav -Renderer ($rendererBase + @{ DisplayNits = 200 })
        Complete-Case 'mpcvr-hdr-to-sdr-200' @(
            (Get-ProcessProblem $c.Run),
            (Test-FlatField $c.Png $field 200),
            # the display target must actually have moved the picture, or both cases are reading something stuck
            $(if ($null -eq (Test-FlatField $c.Png $field 125)) { 'the 200 nit picture also passes as 125 nit, so the setting did nothing' })
        )
    }

    if ($mpcvrCases -contains 'mpcvr-hdr-to-sdr-dark' -and (Test-CaseSelected 'mpcvr-hdr-to-sdr-dark')) {
        $field = $clips.clips.'flat_pq025.mkv'.field
        $c = Invoke-PlayerCase -Name 'mpcvr-hdr-to-sdr-dark' -Clip 'flat_pq025.mkv' `
            -Switches '/play /close /fullscreen /monitor 2' -PlugModes '1920x1080@60' -CaptureAtSec 12 `
            -Settings $rendererIni -IniSections $rendererLav -Renderer ($rendererBase + @{ DisplayNits = 200 })
        Complete-Case 'mpcvr-hdr-to-sdr-dark' @(
            (Get-ProcessProblem $c.Run),
            (Test-FlatField $c.Png $field 200)
        )
    }

    # 14-15. clsid2/mpc-hc@a0735130e "Reset internal filters to enabled (once)": UpdateSettings, on loading a
    #    profile at SettingsVersion 8, re-enables every internal source and transform filter once and writes
    #    the profile at APPSETTINGS_VERSION (9 in AppSettings.h); a profile already there is left alone, so a
    #    filter a user turns off after the upgrade stays off. SRC_FLV and TRA_MPEG2 stand in for the two
    #    lists (SrcFiltersKeys/TraFiltersKeys in AppSettings.cpp, both defaulting to 1); they were chosen
    #    because stereo.mkv uses neither, so a filter left off cannot stop the clip playing. They are set
    #    to 0 in [Internal Filters], and what matters is what the player's own exit writes back. The first
    #    case guards the reset itself, the second that it does not run on every launch.
    $filterSection = [ordered]@{ SRC_FLV = 0; TRA_MPEG2 = 0 }
    if (Test-CaseSelected 'filters-reset-once-from-version-8') {
        $c = Invoke-PlayerCase -Name 'filters-reset-once-from-version-8' -Clip 'stereo.mkv' -Settings @{ SettingsVersion = 8 } -IniSections @{ 'Internal Filters' = $filterSection }
        $version = Get-IniValue $c.Ini 'Settings' 'SettingsVersion'
        $src = Get-IniValue $c.Ini 'Internal Filters' 'SRC_FLV'
        $tra = Get-IniValue $c.Ini 'Internal Filters' 'TRA_MPEG2'
        Complete-Case 'filters-reset-once-from-version-8' @(
            (Get-ProcessProblem $c.Run),
            $(if ($null -eq $c.Ini) { 'no mpc-hc64.ini came back from the guest' }),
            $(if ($c.Ini -and $version -ne '9') { "SettingsVersion is $version, expected 9 (APPSETTINGS_VERSION in AppSettings.h)" }),
            $(if ($c.Ini -and ($src -ne '1' -or $tra -ne '1')) { "filters set to 0 came back SRC_FLV=$src TRA_MPEG2=$tra, both expected 1" })
        )
    }

    if (Test-CaseSelected 'filters-kept-off-at-version-9') {
        $c = Invoke-PlayerCase -Name 'filters-kept-off-at-version-9' -Clip 'stereo.mkv' -Settings @{ SettingsVersion = 9 } -IniSections @{ 'Internal Filters' = $filterSection }
        $src = Get-IniValue $c.Ini 'Internal Filters' 'SRC_FLV'
        $tra = Get-IniValue $c.Ini 'Internal Filters' 'TRA_MPEG2'
        Complete-Case 'filters-kept-off-at-version-9' @(
            (Get-ProcessProblem $c.Run),
            $(if ($null -eq $c.Ini) { 'no mpc-hc64.ini came back from the guest' }
              elseif ($src -ne '0' -or $tra -ne '0') { "filters set to 0 came back SRC_FLV=$src TRA_MPEG2=$tra, both expected to stay 0" })
        )
    }

    # 16-20. The command line, and what a second instance's command line does to the running player. With
    #    AllowMultipleInstances=0 the second instance hands its line to the running player over WM_COPYDATA
    #    and exits; the guest runner records its exit as secondExited/secondExitCode, and the player's side
    #    shows in the audio captures (one per file played, oldest first).

    # 16. "Add to MPC-HC playlist" / /add must not pause what is playing: clsid2/mpc-hc@76ee7f64f4 removed the
    #    blanket pause f82f61855e had put in front of every redirected open (#3838). A second instance adds
    #    stereo.mkv at 2 s; the 20 s clip, closed at 8 s, must sound without a break until the close: about 7 s,
    #    since playback starts about a second after launch on the guest. Paused at 2 s it sounds for about 1.4
    #    (measured on 2.6.4).
    if (Test-CaseSelected 'add-keeps-playing') {
        $c = Invoke-PlayerCase -Name 'add-keeps-playing' -Clip 'long.mkv' -Switches '/play' -CloseAtSec 8 `
            -SecondArgumentLine '"C:\mpc-test\media\stereo.mkv" /add'
        $problems = @((Get-ProcessProblem $c.Run))
        if (-not $c.Run.secondExited) { $problems += 'the /add instance did not exit within 10 s' }
        elseif ($c.Run.secondExitCode -ne 0) { $problems += "the /add instance exited with code $($c.Run.secondExitCode)" }
        if ($c.Wavs.Count -ne 1) { $problems += "$($c.Wavs.Count) audio stream(s) reached the endpoint, expected 1 (the running clip's)" }
        else { $problems += (Test-Audio $c.Wavs[0] $long.audio[0].tones 7 1.0) }
        Complete-Case 'add-keeps-playing' $problems
    }

    # 17. /start: clsid2/mpc-hc@bb8bf48324 "Fix regression with setting initial startpos" -- f82f61855e had
    #    dropped it. A 20 s clip started at 12 s plays for about 8, not 20.
    if (Test-CaseSelected 'start-position') {
        $c = Invoke-PlayerCase -Name 'start-position' -Clip 'long.mkv' -Switches '/play /close /start 12000'
        Complete-Case 'start-position' @(
            (Get-ProcessProblem $c.Run),
            (Test-Audio $c.Wav $long.audio[0].tones 8 1.0)
        )
    }

    # 18. The same /start through a redirect (same commits, the ProcessCommandLine path): the second instance
    #    hands "long.mkv /start 12000" to the running player, which replaces stereo.mkv and must start long.mkv
    #    at 12 s. Two captures, oldest first: stereo.mkv's ~2 s, then long.mkv's ~8 s.
    if (Test-CaseSelected 'redirect-start-position') {
        $c = Invoke-PlayerCase -Name 'redirect-start-position' -Clip 'stereo.mkv' -Switches '/play' -CloseAtSec 13 `
            -SecondArgumentLine '"C:\mpc-test\media\long.mkv" /start 12000'
        $problems = @((Get-ProcessProblem $c.Run))
        if (-not $c.Run.secondExited) { $problems += 'the redirecting instance did not exit within 10 s' }
        elseif ($c.Run.secondExitCode -ne 0) { $problems += "the redirecting instance exited with code $($c.Run.secondExitCode)" }
        if ($c.Wavs.Count -ne 2) { $problems += "$($c.Wavs.Count) audio stream(s) reached the endpoint, expected 2 (one per file)" }
        else { $problems += (Test-Audio $c.Wavs[1] $long.audio[0].tones 8 1.0) }
        Complete-Case 'redirect-start-position' $problems
    }

    # 19. A redirected multi-file open as Explorer makes it: one instance per file, close together.
    #    clsid2/mpc-hc@2ac66df928 (#4171, of #3991 and #4168). The first redirect, third.mkv, replaces the
    #    playlist and starts playing; the second, folder\b.mkv 300 ms later, is within the redirect threshold
    #    (1000 ms), so it is the same selection: it is appended and the selection sorted by path. The fix starts
    #    that sort at index 1, under the playing file. Sorting from 0 moved "folder\b.mkv" in front of
    #    "third.mkv", which was playing at the end of the list with nothing after it, so b.mkv never played.
    #    LoopMode=1 plays the next playlist entry (AfterPlayback=1 is next file in folder, which
    #    DoAfterPlaybackEvent ignores once the playlist holds two entries). Three captures: stereo.mkv's 2 s,
    #    third.mkv, then b.mkv; on the unfixed player playback stops after third.mkv.
    if (Test-CaseSelected 'redirect-multi-file-order') {
        $c = Invoke-PlayerCase -Name 'redirect-multi-file-order' -Clip 'stereo.mkv' -Switches '/play' -Settings @{ LoopMode = 1 } -CloseAtSec 14 `
            -SecondArgumentLine '"C:\mpc-test\media\third.mkv"', '"C:\mpc-test\media\folder\b.mkv"'
        $second = @($clips.clips.'twotracks.mkv'.audio | Where-Object default)[0]     # folder\b.mkv is a copy of twotracks.mkv
        $problems = @((Get-ProcessProblem $c.Run))
        if (-not $c.Run.secondExited) { $problems += 'a redirecting instance did not exit within 10 s' }
        elseif ($c.Run.secondExitCode -ne 0) { $problems += "a redirecting instance exited with code $($c.Run.secondExitCode)" }
        if ($c.Wavs.Count -ne 3) { $problems += "$($c.Wavs.Count) audio stream(s) reached the endpoint, expected 3 (stereo.mkv, then third.mkv, then folder\b.mkv)" }
        else {
            $problems += (Test-Audio $c.Wavs[1] $clips.clips.'third.mkv'.audio[0].tones $seconds 1.0)
            $problems += (Test-Audio $c.Wavs[2] $second.tones $seconds 1.0)
        }
        Complete-Case 'redirect-multi-file-order' $problems
    }

    # 20. A video given with /dub and /add is one playlist entry: clsid2/mpc-hc@b18fd6036a (#4232, of #4224),
    #    which made the ADD branch append video + dub together like the open path always had. The second
    #    instance adds long_silent.mkv with dub.wav; with LoopMode=1 the entry follows stereo.mkv, and what
    #    sounds is the dub's 300 Hz over the video -- not silence (the video alone) and not a third capture
    #    (the dub as an entry of its own). The close covers stereo.mkv's end plus a few seconds of the dub.
    if (Test-CaseSelected 'dub-with-add-is-one-entry') {
        $c = Invoke-PlayerCase -Name 'dub-with-add-is-one-entry' -Clip 'stereo.mkv' -Switches '/play' -Settings @{ LoopMode = 1 } -CloseAtSec 9 `
            -SecondArgumentLine '"C:\mpc-test\media\long_silent.mkv" /dub "C:\mpc-test\media\dub.wav" /add'
        $problems = @((Get-ProcessProblem $c.Run))
        if (-not $c.Run.secondExited) { $problems += 'the /add instance did not exit within 10 s' }
        elseif ($c.Run.secondExitCode -ne 0) { $problems += "the /add instance exited with code $($c.Run.secondExitCode)" }
        if ($c.Wavs.Count -ne 2) { $problems += "$($c.Wavs.Count) audio stream(s) reached the endpoint, expected 2 (stereo.mkv, then the video with its dub)" }
        else { $problems += (Test-Audio $c.Wavs[1] $clips.clips.'dub.wav'.audio[0].tones 5 1.5) }
        Complete-Case 'dub-with-add-is-one-entry' $problems
    }

    # 21-25. The end of a file: what happens when playback runs out. These are the first cases that drive a
    #    running player, through the guest runner's PostCommands: a WM_COMMAND posted to the player's window at
    #    a given time after start, the same message a menu accelerator sends. MFC drops a posted command whose
    #    ON_UPDATE_COMMAND_UI reports it disabled, so the posts are timed at 2 s or later, once playback is
    #    underway; the runner records per post whether a window took it, and the cases assert the first one
    #    landed so that a pass cannot come from the commands never arriving.

    # 21. A counted playlist loop plays every entry on every pass, then stops: clsid2/mpc-hc@2df5c77369 made
    #    GraphEventComplete's skip-to-next a POSTED command, so the OnPlayStop during that skip's close zeroed
    #    m_nLoops after the count had been read, and a "repeat N times" playlist no longer stopped after N
    #    passes. folder\a.mkv (440/880) and folder\b.mkv (1200) on the command line are one two-entry playlist,
    #    LoopMode=1 and LoopNum=2 with Loop=0: the fLoopForever half of the setting would ignore the count
    #    (GraphEventComplete tests s.fLoopForever first). Four captures, a b a b, each the whole clip; then the
    #    player stops and the window is closed.
    if (Test-CaseSelected 'playlist-loops-twice') {
        $c = Invoke-PlayerCase -Name 'playlist-loops-twice' -Clip 'folder\a.mkv' -Switches '"C:\mpc-test\media\folder\b.mkv" /play' `
            -Settings @{ LoopMode = 1; LoopNum = 2 } -CloseAtSec 19.5
        $second = @($clips.clips.'twotracks.mkv'.audio | Where-Object default)[0]     # folder\b.mkv is a copy of twotracks.mkv
        $problems = @((Get-ProcessProblem $c.Run))
        if ($c.Wavs.Count -ne 4) { $problems += "$($c.Wavs.Count) audio stream(s) reached the endpoint, expected 4 (two passes of a two-entry playlist)" }
        else {
            for ($i = 0; $i -lt 4; $i++) {
                $want = if ($i % 2 -eq 0) { $stereo.audio[0].tones } else { $second.tones }
                $err = Test-Audio $c.Wavs[$i] $want $seconds 1.0
                if ($err) { $problems += "pass $($i + 1): $err" }
            }
        }
        Complete-Case 'playlist-loops-twice' $problems
    }

    # 22. An image whose source filter reports no duration must not advance to the next playlist entry on its
    #    own: clsid2/mpc-hc@fba51949c1. LAV's internal splitter claims only .gif and .webp among the image
    #    extensions (InsertLAVSplitterSource in FGManager.cpp), so a .png is rendered by DirectShow's Generate
    #    Still Video filter, which has no duration of its own; MPC-HC bounds it with a stop position
    #    StillVideoDuration seconds out (default 10, set to 3 here so the wait fits the case) and EC_COMPLETE
    #    fires when that is reached. The fix returns from GraphEventComplete for such an image instead of
    #    skipping; without it stereo.mkv would start at about 4 s and be heard before the close at 8.
    if (Test-CaseSelected 'image-waits-without-duration') {
        $c = Invoke-PlayerCase -Name 'image-waits-without-duration' -Clip 'still.png' -Switches '"C:\mpc-test\media\stereo.mkv" /play' `
            -Settings @{ LoopMode = 1; StillVideoDuration = 3 } -CloseAtSec 8
        Complete-Case 'image-waits-without-duration' @(
            (Get-ProcessProblem $c.Run),
            $(if ($c.Wavs.Count -ne 0) { "$($c.Wavs.Count) audio stream(s) reached the endpoint, expected none: the image must sit, not advance to stereo.mkv" })
        )
    }

    # 23. The playback rate survives the end of the stream: clsid2/mpc-hc@fb9f5dd489 (#3595, #3915) stopped
    #    OnPlayStop resetting m_dSpeedRate to 1 when the stop is the end of the file. One press of
    #    ID_PLAY_INCRATE doubles the rate (SpeedStep defaults to 0, the doubling branch of OnPlayChangeRate),
    #    so the 4 s clip ends in about half; the replay posted at 8 s must still run at 2x: about 2 s of
    #    audio. The rate change itself opens a new render stream, so there are three captures: before the
    #    change, the rest at 2x, and the replay. Only the replay is judged, by its duration: the renderer does
    #    pitch-shift at 2x (440/880 come out as 880/1760), which is not what this case is about. Measured: the
    #    replay lasts 2.1 s on develop and 4.1 s, at 440 Hz, on 2.5.4.
    if (Test-CaseSelected 'speed-kept-after-end') {
        $c = Invoke-PlayerCase -Name 'speed-kept-after-end' -Clip 'stereo.mkv' -Switches '/play' `
            -Settings @{ AfterPlayback = 0 } -PostCommands '2:895,8:887' -CloseAtSec 14
        $posts = @($c.Run.posts)
        $problems = @((Get-ProcessProblem $c.Run))
        if (-not $posts -or -not $posts[0] -or -not $posts[0].delivered) { $problems += 'the posted rate increase did not reach a window' }
        if ($c.Wavs.Count -lt 2) { $problems += "$($c.Wavs.Count) audio stream(s) reached the endpoint, expected the play and then the replay" }
        else { $problems += (Test-Audio $c.Wavs[-1] @() 2 0.7) }
        Complete-Case 'speed-kept-after-end' $problems
    }
}
finally {
    Remove-PSSession $session -ErrorAction SilentlyContinue
}

Finish
