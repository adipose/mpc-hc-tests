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
    # Two translations, for the cases that run the player in a language other than English (the
    # satellite DLL is the resource handle then) and switch between them; the other 42 are not needed.
    foreach ($lang in 'de', 'fr') {
        $dll = Join-Path $playerDir "Lang\mpcresources.$lang.dll"
        if (Test-Path $dll) {
            New-Item -ItemType Directory -Force (Join-Path $stage 'Lang') | Out-Null
            Copy-Item $dll (Join-Path $stage 'Lang')
        }
    }
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
    Copy-Item -ToSession $session (Join-Path $PSScriptRoot 'Run-ApiCase.guest.ps1') 'C:\mpc-test\' -Force
    Get-ChildItem $media -File | Where-Object { $_.Extension -in '.mkv', '.mp4', '.ass', '.wav', '.png', '.flac', '.rar' } | ForEach-Object { Copy-Item -ToSession $session $_.FullName 'C:\mpc-test\media\' -Force }
    Invoke-Command -Session $session {
        Expand-Archive 'C:\mpc-test\player.zip' 'C:\mpc-test\player' -Force
        # A folder of two clips with different tones, for "next file in folder": a.mkv is stereo.mkv, b.mkv is
        # twotracks.mkv (its default track is 1200 Hz), and nothing else is in there.
        if (Test-Path 'C:\mpc-test\media\folder') { Remove-Item 'C:\mpc-test\media\folder' -Recurse -Force }
        New-Item -ItemType Directory 'C:\mpc-test\media\folder' | Out-Null
        Copy-Item 'C:\mpc-test\media\stereo.mkv' 'C:\mpc-test\media\folder\a.mkv'
        Copy-Item 'C:\mpc-test\media\twotracks.mkv' 'C:\mpc-test\media\folder\b.mkv'
        # Two audio-only files in one folder, the second with art of its own, for the cover-art case.
        if (Test-Path 'C:\mpc-test\media\art') { Remove-Item 'C:\mpc-test\media\art' -Recurse -Force }
        New-Item -ItemType Directory 'C:\mpc-test\media\art' | Out-Null
        Copy-Item 'C:\mpc-test\media\dub.wav' 'C:\mpc-test\media\art\a.wav'
        Copy-Item 'C:\mpc-test\media\dub.wav' 'C:\mpc-test\media\art\b.wav'
        Copy-Item 'C:\mpc-test\media\still.png' 'C:\mpc-test\media\art\b.png'
        # A copy of stereo.mkv under a name the history-exclude-filter case's filter matches:
        # HistoryExcludeFilter=secret is a case-insensitive substring match on the full path.
        Copy-Item 'C:\mpc-test\media\stereo.mkv' 'C:\mpc-test\media\SECRET-clip.mkv' -Force
        # A copy of stereo.mkv in a folder and under a name that need escaping in JSON, for the
        # /status.json case. Built from char codes so this file can stay plain ASCII.
        if (Test-Path 'C:\mpc-test\media\json test') { Remove-Item 'C:\mpc-test\media\json test' -Recurse -Force }
        New-Item -ItemType Directory 'C:\mpc-test\media\json test' | Out-Null
        Copy-Item 'C:\mpc-test\media\stereo.mkv' ("C:\mpc-test\media\json test\it's " + [char]0x00FC + "n" + [char]0x00EF + "code & co.mkv")
        # Thirty copies of stereo.mkv, for the playlist cases: more entries than fit in the list, with
        # two-character names so no column goes wide. list30.mpcpl lists them; a case that needs the
        # startup-restore path copies it to C:\mpc-test\player\default.mpcpl for its own run only.
        if (Test-Path 'C:\mpc-test\media\list30') { Remove-Item 'C:\mpc-test\media\list30' -Recurse -Force }
        New-Item -ItemType Directory 'C:\mpc-test\media\list30' | Out-Null
        $mpcpl = [Text.StringBuilder]::new()
        [void] $mpcpl.AppendLine('MPCPLAYLIST')
        foreach ($i in 1..30) {
            $name = '{0:00}.mkv' -f $i
            Copy-Item 'C:\mpc-test\media\stereo.mkv' "C:\mpc-test\media\list30\$name"
            [void] $mpcpl.AppendLine("$i,type,0")
            [void] $mpcpl.AppendLine("$i,filename,C:\mpc-test\media\list30\$name")
        }
        [IO.File]::WriteAllText('C:\mpc-test\media\list30.mpcpl', $mpcpl.ToString(), [Text.UTF8Encoding]::new($true))
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
                                               # player's window at each time (e.g. '2:895,8:887'); the form
                                               # <seconds>:msg:<msg>:<wParam> (decimal, e.g. '3:msg:16:0') posts
                                               # that raw message to the player's frame instead
            [string] $ProbeAt = '',              # comma-separated seconds: at each, the guest reads the player's
                                               # playlist list control (count, selection, scroll, scrollbars)
                                               # into the run's probes array
            [string[]] $HttpAt = @(),          # '<sec>|<method>|<path>|<body>' web requests, run in the same
                                               # time-ordered sequence as the posts and probes; answers land in
                                               # the run's http array, bodies in http-<n>.bin files
            [int] $HttpPort = 13579,           # the port the profile's WebServerPort must match
            [string] $CloseDialogAt = '',      # comma-separated <sec>:<window title>: at each, post IDCANCEL to
                                               # that window of the player's process (a modal it raised)
            [switch] $KeepProfile,             # keep the history file of the previous case: this case is its second run
            [switch] $NoUpdaterSetting,        # leave UpdaterAutoCheck out of the profile, so the first-run
                                               # update-check prompt appears (the case that is about that prompt)
            [hashtable] $Renderer = @{},       # MPC Video Renderer's own settings, which live in the registry
            [hashtable] $IniSections = @{},    # whole ini sections besides [Settings], for the internal filters
            [string] $AcceptDialogAt = '',     # like CloseDialogAt, but posts IDOK: accepts the dialog (the RAR
                                               # entry selector's Select button, which no other option can press)
            [string] $ControlAt = ''           # comma-separated <sec>:probe:<ctrl>, <sec>:combo:<ctrl>:<item data>,
                                               # <sec>:cmd:<ctrl>:<command id>: steps on a dialog control found by
                                               # its id (so a translated title does not matter); the run's
                                               # controls array records each
        )
        $tag = '{0}-{1}' -f $Name, (Get-Date -Format 'HHmmss')
        $guestOut = "C:\mpc-test\out\$tag.json"
        $guestPng = "C:\mpc-test\out\$tag.png"

        # A fresh portable profile: an ini beside the exe puts the player in ini mode, and nothing of the last
        # case -- or of whoever used this guest before -- carries over. UpdaterAutoCheck must be present or
        # the first-run prompt blocks an unattended player; -NoUpdaterSetting leaves it out, for the case
        # that is about that prompt.
        $ini = [ordered]@{ UpdaterAutoCheck = 0; KeepHistory = 0; RememberFilePos = 0; Loop = 0; AllowMultipleInstances = 0; LogoFile = ''; ShowOSD = 0 }
        foreach ($k in $Settings.Keys) { $ini[$k] = $Settings[$k] }
        if ($NoUpdaterSetting) { $ini.Remove('UpdaterAutoCheck') }
        $iniText = "[Settings]`r`n" + (($ini.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`r`n") + "`r`n"
        foreach ($section in $IniSections.Keys) {
            $body = $IniSections[$section]
            $iniText += "`r`n[$section]`r`n" + (($body.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`r`n") + "`r`n"
        }
        $rendererJson = if ($Renderer.Count) { $Renderer | ConvertTo-Json -Compress } else { '' }

        # An empty Clip runs the player with no file on the command line: a case that needs the playlist
        # restored at startup must not have a command-line open replace it.
        $argumentLine = if ($Clip) { ('"C:\mpc-test\media\{0}" {1}' -f $Clip, $Switches).Trim() } else { $Switches.Trim() }
        # Each later command line carries quoted paths, and no quoting survives the hand-built task line: each goes
        # over as base64 of the UTF-8 string (nothing but [A-Za-z0-9+/=]), comma-joined, and the guest decodes them.
        # The web requests go the same way: their bodies hold ampersands and quotes.
        $secondEncoded = (@($SecondArgumentLine | Where-Object { $_ } | ForEach-Object { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($_)) })) -join ','
        $httpEncoded = (@($HttpAt | Where-Object { $_ } | ForEach-Object { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($_)) })) -join ','
        # The casts are parenthesised: in a command's argument list a bare [bool]$x is the string "[bool]False",
        # which is true on the other side.
        $guest = Invoke-Command -Session $session -ArgumentList $iniText, $PlugModes, $argumentLine, $guestOut, $guestPng, $CaptureAtSec, $CloseAtSec, ([bool]$KeepProfile), $consoleUser, $CloseKind, ([bool]$CloseWhenWindowAppears), $CloseRepeat, $RedirectStorm, ($RedirectFiles -join ','), $StormAtSec, $StormIntervalMs, $rendererJson, $secondEncoded, $SecondAtSec, $PostCommands, $ProbeAt, $httpEncoded, $HttpPort, $CloseDialogAt, $AcceptDialogAt, $ControlAt {
            param($iniText, $plugModes, $argumentLine, $out, $png, $captureAt, $closeAt, $keepProfile, $user, $closeKind, $closeOnWindow, $closeRepeat, $redirectStorm, $redirectFiles, $stormAtSec, $stormIntervalMs, $rendererJson, $secondEncoded, $secondAtSec, $postCommands, $probeAt, $httpAt, $httpPort, $closeDialogAt, $acceptDialogAt, $controlAt)
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
            # Digits, dots, colons, commas and the letters of "msg" only: survives the hand-built line with plain quoting.
            if ($postCommands) { $taskArgs += (' -PostCommands "{0}"' -f $postCommands) }
            if ($probeAt) { $taskArgs += (' -ProbeAt "{0}"' -f $probeAt) }
            if ($httpAt) { $taskArgs += " -HttpAt $httpAt -HttpPort $httpPort" }
            if ($closeDialogAt) { $taskArgs += (' -CloseDialogAt "{0}"' -f $closeDialogAt) }
            if ($acceptDialogAt) { $taskArgs += (' -AcceptDialogAt "{0}"' -f $acceptDialogAt) }
            if ($controlAt) { $taskArgs += (' -ControlAt "{0}"' -f $controlAt) }
            $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $taskArgs
            $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive
            Register-ScheduledTask -TaskName 'MpcPlaybackCase' -Action $action -Principal $principal -Force | Out-Null
            Start-ScheduledTask -TaskName 'MpcPlaybackCase'
            $taskStarted = Get-Date
            $deadline = $taskStarted.AddSeconds(90)
            while (-not (Test-Path $out) -and (Get-Date) -lt $deadline) {
                Start-Sleep -Seconds 2
            }
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

        # The bodies of the case's web requests, saved by the guest beside the result JSON as http-<n>.bin.
        $httpFiles = @()
        if ($HttpAt.Count -gt 0 -and $run.http) {
            foreach ($answer in @($run.http)) {
                if ($answer.file) {
                    $local = Join-Path $OutDir ('{0}.{1}' -f $Name, $answer.file)
                    Copy-Item -FromSession $session (Join-Path 'C:\mpc-test\out' $answer.file) $local -Force
                    $httpFiles += $local
                }
            }
        }

        # Files the control steps saved beside the result (the grip crops), named after it on the guest.
        foreach ($step in @($(if ($run.PSObject.Properties['controls']) { $run.controls }))) {
            if ($step.PSObject.Properties['file'] -and $step.file) {
                Copy-Item -FromSession $session (Join-Path 'C:\mpc-test\out' $step.file) (Join-Path $OutDir ($step.file -replace '^.*-grip-', "$Name-grip-")) -Force
            }
        }

        if ($guest.History) { Set-Content (Join-Path $OutDir "$Name.history.ini") $guest.History }
        if ($guest.Ini) { Set-Content (Join-Path $OutDir "$Name.ini") $guest.Ini }

        [pscustomobject]@{ Run = $run; Wav = $wav; Wavs = $wavs; Png = $png; Plug = $guest.Plug; History = $guest.History; Ini = $guest.Ini; HttpFiles = $httpFiles }
    }

    # One /slave API case: the profile is written exactly as for Invoke-PlayerCase, then
    # Run-ApiCase.guest.ps1 runs as the console user. The guest hosts a window the player
    # connects back to (started with /slave <hwnd>), sends the case's commands as WM_COPYDATA
    # at their times -- dwData the CMD_ code, lpData the UTF-16 payload, as src/MPCTestAPI does --
    # records every reply in order, and closes the player with CMD_CLOSEAPP. Commands is a list
    # of '<seconds>:<CMD name or number>:<payload>' (MpcApi.h names; the payload may be empty);
    # they ride base64 because quoting does not survive the hand-built task line. The asserting
    # below reads the recorded replies from the result JSON.
    function Invoke-ApiCase {
        param(
            [string] $Name,
            [string] $Clip,
            [string[]] $Commands = @(),
            [hashtable] $Settings = @{},
            [double] $CloseAtSec = 0          # zero: CMD_CLOSEAPP two seconds after the last command
        )
        $tag = '{0}-{1}' -f $Name, (Get-Date -Format 'HHmmss')
        $guestOut = "C:\mpc-test\out\$tag.json"

        # The same fresh portable profile as a player case; nothing of the last case carries over.
        $ini = [ordered]@{ UpdaterAutoCheck = 0; KeepHistory = 0; RememberFilePos = 0; Loop = 0; AllowMultipleInstances = 0; LogoFile = ''; ShowOSD = 0 }
        foreach ($k in $Settings.Keys) { $ini[$k] = $Settings[$k] }
        $iniText = "[Settings]`r`n" + (($ini.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`r`n") + "`r`n"

        $commandsEncoded = (@($Commands | Where-Object { $_ } | ForEach-Object { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($_)) })) -join ','

        $guest = Invoke-Command -Session $session -ArgumentList $iniText, $Clip, $commandsEncoded, $CloseAtSec, $guestOut, $consoleUser {
            param($iniText, $clip, $commandsEncoded, $closeAtSec, $out, $user)
            # The session is shared with the driver install scripts, which leave it on 'Stop'; a native tool
            # writing to stderr would then end the case instead of being a result.
            $ErrorActionPreference = 'Continue'
            Get-Process mpc-hc64 -ErrorAction SilentlyContinue | Stop-Process -Force
            Get-ChildItem 'C:\mpc-test\player' -Filter '*.ini' | ForEach-Object { [IO.File]::Delete($_.FullName) }
            [IO.File]::WriteAllText('C:\mpc-test\player\mpc-hc64.ini', $iniText, [Text.Encoding]::Unicode)

            $taskArgs = "-NoProfile -ExecutionPolicy Bypass -File C:\mpc-test\Run-ApiCase.guest.ps1 -Exe C:\mpc-test\player\mpc-hc64.exe -Clip `"C:\mpc-test\media\$clip`" -Out $out"
            if ($commandsEncoded) { $taskArgs += " -Commands $commandsEncoded" }
            if ($closeAtSec -gt 0) { $taskArgs += " -CloseAtSec $closeAtSec" }
            $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $taskArgs
            $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive
            Register-ScheduledTask -TaskName 'MpcApiCase' -Action $action -Principal $principal -Force | Out-Null
            Start-ScheduledTask -TaskName 'MpcApiCase'
            $deadline = (Get-Date).AddSeconds(90)
            while (-not (Test-Path $out) -and (Get-Date) -lt $deadline) {
                Start-Sleep -Seconds 2
            }
            Unregister-ScheduledTask -TaskName 'MpcApiCase' -Confirm:$false
            Get-Process mpc-hc64 -ErrorAction SilentlyContinue | Stop-Process -Force

            [pscustomobject]@{
                Json = if (Test-Path $out) { Get-Content $out -Raw } else { $null }
            }
        }
        if (-not $guest.Json) { throw "case $Name produced no result on the guest" }
        $run = $guest.Json | ConvertFrom-Json
        Set-Content (Join-Path $OutDir "$Name.guest.json") $guest.Json

        # The audio captures of the run, same window and copy-back as Invoke-PlayerCase: the mute
        # case reads the muted stretch off the WAV.
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

        [pscustomobject]@{ Run = $run; Wav = $wav; Wavs = $wavs }
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

    # The [Toolbars\PlayerToolBar] ini keys for a saved toolbar layout: ButtonSequence, the vector of
    # command ids as the player's ini binary encoding -- two chars 'A'..'P' per byte, low nibble first
    # (BinaryToAP in Profile.cpp, what WriteProfileBinary writes) -- over the little-endian int32 ids,
    # and ButtonSequenceSize its byte count. GetProfileVectorInt (mplayerc.cpp) reads the size first
    # and keeps the vector only when the binary decodes to exactly that many bytes, so the two must
    # agree. ButtonLayoutRevision, when a case wants one, is added on top as a plain integer.
    function Get-ButtonSequenceIni {
        param([int[]] $Ids)
        $text = [Text.StringBuilder]::new()
        foreach ($id in $Ids) {
            foreach ($byte in [BitConverter]::GetBytes($id)) {
                [void] $text.Append([char](65 + ($byte -band 0x0F)))
                [void] $text.Append([char](65 + (($byte -shr 4) -band 0x0F)))
            }
        }
        [ordered]@{ ButtonSequence = $text.ToString(); ButtonSequenceSize = 4 * $Ids.Count }
    }

    # A RECT (four little-endian int32s, left/top/right/bottom) in the same 'A'..'P'
    # ini binary encoding -- which is how [Settings] LastWindowRect is stored, so a
    # case can seed the player's window position and size (with RememberWindowPos and
    # RememberWindowSize on).
    function Get-RectIniBinary {
        param([int] $Left, [int] $Top, [int] $Right, [int] $Bottom)
        $text = [Text.StringBuilder]::new()
        foreach ($v in @($Left, $Top, $Right, $Bottom)) {
            foreach ($byte in [BitConverter]::GetBytes($v)) {
                [void] $text.Append([char](65 + ($byte -band 0x0F)))
                [void] $text.Append([char](65 + (($byte -shr 4) -band 0x0F)))
            }
        }
        $text.ToString()
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

    # The average RMS of a capture's non-silent windows (Get-ToneTimeline.ps1 reads one per
    # window; hz > 0 marks the non-silent ones), skipping the first and the last window where
    # the stream starts and stops. For the case that compares loudness between two runs.
    function Get-CaptureRms {
        param([string] $Wav)
        if (-not $Wav) { return $null }
        $windows = @(& (Join-Path $PSScriptRoot 'Get-ToneTimeline.ps1') -Wav $Wav | Where-Object { $_.hz -gt 0 })
        if ($windows.Count -lt 4) { return $null }
        $windows = $windows[1..($windows.Count - 2)]
        [double] ($windows | Measure-Object rms -Average).Average
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
        if ($Field.transfer -eq 'hlg') {
            # The fixed EVR-CP/Sync HLG-to-SDR pass (f185a85594, src/filters/renderer/VideoRenderers/
            # HLGToSDR.h): the inverse OETF, the 1.2 system gamma, the GAIN over REF_WHITE^gamma
            # scaling, a soft knee at 0.60, and gamma 2.0 back. A neutral field is unaffected by
            # the BT.2020->BT.709 matrix (its rows sum to 1), so the level is exact for a grey.
            $e = $signal
            if ($e -le 0.5) { $scene = $e * $e / 3.0 } else { $scene = ([math]::Exp(($e - 0.55991073) / 0.17883277) + 0.28466892) / 12.0 }
            $display = [math]::Pow($scene, 1.2)
            $sdr = $display * (0.57 / [math]::Pow(0.2640, 1.2))
            if ($sdr -gt 0.60) { $knee = $sdr - 0.60; $sdr = 0.60 + 0.40 * $knee / ($knee + 0.40) }
            return [math]::Round([math]::Pow([math]::Min([math]::Max($sdr, 0.0), 1.0), 0.5) * 255.0, 1)
        }
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

    # 21-23. The end of a file: what happens when playback runs out. These are the first cases that drive a
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

    # 24. The default flag outranks the forced flag: clsid2/mpc-hc@9b4408c5c8 swapped the weights in
    #    SetupAudioStreams, so [default] adds 4 and [forced] 2 (#3935). forced.mkv's track 1 is forced and
    #    track 2 is default; neither has a language, so no language preference can decide it instead. Like
    #    default-audio-track, what sounds must be the default track's tones.
    if (Test-CaseSelected 'forced-does-not-outrank-default') {
        $c = Invoke-PlayerCase -Name 'forced-does-not-outrank-default' -Clip 'forced.mkv'
        $default = @($clips.clips.'forced.mkv'.audio | Where-Object default)[0]
        Complete-Case 'forced-does-not-outrank-default' @(
            (Get-ProcessProblem $c.Run),
            (Test-Audio $c.Wav $default.tones $seconds)
        )
    }

    # 25-27. The playlist's list state, read from outside the player: the guest runner probes the playlist's
    #    list control at given times (item count, selection, scroll position, scrollbars) and the cases assert
    #    on what the list shows, not on what the player says. Where a case needs the playlist shown at start it
    #    sets [ToolBars\Playlist] Visible=1, the key CPlayerPlaylistBar::SaveState writes when the bar was
    #    visible at exit.

    # 25. Next/previous must move the playlist's selection with the playing item: clsid2/mpc-hc@b1741976ea
    #    (#3840, #3996). SetNext/SetPrev sync the list's selection to the new position only when the selection
    #    was on the item that was playing, so the case needs a known selection first. A multi-file command line
    #    is opened one file at a time (Open, then an Append per further file), and Append selects the first
    #    item it adds when the list was not empty, so three files leave the selection on the LAST entry while
    #    the first one plays. The skips at 3 s and 5 s walk the playing item onto that selection (probes at 4
    #    and 6 s: still 2, left behind, the pre-fix shape -- the sync condition is not met until playing and
    #    selection coincide); from 7 s on, selection and playing item must move together: back to 1, forward
    #    to 2, back to 1. On an unfixed player the selection never leaves 2.
    if (Test-CaseSelected 'playlist-selection-follows-skip') {
        $c = Invoke-PlayerCase -Name 'playlist-selection-follows-skip' -Clip 'list30\01.mkv' `
            -Switches '"C:\mpc-test\media\list30\02.mkv" "C:\mpc-test\media\list30\03.mkv" /play' `
            -Settings @{ LoopMode = 1 } -IniSections @{ 'ToolBars\Playlist' = @{ Visible = 1 } } `
            -PostCommands '3:922,5:922,7:921,9:922,11:921' -ProbeAt '4,6,8,10,12' -CloseAtSec 13
        $posts = @($c.Run.posts)
        $probes = @($c.Run.probes)
        $expected = @(2, 2, 1, 2, 1)
        $problems = @((Get-ProcessProblem $c.Run))
        if (@($posts | Where-Object delivered).Count -ne 5) { $problems += 'not every posted skip reached a window' }
        if ($probes.Count -ne 5 -or @($probes | Where-Object found).Count -ne 5) {
            $problems += 'the playlist list control was not found at every probe'
        } else {
            foreach ($pr in $probes) {
                if ($pr.count -ne 3) { $problems += "probe at $($pr.at)s: $($pr.count) playlist entries, expected 3" }
                if (-not $pr.visible) { $problems += "probe at $($pr.at)s: the playlist was not shown at start" }
            }
            for ($i = 0; $i -lt $expected.Count; $i++) {
                if ($probes[$i].selected -ne $expected[$i]) {
                    $problems += "probe at $($probes[$i].at)s: the selection is on entry $($probes[$i].selected), expected $($expected[$i]) (the playing item)"
                }
            }
        }
        Complete-Case 'playlist-selection-follows-skip' $problems
    }

    # 26. Showing a hidden playlist must scroll the playing entry fully into view: clsid2/mpc-hc@66d467b094
    #    (#4108, of #4094 and #3889). The hidden bar's list has zero height, and LVM_ENSUREVISIBLE
    #    bottom-aligned the current row into that zero height, leaving the scroll one row past it; the fix
    #    defers the scroll until the bar is shown. To start at the 20th of 30 entries without twenty posted
    #    skips (a skip lands only while the player reports LOADED, so they would have to sit seconds apart),
    #    the case opens list30.mpcpl with a saved playlist position: [PlaylistHistory\<hash>] Position=19,
    #    where the hash is the first 12 base64 characters of the SHA-1 of the lowercased UTF-16 path
    #    (getRFEHash in AppSettings.cpp). Append() then puts the playlist position on the saved entry, and
    #    MainFrm skips its usual SetFirst for a playlist file ("playlists already set first pos (or saved
    #    pos)"). LoopMode=0 (file) with AfterPlayback=0 keeps the player on entry 20 once the 4 s clip
    #    ends, so the probe at 5 s cannot race the advance to entry 21: at the default LoopMode=1
    #    (playlist) the end-of-stream code posts ID_NAVIGATE_SKIPFORWARDFILE before AfterPlayback is ever
    #    consulted. The playlist is shown at 4 s by
    #    posting ID_VIEW_PLAYLIST and probed 1 s later. The playing entry (index 19) must lie fully in view
    #    (perPage counts only fully visible rows), and the list must not be scrolled further than that needs:
    #    top no greater than max(0, 19 - perPage + 1). Being in view alone does not catch the bug when the
    #    whole list nearly fits -- 2.8.0 opened at top 2 with 28 rows showing, the "playlist appears from
    #    number 2" of #4094, where develop opens at top 0.
    if (Test-CaseSelected 'playlist-shows-current-after-hidden') {
        $plPath = 'C:\mpc-test\media\list30.mpcpl'
        $plHash = [Convert]::ToBase64String([Security.Cryptography.SHA1]::Create().ComputeHash([Text.Encoding]::Unicode.GetBytes($plPath.ToLower()))).Substring(0, 12)
        $c = Invoke-PlayerCase -Name 'playlist-shows-current-after-hidden' -Clip 'list30.mpcpl' -Switches '/play' `
            -Settings @{ KeepHistory = 1; AfterPlayback = 0; LoopMode = 0 } -IniSections @{ "PlaylistHistory\$plHash" = @{ Position = 19 } } `
            -PostCommands '4:824' -ProbeAt '5' -CloseAtSec 7
        $posts = @($c.Run.posts)
        $listState = @($c.Run.probes)[0]
        $problems = @((Get-ProcessProblem $c.Run))
        if (-not $posts -or -not $posts[0] -or -not $posts[0].delivered) { $problems += 'the posted show-playlist command did not reach a window' }
        if (-not $listState -or -not $listState.found) {
            $problems += 'the playlist list control was not found'
        } else {
            if ($listState.count -ne 30) { $problems += "$($listState.count) playlist entries, expected 30" }
            if (-not $listState.visible) { $problems += 'the playlist was not shown by ID_VIEW_PLAYLIST' }
            $last = $listState.top + $listState.perPage - 1
            if (19 -lt $listState.top -or 19 -gt $last) { $problems += "the playing entry (index 19) is not fully in view: top $($listState.top), fully visible through $last" }
            $maxTop = [math]::Max(0, 19 - $listState.perPage + 1)
            if ($listState.top -gt $maxTop) { $problems += "the list is scrolled to top $($listState.top), further than the playing entry needs (at most $maxTop with $($listState.perPage) rows showing)" }
        }
        Complete-Case 'playlist-shows-current-after-hidden' $problems
    }

    # 27. A playlist restored at startup must not grow a horizontal scrollbar: clsid2/mpc-hc@fbcb10020f
    #    (#3988, of #3972). LoadPlaylist adds the restored entries with the list's redraw off, and a list view
    #    does not lay out its scrollbars while redraw is off, so when ResizeListColumn sized the name column
    #    the client rect still reported the full width and the column ended a vertical scrollbar too wide. The
    #    repro needs the restore path itself -- a command-line open would replace the restored list -- so the
    #    player is launched with no file on the command line and default.mpcpl sits next to the exe (in ini
    #    mode the playlist save path is the exe's folder) with RememberPlaylistItems at its default on. The
    #    mpcpl is removed again after the case so no later launch restores it.
    if (Test-CaseSelected 'playlist-no-horizontal-scrollbar') {
        Invoke-Command -Session $session { Copy-Item 'C:\mpc-test\media\list30.mpcpl' 'C:\mpc-test\player\default.mpcpl' -Force }
        try {
            $c = Invoke-PlayerCase -Name 'playlist-no-horizontal-scrollbar' -Clip '' -Switches '' `
                -IniSections @{ 'ToolBars\Playlist' = @{ Visible = 1 } } -ProbeAt '3' -CloseAtSec 5
            $listState = @($c.Run.probes)[0]
            $problems = @((Get-ProcessProblem $c.Run))
            if (-not $c.Run.closeSent) { $problems += 'the close request did not reach a window' }
            if (-not $listState -or -not $listState.found) {
                $problems += 'the playlist list control was not found'
            } else {
                if ($listState.count -ne 30) { $problems += "$($listState.count) playlist entries restored, expected 30" }
                if (-not $listState.visible) { $problems += 'the playlist was not shown at start' }
                if (-not $listState.vscroll) { $problems += 'no vertical scrollbar on a 30-entry restored playlist' }
                if ($listState.hscroll) { $problems += 'a horizontal scrollbar appeared on the restored playlist' }
            }
            Complete-Case 'playlist-no-horizontal-scrollbar' $problems
        } finally {
            Invoke-Command -Session $session { Remove-Item 'C:\mpc-test\player\default.mpcpl' -Force -ErrorAction SilentlyContinue }
        }
    }

    # 28-30. The persisted toolbar layout, read back off the toolbar itself: every probe also records
    #    toolbarIds, the idCommand of each of the main toolbar's buttons in order (TB_BUTTONCOUNT and
    #    TB_GETBUTTON into a buffer in the player's address space). The layout a case seeds lives in
    #    [Toolbars\PlayerToolBar] (IDS_R_PLAYERTOOLBAR in SettingsDefines.h): ButtonSequence and
    #    ButtonSequenceSize from Get-ButtonSequenceIni, and ButtonLayoutRevision for revisions past 0.
    #    The command ids are the resource.h ones CPlayerToolBar's supportedSvgButtons lists:
    #    ID_LEFTSEPARATOR 957, ID_PLAY_PLAY 887, ID_PLAY_PAUSE 888, ID_PLAY_STOP 890,
    #    ID_NAVIGATE_SKIPBACK 921, ID_NAVIGATE_SKIPFORWARD 922, ID_PLAY_FRAMESTEP 891,
    #    ID_PLAY_DECRATE 894, ID_PLAY_INCRATE 895, ID_DUMMYSEPARATOR 945, ID_VOLUME_MUTE 909. The clip
    #    only keeps the player alive while the probe runs; what is asserted is the toolbar.

    # 28. A saved layout with a duplicated button must be discarded, not loaded as is:
    #    clsid2/mpc-hc@a0968dc305 (#3839, of #3829 -- a layout that named Stop twice put two Stop
    #    buttons on the toolbar). The seeded revision-1 sequence is valid but for the second Stop;
    #    IsValidButtonLayout's duplicate check rejects it and PlaceButtons takes its else branch, the
    #    defaults: play, pause, stop, skipback, decrate, incrate, skipforward, framestep between the
    #    separators and the volume button. On an unfixed player the layout loads as it stands and the
    #    probe sees Stop twice.
    if (Test-CaseSelected 'toolbar-layout-with-duplicates-is-discarded') {
        $layout = Get-ButtonSequenceIni @(957, 887, 888, 890, 890, 945, 909)
        $layout.ButtonLayoutRevision = 1
        $c = Invoke-PlayerCase -Name 'toolbar-layout-with-duplicates-is-discarded' -Clip 'stereo.mkv' `
            -IniSections @{ 'Toolbars\PlayerToolBar' = $layout } -ProbeAt '2'
        $tbProbe = @($c.Run.probes)[0]
        $problems = @((Get-ProcessProblem $c.Run))
        if (-not $tbProbe -or $null -eq $tbProbe.toolbarIds) {
            $problems += 'the player toolbar was not found'
        } else {
            $ids = @($tbProbe.toolbarIds)
            $nonSeparator = @($ids | Where-Object { $_ -ne 957 -and $_ -ne 945 })   # separators repeat legitimately
            $duplicates = @($nonSeparator | Group-Object | Where-Object { $_.Count -gt 1 })
            if ($duplicates) { $problems += "duplicate button(s) on the toolbar: $(($duplicates | ForEach-Object Name) -join ', ') ($($ids -join ','))" }
            foreach ($want in @(887, 888, 890, 921, 894, 895, 922, 891)) {
                if ($ids -notcontains $want) { $problems += "default button $want is missing from the toolbar ($($ids -join ','))" }
            }
        }
        Complete-Case 'toolbar-layout-with-duplicates-is-discarded' $problems
    }

    # 29. A revision-1 layout the user removed every movable button from must be honoured, not reset:
    #    clsid2/mpc-hc@90d2b12d68 (#4220 -- the saved sequence of such a layout is only leftsep,
    #    dummysep, volume, which failed IsValidButtonLayout's old minimum of six entries and was
    #    thrown away for the defaults). The minimum is now three entries with the movable part empty,
    #    so the toolbar must come up as exactly the two separators and the volume button: no play,
    #    pause or stop anywhere in it.
    if (Test-CaseSelected 'toolbar-layout-without-movable-buttons-is-kept') {
        $layout = Get-ButtonSequenceIni @(957, 945, 909)
        $layout.ButtonLayoutRevision = 1
        $c = Invoke-PlayerCase -Name 'toolbar-layout-without-movable-buttons-is-kept' -Clip 'stereo.mkv' `
            -IniSections @{ 'Toolbars\PlayerToolBar' = $layout } -ProbeAt '2'
        $tbProbe = @($c.Run.probes)[0]
        $problems = @((Get-ProcessProblem $c.Run))
        if (-not $tbProbe -or $null -eq $tbProbe.toolbarIds) {
            $problems += 'the player toolbar was not found'
        } else {
            $ids = @($tbProbe.toolbarIds)
            foreach ($removed in @(887, 888, 890)) {
                if ($ids -contains $removed) { $problems += "button $removed is on the toolbar; the user's empty layout was not honoured ($($ids -join ','))" }
            }
        }
        Complete-Case 'toolbar-layout-without-movable-buttons-is-kept' $problems
    }

    # 30. A layout saved before ButtonLayoutRevision existed must not show a button twice, and must keep
    #    its order: #3829, two Stop buttons. The sequence is byte for byte what 2.5.5 itself saves for this
    #    order (measured: it reads the seed and writes it back unchanged): leftsep, play, pause, stop,
    #    skipforward, framestep, skipback, dummysep, volume, with no revision key. Revision 0 saved
    #    play/pause/stop after the left separator, so the movable part starts at index 4, but
    #    IsValidButtonLayout and PlaceButtons started at 3: 2.6.1 and 2.6.4 show Stop twice from it, and
    #    after #3839 (a0968dc305) the saved Stop counts as a duplicate, the layout is discarded and the
    #    defaults load instead (skipback, decrate, incrate, skipforward, framestep). Fixed by e650c468a6 (#4296).
    if (Test-CaseSelected 'toolbar-old-layout-has-no-duplicates') {
        $layout = Get-ButtonSequenceIni @(957, 887, 888, 890, 922, 891, 921, 945, 909)
        $c = Invoke-PlayerCase -Name 'toolbar-old-layout-has-no-duplicates' -Clip 'stereo.mkv' `
            -IniSections @{ 'Toolbars\PlayerToolBar' = $layout } -ProbeAt '2'
        $tbProbe = @($c.Run.probes)[0]
        $problems = @((Get-ProcessProblem $c.Run))
        if (-not $tbProbe -or $null -eq $tbProbe.toolbarIds) {
            $problems += 'the player toolbar was not found'
        } else {
            $ids = @($tbProbe.toolbarIds)
            foreach ($id in @(887, 888, 890)) {
                $n = @($ids | Where-Object { $_ -eq $id }).Count
                if ($n -ne 1) { $problems += "button $id is on the toolbar $n times, expected once ($($ids -join ','))" }
            }
            $buttonsInOrder = @($ids | Where-Object { $_ -ne 957 -and $_ -ne 945 }) -join ','
            $saved = '887,888,890,922,891,921,909'
            if ($buttonsInOrder -ne $saved) { $problems += "the saved layout was not kept: buttons $buttonsInOrder, saved $saved ($($ids -join ','))" }
        }
        Complete-Case 'toolbar-old-layout-has-no-duplicates' $problems
    }

    # 31-35. The web interface: the profile turns it on (EnableWebServer, WebServerPort,
    #    WebServerLocalhostOnly -- checked against SettingsDefines.h) and the guest talks to it
    #    over plain HTTP on 127.0.0.1 (the server binds IPv4 only, so never "localhost"). The
    #    requests ride in the same time-ordered sequence as posted commands; answers land in the
    #    run's http array with their bodies copied back as <case>.http-<n>.bin.
    $web = @{ EnableWebServer = 1; WebServerPort = 13579; WebServerLocalhostOnly = 1 }

    # 31. A web command that opens a modal dialog must not freeze the web server:
    #    clsid2/mpc-hc@a77c59b537 (#4053) -- OnCommand dispatched with a synchronous SendMessage,
    #    and wm_command=815 (ID_VIEW_OPTIONS) opens the modal Options dialog, so the web thread
    #    stayed stuck behind it until someone dismissed the dialog at the player; the fix
    #    dispatches with SendMessageTimeout (5000 ms) instead, so a request holds the web thread
    #    for at most 5 s. The guest makes its requests one after another, so the POST at 3 s
    #    that opens Options holds it for about 5 s (its own 5 s timeout and the server's 5 s
    #    bound race, and the POST's status is not asserted) and the GET scheduled at 4 s is
    #    really sent at about 8 s, with Options still open. Fixed, the web thread is free by
    #    then and the GET answers 200 well within 3000 ms; unfixed it is still stuck behind the
    #    modal, and the GET times out with status 0. The dialog close at 6 s (a modal left open
    #    can leave the player's own WM_CLOSE unanswered) and the player close at 8 s are overdue
    #    by then and happen right after the GET.
    if (Test-CaseSelected 'web-modal-command-does-not-freeze') {
        $c = Invoke-PlayerCase -Name 'web-modal-command-does-not-freeze' -Clip 'long.mkv' -Switches '/play' `
            -Settings $web -CloseAtSec 8 `
            -HttpAt '3|POST|/command.html|wm_command=815', '4|GET|/variables.html|' `
            -CloseDialogAt '6:Options'
        $answers = @($c.Run.http)
        $closes = @($c.Run.dialogCloses)
        $behind = if ($answers.Count -ge 2) { $answers[1] } else { $null }
        $problems = @((Get-ProcessProblem $c.Run))
        if (-not $c.Run.closeSent) { $problems += 'the close request did not reach a window' }
        if (-not $closes -or -not $closes[0].delivered) { $problems += 'the Options dialog was not found to close (did the command open it?)' }
        if (-not $behind) {
            $problems += 'the request behind the modal command was never made'
        } else {
            if ($behind.status -ne 200) { $problems += "the request behind the modal command got status $($behind.status), expected 200" }
            if ($behind.ms -gt 3000) { $problems += "the request behind the modal command took $($behind.ms) ms, expected at most 3000" }
        }
        Complete-Case 'web-modal-command-does-not-freeze' $problems
    }

    # 32. A playlist click in the web remote must open the playlist entry, not a chapter:
    #    clsid2/mpc-hc@4802b44e4b (#4093, of #4078) -- the remote sent the entry's
    #    ID_NAVIGATE_JUMPTO_SUBITEM_START + index id as a plain wm_command, which on chaptered
    #    media the player reads as a chapter jump. The fixed remote.html sends
    #    wm_command=-3&index=<n> (CMD_SETPLAYLISTINDEX), which SetSelIdx + posted
    #    WM_MPC_OPENCURPLAYLIST turn into an open of that entry. chapters.mkv (three chapters)
    #    and twotracks.mkv on the command line are a two-entry playlist; the click on entry 2
    #    (index 1) at 3 s must open twotracks.mkv: a second capture sounding its default track's
    #    1200 Hz. On the unfixed player nothing opens (the id means nothing without the fix), so
    #    only chapters.mkv's 12 s are heard. LoopMode=0 keeps the player from advancing by itself
    #    once twotracks.mkv ends; the window is closed at 9 s.
    if (Test-CaseSelected 'web-playlist-click-with-chapters') {
        $c = Invoke-PlayerCase -Name 'web-playlist-click-with-chapters' `
            -Clip 'chapters.mkv' -Switches '"C:\mpc-test\media\twotracks.mkv" /play' `
            -Settings ($web + @{ LoopMode = 0 }) -CloseAtSec 9 `
            -HttpAt '3|POST|/command.html|wm_command=-3&index=1'
        $second = @($clips.clips.'twotracks.mkv'.audio | Where-Object default)[0]
        $answers = @($c.Run.http)
        $problems = @((Get-ProcessProblem $c.Run))
        if (-not $c.Run.closeSent) { $problems += 'the close request did not reach a window' }
        if (-not $answers -or $answers[0].status -ne 200) { $problems += "the playlist-click command got status $(if ($answers) { $answers[0].status } else { 'none' }), expected 200" }
        if ($c.Wavs.Count -ne 2) { $problems += "$($c.Wavs.Count) audio stream(s) reached the endpoint, expected 2 (chapters.mkv, then the clicked entry)" }
        else { $problems += (Test-Audio $c.Wavs[1] $second.tones $seconds 1.0) }
        Complete-Case 'web-playlist-click-with-chapters' $problems
    }

    # 33. The JSON endpoints must escape what they quote: clsid2/mpc-hc@a77c59b537 (#4053) added
    #    /status.json with JSONString/JSONEscape doing the quoting. The clip is a copy of
    #    stereo.mkv in a folder "json test" whose name holds an apostrophe, a U+00FC, a U+00EF
    #    and an ampersand (built from char codes so this file stays ASCII), and the path back
    #    through the guest is all base64. The "path" field (m_wndPlaylistBar.GetCurFileName())
    #    must parse and equal the real path exactly.
    if (Test-CaseSelected 'web-status-json-escapes-paths') {
        $jsonClip = "json test\it's " + [char]0x00FC + "n" + [char]0x00EF + "code & co.mkv"
        $c = Invoke-PlayerCase -Name 'web-status-json-escapes-paths' -Clip $jsonClip -Settings $web -HttpAt '2.5|GET|/status.json|'
        $answers = @($c.Run.http)
        $problems = @((Get-ProcessProblem $c.Run))
        if (-not $answers -or $answers[0].status -ne 200) {
            $problems += "the status request got status $(if ($answers) { $answers[0].status } else { 'none' }), expected 200"
        } else {
            $status = $null
            try { $status = $answers[0].bodyText | ConvertFrom-Json } catch { }
            if (-not $status) {
                $problems += 'the /status.json body did not parse as JSON'
            } else {
                $want = 'C:\mpc-test\media\' + $jsonClip
                if ($status.path -cne $want) { $problems += "the path field is '$($status.path)', expected exactly '$want'" }
            }
        }
        Complete-Case 'web-status-json-escapes-paths' $problems
    }

    # 34. A filter that keeps matching files out of the history: clsid2/mpc-hc@f310dc2461
    #    (#3987, of #3985, #3920 and #4196). HistoryExcludeFilter is semicolon-separated
    #    substrings, matched case-insensitively against the file's full path
    #    (MatchesHistoryExcludeFilter in AppSettings.cpp); a match is kept out of the recent
    #    files list, the resume positions and the Windows recent documents. SECRET-clip.mkv is
    #    a stereo.mkv copy made on the guest at deploy time, so its path contains "secret".
    #    Two runs on one profile: the matching clip must leave no entry in the history, and
    #    stereo.mkv under the same filter must be recorded, so the case cannot pass on a player
    #    that records nothing. The history is mpc-hc64.history.ini since #3979 (2.8.0) and the
    #    main ini before it, so both are read.
    if (Test-CaseSelected 'history-exclude-filter') {
        $historySettings = @{ KeepHistory = 1; RememberFilePos = 1; RememberPosForLongerThan = 0; HistoryExcludeFilter = 'secret' }
        $a = Invoke-PlayerCase -Name 'history-exclude-filter' -Clip 'SECRET-clip.mkv' -Settings $historySettings
        $b = Invoke-PlayerCase -Name 'history-exclude-filter-control' -Clip 'stereo.mkv' -Settings $historySettings -KeepProfile
        $problems = @((Get-ProcessProblem $a.Run), (Get-ProcessProblem $b.Run))
        $historyA = "$($a.History)`r`n$($a.Ini)"
        $historyB = "$($b.History)`r`n$($b.Ini)"
        if ($historyA -match 'SECRET-clip\.mkv') { $problems += 'the filtered clip is in the history after its own run' }
        if ($historyB -match 'SECRET-clip\.mkv') { $problems += 'the history names SECRET-clip.mkv although HistoryExcludeFilter=secret matches its path' }
        if ($historyB -notmatch 'stereo\.mkv') { $problems += 'stereo.mkv is not in the history although the filter does not match it' }
        Complete-Case 'history-exclude-filter' $problems
    }

    # 35. Closing the player while the first-run "check for updates?" prompt is up must not crash on
    #    exit: clsid2/mpc-hc@92583276c5 (#3989). UpdateChecker::IsAutoUpdateEnabled raises the prompt
    #    -- a modal AfxMessageBox, MB_YESNO, titled with the app name (mpc-hc64, there being no
    #    AFX_IDS_APP_TITLE resource) -- from InitInstance, after the main frame is created and shown,
    #    and only when the profile has no UpdaterAutoCheck, hence -NoUpdaterSetting. Because the box is
    #    modal it pumps messages, so the WM_CLOSE posted to the frame at 3 s is dispatched while
    #    InitInstance is still inside the box: the frame is destroyed and MFC clears m_pMainWnd.
    #    The close goes as a raw message through -PostCommands because the runner's own -CloseAtSec
    #    close runs only after the whole timed-event block, i.e. after the prompt was already
    #    dismissed: a normal close that passes on the unfixed player too. Dismissing the prompt at
    #    6 s (its modal loop ends on its own when the destroyed main window posts quit, so the close
    #    is a backstop that may find no window, and nothing is asserted on it) hands control back to
    #    InitInstance, which before the fix went straight to SendCommandLine(m_pMainWnd->m_hWnd) and
    #    dereferenced the null m_pMainWnd -- 0xC0000005 on exit. Fixed, it returns FALSE, and
    #    ExitInstance still saves the settings, so the prompt's answer (cancel, AUTOUPDATE_DISABLE) is
    #    written. The ini check is what ties the pass to the prompt: a run in which the prompt never
    #    appeared exits 0 too, but writes -1 (AUTOUPDATE_UNKNOWN).
    if (Test-CaseSelected 'close-during-first-run-prompt') {
        $c = Invoke-PlayerCase -Name 'close-during-first-run-prompt' -Clip '' -Switches '' `
            -NoUpdaterSetting -PostCommands '3:msg:16:0' -CloseDialogAt '6:mpc-hc64'
        $updater = Get-IniValue $c.Ini 'Settings' 'UpdaterAutoCheck'
        Complete-Case 'close-during-first-run-prompt' @(
            (Get-ProcessProblem $c.Run),
            $(if (-not $c.Run.posts[0].delivered) { 'the WM_CLOSE posted at 3 s did not reach the player window' }),
            $(if ($updater -ne '0') { "UpdaterAutoCheck came back as $updater, expected 0: the first-run prompt did not appear, or was never answered" })
        )
    }

    # 36. A headless /thumbnails run must report its failures to the caller, not to a message box:
    #    clsid2/mpc-hc@40de2ddea8 (#4234, of issue #4228 -- /thumbnails on a missing source or an
    #    unwritable output raised a modal and hung forever, there being nobody to dismiss it). The
    #    commit latches CLSW_THUMBNAILS as headless (DoMessageBox answers as if cancelled and reports
    #    the text on stderr), and the failure paths -- the open-failed one (OnOpenMediaFailed) and the
    #    empty-playlist one (OpenCurPlaylistItem) -- report the reason, post WM_CLOSE and exit with
    #    m_nExitCode 1. The first run's source does not exist, so it must exit by itself with 1. The
    #    second is the control: stereo.mkv's sheet is written beside the clip as stereo.mkv_thumbs.jpg
    #    (MakeSnapshotFileName; bSnapShotKeepVideoExtension defaults on) and the run exits 0, so the
    #    case cannot pass on a player that fails everything. Get-ProcessProblem would call the 1 a
    #    failure, so the exit codes are asserted directly. The runner kills the process on a timeout,
    #    so even an unfixed player leaves no modal behind.
    if (Test-CaseSelected 'thumbnails-errors-exit-nonzero') {
        $a = Invoke-PlayerCase -Name 'thumbnails-missing-source' -Clip 'does-not-exist.mkv' -Switches '/thumbnails /minimized'
        $b = Invoke-PlayerCase -Name 'thumbnails-control' -Clip 'stereo.mkv' -Switches '/thumbnails /minimized'
        $thumbsWritten = Invoke-Command -Session $session {
            $f = 'C:\mpc-test\media\stereo.mkv_thumbs.jpg'
            $written = (Test-Path $f) -and ((Get-Item $f).Length -gt 0)
            Remove-Item $f -Force -ErrorAction SilentlyContinue
            $written
        }
        $problems = @()
        if ($a.Run.timedOut) { $problems += 'the missing-source run did not exit by itself (the pre-fix hang: a message box nobody can dismiss)' }
        elseif ($a.Run.exitCode -ne 1) { $problems += "the missing-source run exited with code $($a.Run.exitCode), expected 1" }
        if ($b.Run.timedOut) { $problems += 'the control run did not exit by itself' }
        elseif ($b.Run.exitCode -ne 0) { $problems += "the control run exited with code $($b.Run.exitCode), expected 0" }
        if (-not $thumbsWritten) { $problems += 'the control run left no stereo.mkv_thumbs.jpg beside the clip' }
        Complete-Case 'thumbnails-errors-exit-nonzero' $problems
    }

    # A favorite with an A-B range, opened while another file is playing, must loop its range.
    # Closing the playing file cleared the range before the favorite opened, and the call that
    # should have carried it passed it as the bool reopen argument. The favorite still started at
    # mark A, but played on from there to the end. Opened with no file loaded it always worked,
    # which is why stereo.mkv plays first.
    # steps.mkv's segment 5 (10-12 s) is 800 Hz. Looped, the favorite plays 800 Hz more than once
    # through (8 windows) and never reaches 1000 Hz. 900 Hz is allowed: a busy guest can run up to
    # a second past B before the loop seeks back. Unfixed, it is 800 Hz once, then 900-1200 Hz.
    if (Test-CaseSelected 'favorite-restores-its-own-ab-range') {
        $steps = 'C:\mpc-test\media\steps.mkv'
        $favs = [ordered]@{
            Name0 = "Steps two to four;0:20000000:40000000;0;$steps"
            Name1 = "Steps ten to twelve;0:100000000:120000000;0;$steps"
        }
        $c = Invoke-PlayerCase -Name 'favorite-restores-its-own-ab-range' -Clip 'stereo.mkv' -Switches '/play' `
            -IniSections @{ 'Favorites' = @{ RememberABMarks = 1 }; 'Favorites\Files' = $favs } `
            -PostCommands '3:2801' -CloseAtSec 13
        $posts = @($c.Run.posts)
        $problems = @((Get-ProcessProblem $c.Run))
        # The favorite's capture is the largest, about 10 s against stereo.mkv's 3 s. Not the last: the
        # split varies, stereo.mkv sometimes has no capture of its own and the close can leave a tiny
        # one after the favorite's. Read against steps.mkv's tones, stereo.mkv's 440/880 Hz come out
        # as 300-600 Hz, which looks like steps.mkv from its start.
        if (-not $posts -or -not $posts[0] -or -not $posts[0].delivered) { $problems += 'the posted favorite command did not reach a window' }
        elseif (-not $c.Wav) { $problems += 'no audio reached the endpoint for the favorite' }
        else {
            $heard = @(& (Join-Path $PSScriptRoot 'Get-ToneTimeline.ps1') -Wav $c.Wav | Where-Object { $_.hz -gt 0 })
            $byHz = ($heard | Group-Object hz | ForEach-Object { "$($_.Name) Hz x$($_.Count)" }) -join ', '
            $inRange = @($heard | Where-Object { $_.hz -eq 800 }).Count
            $past = @($heard | Where-Object { $_.hz -ge 1000 }).Count
            $before = @($heard | Where-Object { $_.hz -lt 800 }).Count
            if ($heard.Count -eq 0) { $problems += 'the favorite played nothing' }
            elseif ($before) { $problems += "the favorite played before mark A ($byHz)" }
            elseif ($past) { $problems += "the favorite played on past mark B instead of looping ($byHz)" }
            elseif ($inRange -le 8) { $problems += "the favorite's 10-12 s range did not repeat ($byHz)" }
        }
        Complete-Case 'favorite-restores-its-own-ab-range' $problems
    }

    # 36. The same as 30 for a layout saved before the left separator existed (2.5.2 to 2.5.4, before 750b3d2bfc):
    #    play, pause, stop, skipforward, framestep, skipback, dummysep, volume, no revision key. Byte for
    #    byte what 2.5.4 itself saves (measured: seeded with an unknown id among the buttons, its customize
    #    dialog opened and closed, it wrote this back without the unknown id). Here the movable part starts
    #    at index 3, not 4. develop already reads this one right; the case guards the fix for case 30, where
    #    starting every revision-0 layout at 4 would drop skipforward from this one.
    if (Test-CaseSelected 'toolbar-older-layout-keeps-its-order') {
        $layout = Get-ButtonSequenceIni @(887, 888, 890, 922, 891, 921, 945, 909)
        $c = Invoke-PlayerCase -Name 'toolbar-older-layout-keeps-its-order' -Clip 'stereo.mkv' `
            -IniSections @{ 'Toolbars\PlayerToolBar' = $layout } -ProbeAt '2'
        $tbProbe = @($c.Run.probes)[0]
        $problems = @((Get-ProcessProblem $c.Run))
        if (-not $tbProbe -or $null -eq $tbProbe.toolbarIds) {
            $problems += 'the player toolbar was not found'
        } else {
            $ids = @($tbProbe.toolbarIds)
            $buttonsInOrder = @($ids | Where-Object { $_ -ne 957 -and $_ -ne 945 }) -join ','
            $saved = '887,888,890,922,891,921,909'
            if ($buttonsInOrder -ne $saved) { $problems += "the saved layout was not kept: buttons $buttonsInOrder, saved $saved ($($ids -join ','))" }
        }
        Complete-Case 'toolbar-older-layout-keeps-its-order' $problems
    }

    # A profile without SecondarySubVerPos must default the secondary subtitle's vertical
    # position to 8, the constructor's value: LoadSettings read the key with a GetProfileInt
    # fallback of 0 while the out-of-range fallback and the constructor used 8, so a profile
    # missing the key put the secondary subtitle at the very top. clsid2/mpc-hc@51937d1eee
    # (#4299). The case's ini never carries the key, and the player's own shutdown writes the
    # settings back, so the saved ini holds what LoadSettings made of it.
    if (Test-CaseSelected 'secondary-sub-position-defaults-to-8') {
        $c = Invoke-PlayerCase -Name 'secondary-sub-position-defaults-to-8' -Clip 'stereo.mkv'
        $verPos = Get-IniValue $c.Ini 'Settings' 'SecondarySubVerPos'
        Complete-Case 'secondary-sub-position-defaults-to-8' @(
            (Get-ProcessProblem $c.Run),
            $(if ($verPos -ne '8') { "the saved profile's SecondarySubVerPos is $verPos, expected 8 (the default for a profile without the key)" })
        )
    }

    # 37. A floating playlist must be restored when leaving fullscreen, even with windowed
    #    controls on autohide: clsid2/mpc-hc@5f9e5d66df (#4083). On leaving fullscreen the
    #    autohide path (SetHiddenDueToFullscreen(false, true)) only knows dock zones, so a
    #    floating bar handed to it stays hidden; the fix restores a floating bar right away.
    #    The seed floats the bar: [ToolBars\Playlist] DockState=59423 (AFX_IDW_DOCKBAR_FLOAT,
    #    CPlayerBar::LoadState) with Visible=1 (CPlayerPlaylistBar::SaveState's key).
    #    HidePlaylistFullScreen and HideWindowedControls are the settings the fix's condition
    #    reads. Fullscreen on and off are posted at 4 and 7 s; the probes after must find the
    #    playlist's list view visible again. Unfixed 2.8.0: the bar stays hidden after leaving
    #    fullscreen. The 3 s probe guards the seed: the bar must be visible then. The toggles land
    #    on a clip that is still playing: on the 4 s stereo.mkv the second toggle could land after the
    #    end, where ID_VIEW_FULLSCREEN does nothing, and the player stayed fullscreen; long.mkv runs
    #    20 s. A run whose window is still fullscreen after the second toggle says so instead of
    #    blaming the bar.
    if (Test-CaseSelected 'floating-playlist-restored-after-fullscreen') {
        $c = Invoke-PlayerCase -Name 'floating-playlist-restored-after-fullscreen' -Clip 'long.mkv' -Switches '/play' `
            -Settings @{ HideWindowedControls = 1; HidePlaylistFullScreen = 1 } `
            -IniSections @{ 'ToolBars\Playlist' = @{ Visible = 1; DockState = 59423 } } `
            -PostCommands '4:830,7:830' -ProbeAt '3,8.5,11,14' -CloseAtSec 15
        $posts = @($c.Run.posts)
        $probes = @($c.Run.probes)
        $problems = @((Get-ProcessProblem $c.Run))
        if (@($posts | Where-Object delivered).Count -ne 2) { $problems += 'not every posted fullscreen toggle reached a window' }
        if ($probes.Count -ne 4 -or @($probes | Where-Object found).Count -ne 4) {
            $problems += 'the playlist list control was not found at every probe'
        } else {
            if (-not $probes[0].visible) { $problems += 'the seeded floating playlist was not visible before fullscreen' }
            $after = $probes[-1].mainRect; $wa = $probes[-1].workArea
            if ($after.left -le $wa.left -and $after.top -le $wa.top -and $after.right -ge $wa.right -and $after.bottom -gt $wa.bottom) {
                $problems += "the player was still fullscreen at 14 s (window $($after.left),$($after.top),$($after.right),$($after.bottom)): a fullscreen toggle did not take effect, so the case proves nothing about the bar"
            } elseif (-not $probes[-1].visible) { $problems += "the floating playlist was not restored after leaving fullscreen (visible at 8.5/11/14 s: $(@($probes[1..3] | ForEach-Object { [bool]$_.visible }) -join '/'))" }
        }
        Complete-Case 'floating-playlist-restored-after-fullscreen' $problems
    }

    # 38. Zoom +/- must keep the window inside the work area, must maximise when the zoom
    #    fills it, and must do nothing on an audio-only file showing the logo:
    #    clsid2/mpc-hc@a9d0cf671b (#3826). Two runs. The logo run plays dub.wav and posts
    #    ID_VIEW_ZOOM_ADD (33457) three times: after the fix each is a no-op and the probed
    #    window rect does not move; 2.6.4 zooms the logo's window by 2% of the work area per
    #    press. The fill run seeds the window (LastWindowRect, RememberWindowPos/Size on,
    #    AutoZoom off so the open does not resize it) at the player's idea of a full work
    #    area: the work area probed in the logo run, inflated by the invisible borders the
    #    same probe read off the window (the player's GetWorkAreaRect inflates by exactly
    #    that, so the seed is its maxRect, 4 px wider per side to be past any rounding).
    #    One zoom-in then ends at newRect == maxRect and the fix's step 5 maximises. On
    #    2.6.4 the zoom grows the window past the work area (the old default rect was never
    #    clamped) or, if Windows clamps the move, fills it without maximising -- either way
    #    one of the two asserts fails.
    if (Test-CaseSelected 'zoom-stays-in-work-area') {
        $problems = @()
        $a = Invoke-PlayerCase -Name 'zoom-stays-in-work-area-logo' -Clip 'dub.wav' -Switches '/play' `
            -PostCommands '3:33457,3.6:33457,4.2:33457' -ProbeAt '2,5.5' -CloseAtSec 7
        $logoProbes = @($a.Run.probes)
        $problems += (Get-ProcessProblem $a.Run)
        if (@($a.Run.posts | Where-Object delivered).Count -ne 3) { $problems += 'not every posted zoom reached a window' }
        if ($logoProbes.Count -ne 2 -or -not $logoProbes[0].mainRect -or -not $logoProbes[1].mainRect) {
            $problems += 'the main window rect was not probed at both times'
        } else {
            foreach ($edge in 'left', 'top', 'right', 'bottom') {
                $moved = [math]::Abs($logoProbes[0].mainRect.$edge - $logoProbes[1].mainRect.$edge)
                if ($moved -gt 2) { $problems += "zooming the logo moved the window's $edge edge by $moved px (a no-op was expected)" }
            }
        }
        $wa = $logoProbes[0].workArea; $mr = $logoProbes[0].mainRect; $fr = $logoProbes[0].frameRect
        if (-not $wa -or -not $mr -or -not $fr) {
            $problems += 'no work area or frame bounds from the logo run to seed the fill run from'
        } else {
            # The invisible borders as the probe read them, then the seed rect: the work area
            # inflated by the borders (the player's maxRect) plus 4 px per side.
            $bL = $fr.left - $mr.left; $bT = $fr.top - $mr.top; $bR = $mr.right - $fr.right; $bB = $mr.bottom - $fr.bottom
            $seedRect = [ordered]@{ left = $wa.left - $bL - 4; top = $wa.top - $bT - 4; right = $wa.right + $bR + 4; bottom = $wa.bottom + $bB + 4 }
            $seed = Get-RectIniBinary $seedRect.left $seedRect.top $seedRect.right $seedRect.bottom
            $b = Invoke-PlayerCase -Name 'zoom-stays-in-work-area-fill' -Clip 'stereo.mkv' -Switches '/play' `
                -Settings @{ RememberWindowPos = 1; RememberWindowSize = 1; AutoZoom = 0; LastWindowRect = $seed } `
                -PostCommands '3:33457' -ProbeAt '2,4.5' -CloseAtSec 6.5
            $fillProbes = @($b.Run.probes)
            $fillPosts = @($b.Run.posts)
            $problems += (Get-ProcessProblem $b.Run)
            if (-not $fillPosts -or -not $fillPosts[0] -or -not $fillPosts[0].delivered) { $problems += 'the posted zoom-in did not reach a window' }
            if ($fillProbes.Count -ne 2 -or -not $fillProbes[0].mainRect -or -not $fillProbes[1].mainRect) {
                $problems += 'the main window rect was not probed at both times'
            } else {
                foreach ($edge in 'left', 'top', 'right', 'bottom') {
                    $off = [math]::Abs($fillProbes[0].mainRect.$edge - $seedRect.$edge)
                    if ($off -gt 10) { $problems += "the seeded window's $edge edge is at $($fillProbes[0].mainRect.$edge), seeded $($seedRect.$edge): the seed did not land" }
                }
                $p = $fillProbes[1]
                if ($p.mainRect.left -lt $wa.left - 16 -or $p.mainRect.top -lt $wa.top - 16 -or $p.mainRect.right -gt $wa.right + 16 -or $p.mainRect.bottom -gt $wa.bottom + 16) {
                    $problems += "after zoom-in the window ($($p.mainRect.left),$($p.mainRect.top),$($p.mainRect.right),$($p.mainRect.bottom)) is outside the work area ($($wa.left),$($wa.top),$($wa.right),$($wa.bottom))"
                }
                if (-not $p.maximized) { $problems += 'the zoom that fills the work area did not maximise the window' }
            }
        }
        Complete-Case 'zoom-stays-in-work-area' $problems
    }

    # The RAR case needs a fixture the generator builds only when rar.exe is on the host.
    $rarCases = @('rar-skip-within-archive')
    $rarReady = Test-Path (Join-Path $media 'two-entry.rar')
    if (-not $rarReady) {
        $wanted = @($rarCases | Where-Object { Test-CaseSelected $_ })
        if ($wanted.Count) {
            $skipped += $wanted.Count
            Note Yellow "skipped $($wanted -join ', '): the RAR fixtures are missing from $media (New-PlaybackClips.ps1 builds them only when C:\Program Files\WinRAR\Rar.exe exists)"
        }
        $rarCases = @()
    }

    # 39. Skip-forward inside a multi-entry RAR must open the next ENTRY, not the next file
    #    in the folder: clsid2/mpc-hc@19432a0678 (#3644). two-entry.rar holds stereo.mkv
    #    (440/880 Hz) and third.mkv (1600 Hz), stored, in that order. Opening it raises the
    #    "Select Media from RAR" dialog (RarEntrySelectorDialog, entry 0 preselected), which
    #    the guest accepts with IDOK at 2 s (-AcceptDialogAt); the ID_NAVIGATE_SKIPFORWARDFILE
    #    (920) posted at 6 s must then produce a second capture sounding 1600 Hz. Unfixed
    #    2.5.5: the skip falls through to SearchInDir and opens the next file in the folder
    #    (twotracks.mkv, 1200 Hz) instead.
    if ($rarCases -contains 'rar-skip-within-archive' -and (Test-CaseSelected 'rar-skip-within-archive')) {
        $c = Invoke-PlayerCase -Name 'rar-skip-within-archive' -Clip 'two-entry.rar' -Switches '/play' `
            -AcceptDialogAt '2:Select Media from RAR,3.5:Select Media from RAR' -PostCommands '6:920' -CloseAtSec 12
        $accepts = @($c.Run.dialogAccepts)
        $posts = @($c.Run.posts)
        $problems = @((Get-ProcessProblem $c.Run))
        if (-not $accepts -or -not @($accepts | Where-Object delivered)) { $problems += 'the RAR entry selector was not accepted (the "Select Media from RAR" dialog)' }
        if (-not $posts -or -not $posts[0] -or -not $posts[0].delivered) { $problems += 'the posted skip did not reach a window' }
        if ($c.Wavs.Count -ne 2) {
            $problems += "$($c.Wavs.Count) audio stream(s) reached the endpoint, expected 2 (the first entry, then the second)"
        } else {
            $problems += (Test-Audio $c.Wavs[0] $stereo.audio[0].tones 4 1.0)
            $problems += (Test-Audio $c.Wavs[1] $clips.clips.'third.mkv'.audio[0].tones 4 1.0)
        }
        Complete-Case 'rar-skip-within-archive' $problems
    }

    # 40. ReplayGain must apply the track gain from the tags: clsid2/mpc-hc@2607141ae5
    #    (#4155). rg.flac is 8 s of 440 Hz stereo at half amplitude tagged
    #    REPLAYGAIN_TRACK_GAIN=-6.00 dB (no peak tag, so the clipping guard has nothing to
    #    clamp). Two runs on the same clip, ReplayGainMode 1 (track) vs 0 (off); the on
    #    run's RMS must be about 6 dB below the off run's. FLAC only: the commit reads the
    #    tags from the container metadata as ffmpeg keeps them (FLAC, MP4, ID3v2), and Opus
    #    is not among them. Unfixed 2.8.1 does not know the setting and both runs come out
    #    equal.
    if (Test-CaseSelected 'replaygain-track-gain') {
        $on = Invoke-PlayerCase -Name 'replaygain-track-gain-on' -Clip 'rg.flac' -Settings @{ ReplayGainMode = 1 }
        $off = Invoke-PlayerCase -Name 'replaygain-track-gain-off' -Clip 'rg.flac' -Settings @{ ReplayGainMode = 0 }
        $rmsOn = Get-CaptureRms $on.Wav
        $rmsOff = Get-CaptureRms $off.Wav
        $problems = @((Get-ProcessProblem $on.Run), (Get-ProcessProblem $off.Run))
        $problems += (Test-Audio $on.Wav $clips.clips.'rg.flac'.audio[0].tones 8 1.0)
        $problems += (Test-Audio $off.Wav $clips.clips.'rg.flac'.audio[0].tones 8 1.0)
        if ($null -eq $rmsOn -or $null -eq $rmsOff) {
            $problems += 'could not measure the capture RMS for both runs'
        } else {
            $db = 20 * [math]::Log10($rmsOn / $rmsOff)
            if ([math]::Abs($db - (-6.0)) -gt 1.0) {
                $problems += "ReplayGain on vs off is $([math]::Round($db, 1)) dB, expected -6.0 +/- 1 (rms $([math]::Round($rmsOn, 4)) vs $([math]::Round($rmsOff, 4)))"
            }
        }
        Complete-Case 'replaygain-track-gain' $problems
    }

    # 41. HLG on EVR-CP must be converted to SDR, not passed through washed out:
    #    clsid2/mpc-hc@f185a85594 (#4287) runs an HLG-to-SDR pixel shader first in the
    #    DX9 chain. flat_hlg.mkv is a 10-bit HLG flat field at signal 0.5 (Y=502 limited,
    #    BT.2020 primaries, neutral chroma, so the BT.2020->BT.709 matrix is a no-op on it).
    #    The expected level, 96.4, is computed from the shader's own constants in
    #    Get-FieldLevel; 2.8.2 has no conversion and shows the 0.5 signal as-is: measured
    #    126.4. DSVidRen 11 is EVR-CP. The 8-wide tolerance keeps 96.4 far from 126.4.
    if (Test-CaseSelected 'hlg-on-evrcp-is-not-washed-out') {
        $field = $clips.clips.'flat_hlg.mkv'.field
        $c = Invoke-PlayerCase -Name 'hlg-on-evrcp-is-not-washed-out' -Clip 'flat_hlg.mkv' `
            -Switches '/play /close /fullscreen /monitor 2' -PlugModes '1920x1080@60' -CaptureAtSec 3.5 `
            -Settings @{ DSVidRen = 11 } -IniSections $rendererLav
        Complete-Case 'hlg-on-evrcp-is-not-washed-out' @(
            (Get-ProcessProblem $c.Run),
            (Test-FlatField $c.Png $field 200 8)
        )
    }

    # 42-43. The /slave API (MpcApi.h): the guest hosts a window the player connects back to over
    #    WM_COPYDATA, sends commands as src/MPCTestAPI does and records every reply, so these
    #    cases assert on the protocol itself -- what the player tells a controlling application.
    #
    #    api-setposition-before-load (3d06f27984) is not among them, on purpose. The commit
    #    ignored CMD_SETPOSITION until the file is LOADED, but an early SETPOSITION was already a
    #    no-op on the unfixed build: SeekTo returns when m_pMS is still null, and once the graph
    #    exists mid-load the seek either waits out the duration check or is discarded by the
    #    load's own positioning, so both builds start at 0 and honour the post-load seek -- there
    #    is no observable difference to aim an assertion at. The commit's user-visible fix was
    #    posting the command's action instead of running it inside the media-close chain that
    #    delivered it (a synchronous CloseMedia re-entering a close), which needs a close already
    #    in flight when the command lands: a race this harness cannot stage deterministically.

    # 42. The selected audio track as the API reports it: clsid2/mpc-hc@e7053ee236 (#4213,
    #    unfixed 2.8.2). SendAudioTracksToApi marked the current stream with
    #    `dwFlags == AMSTREAMSELECTINFO_EXCLUSIVE`, but the audio switcher forwards the upstream
    #    splitter's flags for the selected input (StreamSwitcher.cpp Info: *pdwFlags = dwFlags
    #    from the splitter's own Info), and LAV Splitter reports its enabled stream
    #    AMSTREAMSELECTINFO_ENABLED -- the equality never held, and CMD_LISTAUDIOTRACKS always
    #    ended in |-1. twotracks.mkv's default is track 2, so the list must come back
    #    name|name|1. The current-track query is the control: GetCurrentAudioTrackIdx tested
    #    & ENABLED, which held, so it answers 1 on the unfixed build too and proves the second
    #    track really is the one selected -- a pass cannot come from the wrong track playing.
    #    The subtitle half of the fix (iSelected = j, the per-filter index, instead of i, the
    #    running index) sits in the IAMStreamSelect branch, which only external subtitle source
    #    filters take; subs.mkv's embedded tracks go through the ISubStream branch, where the two
    #    indices coincide, so no fixture here can show it.
    if (Test-CaseSelected 'api-reports-selected-audio-track') {
        $c = Invoke-ApiCase -Name 'api-reports-selected-audio-track' -Clip 'twotracks.mkv' -CloseAtSec 5 -Commands @(
            '3:CMD_GETAUDIOTRACKS:',
            '3.3:CMD_GETCURRENTAUDIOTRACK:'
        )
        $problems = @((Get-ProcessProblem $c.Run))
        $replies = @($c.Run.replies)
        if (-not $c.Run.connect) {
            $problems += 'the player never connected to the API host'
        } else {
            $list = $replies | Where-Object { $_.cmd -eq 'CMD_LISTAUDIOTRACKS' } | Select-Object -Last 1
            $current = $replies | Where-Object { $_.cmd -eq 'CMD_CURRENTAUDIOTRACK' } | Select-Object -Last 1
            if (-not $list) {
                $problems += 'CMD_GETAUDIOTRACKS got no CMD_LISTAUDIOTRACKS reply'
            } else {
                # name|name|...|selected, a literal | inside a name escaped as \| (MpcApi.h)
                $fields = $list.payload -split '(?<!\\)\|'
                $selected = $fields[-1]
                if ($fields.Count -ne 3) { $problems += "the audio track list has $($fields.Count - 1) entries, expected 2 ($($list.payload))" }
                if ($selected -ne '1') { $problems += "the API reports selected audio track $selected, expected 1 (the container's default is track 2; unfixed 2.8.2 reports -1)" }
            }
            if (-not $current) {
                $problems += 'CMD_GETCURRENTAUDIOTRACK got no CMD_CURRENTAUDIOTRACK reply'
            } elseif ($current.payload -ne '1') {
                $problems += "the current-track query reports $($current.payload), expected 1 (the control: it answers this on the unfixed build too)"
            }
        }
        Complete-Case 'api-reports-selected-audio-track' $problems
    }

    # 43. Volume and mute over the API: clsid2/mpc-hc@d9f4975bff (#4075, unfixed 2.8.0) added
    #    CMD_SETVOLUME and CMD_SETMUTE plus the CMD_GETVOLUME/CMD_GETMUTE queries, which answer
    #    CMD_CURRENTVOLUME/CMD_CURRENTMUTE. On the unfixed build the command ids mean nothing:
    #    the player ignores them and never answers, so every reply assert fails there -- and the
    #    capture never goes quiet. The setters are honored only from the connected host's window
    #    (MpcApi.h), which the guest's host window is. The mute must not move the volume (the
    #    query after it still says 40), and the WAV must go silent for the muted stretch and come
    #    back after the unmute.
    if (Test-CaseSelected 'api-volume-and-mute-round-trip') {
        $c = Invoke-ApiCase -Name 'api-volume-and-mute-round-trip' -Clip 'long.mkv' -CloseAtSec 9.5 -Commands @(
            '2.5:CMD_GETVOLUME:',
            '3:CMD_SETVOLUME:40',
            '3.3:CMD_GETVOLUME:',
            '5:CMD_SETMUTE:1',
            '5.3:CMD_GETMUTE:',
            '5.6:CMD_GETVOLUME:',
            '7.5:CMD_SETMUTE:0',
            '7.8:CMD_GETMUTE:'
        )
        $problems = @((Get-ProcessProblem $c.Run))
        $replies = @($c.Run.replies)
        if (-not $c.Run.connect) {
            $problems += 'the player never connected to the API host'
        } else {
            # The first reply of a kind at or after a time: what the player reported then. A
            # setter's own change notification and the answer to the query both qualify.
            $replyAt = {
                param([string] $Cmd, [double] $At)
                $replies | Where-Object { $_.cmd -eq $Cmd -and $_.at -ge $At } | Select-Object -First 1
            }
            if (-not @($replies | Where-Object { $_.cmd -eq 'CMD_CURRENTVOLUME' })) {
                $problems += 'CMD_GETVOLUME was never answered (the volume/mute commands are new in #4075; the unfixed build never answers)'
            }
            $vol40 = & $replyAt 'CMD_CURRENTVOLUME' 3.0
            $muteOn = & $replyAt 'CMD_CURRENTMUTE' 5.0
            $volWhileMuted = & $replyAt 'CMD_CURRENTVOLUME' 5.3
            $muteOff = & $replyAt 'CMD_CURRENTMUTE' 7.5
            if (-not $vol40 -or $vol40.payload -ne '40') { $problems += "after CMD_SETVOLUME 40 the player reports volume $(if ($vol40) { $vol40.payload } else { 'nothing' }), expected 40" }
            if (-not $muteOn -or $muteOn.payload -ne '1') { $problems += "after CMD_SETMUTE 1 the player reports mute $(if ($muteOn) { $muteOn.payload } else { 'nothing' }), expected 1" }
            if ($muteOn -and (-not $volWhileMuted -or $volWhileMuted.payload -ne '40')) { $problems += "muted, the volume query reports $(if ($volWhileMuted) { $volWhileMuted.payload } else { 'nothing' }), expected 40 (mute must not move the volume)" }
            if (-not $muteOff -or $muteOff.payload -ne '0') { $problems += "after CMD_SETMUTE 0 the player reports mute $(if ($muteOff) { $muteOff.payload } else { 'nothing' }), expected 0" }
        }
        if (-not $c.Wav) {
            $problems += 'no audio reached the endpoint'
        } else {
            # The capture starts when the render stream opens (about a second into the run), so
            # its clock is not the case's: the muted stretch is found in the data -- a contiguous
            # silent run mid-capture, closed by sound again -- not read off absolute times.
            $timeline = @(& (Join-Path $PSScriptRoot 'Get-ToneTimeline.ps1') -Wav $c.Wav)
            $sound = @($timeline | Where-Object { $_.hz -gt 0 })
            if (-not $sound) {
                $problems += 'the capture never sounds'
            } else {
                $firstSound = $sound[0].t
                $head = @($timeline | Where-Object { $_.t -ge $firstSound -and $_.t -le $firstSound + 2.5 })
                if (@($head | Where-Object { $_.hz -eq 0 }).Count) { $problems += 'the capture is silent before the mute command' }
                # The longest silent run after playback was underway that a sounding window
                # closes; a run still open at the end (the stream closing) does not count.
                $runStart = -1.0; $runLen = 0; $bestLen = 0
                foreach ($w in $timeline) {
                    if ($w.t -le $firstSound + 2.0) { continue }
                    if ($w.hz -eq 0) {
                        if ($runStart -lt 0) { $runStart = $w.t; $runLen = 0 }
                        $runLen++
                    } else {
                        if ($runLen -gt $bestLen) { $bestLen = $runLen }
                        $runStart = -1.0; $runLen = 0
                    }
                }
                if ($bestLen -lt 6) {   # 6 windows of 0.25 s = 1.5 s; the mute holds for 2.5
                    $problems += 'no muted stretch in the capture, followed by sound again (expected about 2.5 s of silence after CMD_SETMUTE 1, sound after CMD_SETMUTE 0)'
                }
            }
        }
        Complete-Case 'api-volume-and-mute-round-trip' $problems
    }

    # 44. Cover art of the next file in the same folder: clsid2/mpc-hc@c9a1ceda5e ("Fix a coverart
    #    loading issue"). UPDATE_MEDIA_ART caches the folder and author it last searched and skips
    #    CoverArt::FindExternal while they match; the unfixed build cached them even when the search
    #    found nothing. art\a.wav has no art, art\b.wav has its own b.png (still.png, flat red).
    #    Opening b over a playing a queues it, so the close in between does not clear the cache
    #    (CloseMedia runs UPDATE_MEDIA_ART only when no next file is queued), and the unfixed build
    #    never looks for b.png: the view stays artless. Unfixed 2.6.4 (the fix is in 2.7.0).
    if (Test-CaseSelected 'cover-art-next-file-in-same-folder') {
        $c = Invoke-PlayerCase -Name 'cover-art-next-file-in-same-folder' -Clip 'art\a.wav' `
            -Switches '/play /monitor 2' -PlugModes '1920x1080@60' `
            -SecondArgumentLine '"C:\mpc-test\media\art\b.wav"' -SecondAtSec 3 -CaptureAtSec 7 -CloseAtSec 9
        $problems = @(Get-ProcessProblem $c.Run)
        if (-not $c.Png) {
            $problems += 'no frame was captured'
        } else {
            # The player is windowed on the plugged monitor and the art is fitted into its view, so
            # count red samples over the whole screen rather than probe one point; neither the
            # desktop nor the logo shown without art has any saturated red. A 600x340 view is about
            # 3200 samples at step 8.
            $bmp = [System.Drawing.Bitmap]::FromFile($c.Png)
            $red = 0; $total = 0
            try {
                for ($y = 0; $y -lt $bmp.Height; $y += 8) {
                    for ($x = 0; $x -lt $bmp.Width; $x += 8) {
                        $total++
                        if ((Get-ColourName $bmp.GetPixel($x, $y)) -eq 'red') { $red++ }
                    }
                }
            } finally { $bmp.Dispose() }
            if ($red -lt 1000) {
                $problems += "b.wav's cover art (b.png, flat red) is not shown: $red of $total samples are red (the folder cache from a.wav, which has no art, skipped the search)"
            }
        }
        Complete-Case 'cover-art-next-file-in-same-folder' $problems
    }

    # The two translation cases need Lang\mpcresources.de.dll and .fr.dll beside the player, built for
    # its version: Translations::SetLanguage loads a satellite only when its fixed file version is the
    # exe's major.minor.patch.0, and otherwise falls back to English without a word. A slot has them
    # only if it built the translations, and a later project-only build leaves the old ones behind (seen
    # on a slot with a 2.8.3 exe and 2.8.2 DLLs: the cases then ran in English and failed as if the
    # player were broken). So they are checked here, and the cases skipped with the reason.
    $languageCases = @('open-dialog-icon-with-translation', 'reopen-dialog-after-language-change')
    $exeVer = (Get-Item (Join-Path $playerDir 'mpc-hc64.exe')).VersionInfo
    $wantLang = '{0}.{1}.{2}.0' -f $exeVer.FileMajorPart, $exeVer.FileMinorPart, $exeVer.FileBuildPart
    $langProblems = foreach ($lang in 'de', 'fr') {
        $dll = Join-Path $playerDir "Lang\mpcresources.$lang.dll"
        if (-not (Test-Path $dll)) { "Lang\mpcresources.$lang.dll is missing" }
        else {
            $v = (Get-Item $dll).VersionInfo
            $got = '{0}.{1}.{2}.{3}' -f $v.FileMajorPart, $v.FileMinorPart, $v.FileBuildPart, $v.FilePrivatePart
            if ($got -ne $wantLang) { "Lang\mpcresources.$lang.dll is $got, the player needs $wantLang" }
        }
    }
    if ($langProblems) {
        $wanted = @($languageCases | Where-Object { Test-CaseSelected $_ })
        if ($wanted.Count) {
            $skipped += $wanted.Count
            Note Yellow "skipped $($wanted -join ', '): $($langProblems -join '; ') ($playerDir). Build the translations for this exe: build.bat Build x64 Translations (or a full build.bat Build x64 Release)."
        }
        $languageCases = @()
    }

    # 45. The Open dialog's icon with a translation active: #4119, 10c2c03ebd. LoadStaticIcon took
    #    the icon from AfxGetResourceHandle(), which with a translation is the satellite DLL, and the
    #    satellites carry no icons; the static stayed empty. The fix loads it from the exe. German
    #    (1031) from the start; the Open dialog (ID_FILE_OPENMEDIA 800) is probed by its icon static,
    #    IDR_MAINFRAME 128, then cancelled. Unfixed 2.8.1.
    if ($languageCases -contains 'open-dialog-icon-with-translation' -and (Test-CaseSelected 'open-dialog-icon-with-translation')) {
        $c = Invoke-PlayerCase -Name 'open-dialog-icon-with-translation' -Clip 'long.mkv' -Switches '/play' `
            -Settings @{ InterfaceLanguage = 1031 } -PostCommands '2:800' -ControlAt '4:probe:128,5:cmd:128:2' -CloseAtSec 7
        $problems = @(Get-ProcessProblem $c.Run)
        $iconProbe = @($c.Run.controls) | Where-Object { $_.op -eq 'probe' } | Select-Object -First 1
        if (-not $iconProbe -or -not $iconProbe.found) {
            $problems += 'the Open dialog (its icon static, id 128) was not found'
        } else {
            if ($iconProbe.dialog -eq 'Open') { $problems += 'the Open dialog is titled "Open": the German translation was not active, so the case proves nothing' }
            if (-not $iconProbe.icon) { $problems += "the Open dialog ('$($iconProbe.dialog)') shows no icon: it was looked up in the translation DLL (#4119)" }
        }
        Complete-Case 'open-dialog-icon-with-translation' $problems
    }

    # 46. Reopening a dialog after a language change: f261d1b782 (#3902). CDpiAwareResizableDialog
    #    cached the dialog template pointer from the first open; a language change frees the satellite
    #    DLL that pointer lives in, so the next open of the same dialog object read unmapped memory
    #    and the player crashed. Organize Favorites (ID_FAVORITES_ORGANIZE 937) is a long-lived member
    #    of the frame whose window is only hidden on Cancel, so its object and its cache survive the
    #    change. German first (the template comes from mpcresources.de.dll); open it (found by its
    #    tab control, IDC_TAB1 11200) and cancel it; Options (815) opens on the Theme page
    #    (LastUsedPage = IDD_PPAGETHEME 10038), its language combo (IDC_COMBO2 11001, item data the
    #    LANGID) goes to French (1036) and OK frees the German DLL; then Organize Favorites again,
    #    and grow it by 80 px: a visible resize reads the template (OnSize -> GetDialogFontInfo),
    #    and the unfixed build reads it through the dangling pointer. The command is disabled while
    #    there are no favorites, so the profile carries one. The reshown window keeps its German
    #    title (it is not recreated), so that the change happened is read from the ini the player
    #    saves on exit. Unfixed 2.7.1: the resize kills the player, exit code 0xC000041D (an exception
    #    inside a window procedure).
    if ($languageCases -contains 'reopen-dialog-after-language-change' -and (Test-CaseSelected 'reopen-dialog-after-language-change')) {
        $c = Invoke-PlayerCase -Name 'reopen-dialog-after-language-change' -Clip 'long.mkv' -Switches '/play' `
            -Settings @{ InterfaceLanguage = 1031; LastUsedPage = 10038 } `
            -IniSections @{ 'Favorites\Files' = @{ Name0 = 'Long;0;0;C:\mpc-test\media\long.mkv' } } -PostCommands '2:937,5:815,11:937' `
            -ControlAt '3:probe:11200,4:cmd:11200:2,7:combo:11001:1036,8:cmd:11001:1,12.5:size:11200:80,14:probe:11200,15:cmd:11200:2' -CloseAtSec 17
        $problems = @(Get-ProcessProblem $c.Run)
        $steps = @($c.Run.controls)
        $first = $steps | Where-Object { $_.op -eq 'probe' -and $_.at -lt 5 } | Select-Object -First 1
        $combo = $steps | Where-Object { $_.op -eq 'combo' } | Select-Object -First 1
        $resize = $steps | Where-Object { $_.op -eq 'size' } | Select-Object -First 1
        $again = $steps | Where-Object { $_.op -eq 'probe' -and $_.at -gt 13 } | Select-Object -First 1
        if (-not $first -or -not $first.found) { $problems += 'Organize Favorites did not open the first time' }
        if (-not $combo -or -not $combo.found -or $combo.index -lt 0) { $problems += 'the Theme page language combo with French was not found, so the language did not change' }
        if (-not $resize -or -not $resize.found) { $problems += 'Organize Favorites did not open again after the language change' }
        if (-not $again -or -not $again.found) { $problems += 'Organize Favorites was gone after the resize (the player read the freed German template)' }
        if (-not $c.Run.exitCode -and (Get-IniValue $c.Ini 'Settings' 'InterfaceLanguage') -ne '1036') {
            $problems += "the saved InterfaceLanguage is '$(Get-IniValue $c.Ini 'Settings' 'InterfaceLanguage')', not 1036: the language did not change, so the case proves nothing"
        }
        Complete-Case 'reopen-dialog-after-language-change' $problems
    }

    # 47. A modeless resizable dialog follows a display scale change: e704c6b7af (#3678, "dpi-aware
    #    dialog to support modeless dialogs ..."). Organize Favorites (937; it needs a favorite to be
    #    enabled) opens at 100%, the primary monitor goes to 150% under it, and the dialog, its tab
    #    control (IDC_TAB1 11200) and its OK button (IDOK 1) are measured before and after.
    #    Windows resizes the dialog window itself on both builds (measured 499x358 -> 570x472, the
    #    same on unfixed 2.5.5), so that proves nothing; what the fix does is re-lay the controls out
    #    from the template at the new DPI. Measured on develop: OK 101x26 -> 116x35. On 2.5.5 it
    #    stays 102x26, a 100% button in a 150% dialog. Asserted: OK at least x1.25 taller and x1.1
    #    wider, and still inside the dialog.
    if (Test-CaseSelected 'modeless-dialog-follows-dpi-change') {
        $c = Invoke-PlayerCase -Name 'modeless-dialog-follows-dpi-change' -Clip 'long.mkv' -Switches '/play' `
            -IniSections @{ 'Favorites\Files' = @{ Name0 = 'Long;0;0;C:\mpc-test\media\long.mkv' } } -PostCommands '2:937' `
            -ControlAt '3:probe:11200,3.2:probe:1,4:dpi:0:150,8:probe:11200,8.2:probe:1,9:cmd:11200:2,10:dpi:0:100' -CloseAtSec 12
        $problems = @(Get-ProcessProblem $c.Run)
        $steps = @($c.Run.controls)
        $probeOf = { param([int] $Ctrl, [bool] $After) $steps | Where-Object { $_.op -eq 'probe' -and $_.ctrl -eq $Ctrl -and (($_.at -gt 5) -eq $After) } | Select-Object -First 1 }
        $ok0 = & $probeOf 1 $false; $ok1 = & $probeOf 1 $true
        if (-not $ok0 -or -not $ok0.found -or -not $ok1 -or -not $ok1.found) {
            $problems += 'Organize Favorites or its OK button was not found before and after the change'
        } else {
            $w = { param($r) $r[2] - $r[0] }; $h = { param($r) $r[3] - $r[1] }
            Note Gray ("      dialog {0}x{1} -> {2}x{3}, OK {4}x{5} -> {6}x{7}" -f (& $w $ok0.dialogRect), (& $h $ok0.dialogRect), (& $w $ok1.dialogRect), (& $h $ok1.dialogRect), (& $w $ok0.rect), (& $h $ok0.rect), (& $w $ok1.rect), (& $h $ok1.rect))
            $hRatio = (& $h $ok1.rect) / (& $h $ok0.rect); $wRatio = (& $w $ok1.rect) / (& $w $ok0.rect)
            if ($hRatio -lt 1.25 -or $wRatio -lt 1.1) { $problems += ("the OK button changed x{0:N2} wide, x{1:N2} tall for a 100%->150% change: the controls were not laid out again at the new DPI" -f $wRatio, $hRatio) }
            $d = $ok1.dialogRect; $r = $ok1.rect
            if ($r[2] -gt $d[2] -or $r[3] -gt $d[3]) { $problems += "after the change the OK button ($($r -join ',')) reaches outside the dialog ($($d -join ','))" }
        }
        Complete-Case 'modeless-dialog-follows-dpi-change' $problems
    }

    # 48. The status pane reaches the time pane: a99d7ce7c9 ("Simplify statusbar relayout", #3782).
    #    CPlayerStatusBar::Relayout used to size the status label (IDC_PLAYERSTATUS 12026) to the
    #    text it held at that moment, so text that grew later was cut short; it now spans up to 8 px
    #    before the time label (IDC_PLAYERTIME 12027). Both are read from the frame while long.mkv
    #    plays. Unfixed 2.6.1.
    if (Test-CaseSelected 'status-pane-reaches-time-pane') {
        $c = Invoke-PlayerCase -Name 'status-pane-reaches-time-pane' -Clip 'long.mkv' -Switches '/play' `
            -ControlAt '4:fprobe:12026,4.2:fprobe:12027' -CloseAtSec 6
        $problems = @(Get-ProcessProblem $c.Run)
        $status = @($c.Run.controls) | Where-Object { $_.ctrl -eq 12026 } | Select-Object -First 1
        $time = @($c.Run.controls) | Where-Object { $_.ctrl -eq 12027 } | Select-Object -First 1
        if (-not $status -or -not $status.found -or -not $time -or -not $time.found) {
            $problems += 'the status bar labels were not found'
        } else {
            Note Gray "      status '$($status.text)' $($status.rect -join ','); time '$($time.text)' $($time.rect -join ',')"
            $gap = $time.rect[0] - $status.rect[2]
            if ([math]::Abs($gap - 8) -gt 1) { $problems += "the status label ends $gap px before the time label, expected 8: it was sized to its text ('$($status.text)', $($status.rect[2] - $status.rect[0]) px)" }
        }
        Complete-Case 'status-pane-reaches-time-pane' $problems
    }

    # 49. The size grip after a live DPI change, modern dark theme: #4085, 410e511aa6 (of #4037, #4140).
    #    Organize Favorites at 100%, then the primary monitor to 150%; the grip's corner is captured
    #    before and after (the runner's grip step). The grip glyph is six equal squares in the theme's
    #    grip colour (191,191,191 in Dark). Unfixed 2.8.0 redraws it after the change into a grid of
    #    the wrong size, and the squares come out clipped into bars; the fix draws six whole squares.
    #    The capture before the change is the control: six squares on both builds.
    function Get-GripSquares {
        # The glyph's connected components: pixels within 12 of (191,191,191) and neutral, inside the grip's
        # own rect. The crop also holds the window's shadow edge, whose greys reach that value.
        param([string] $Png, $Grip)
        $cw = [math]::Min(2 * ($Grip.rect[2] - $Grip.rect[0]), $Grip.dialogRect[2] - $Grip.dialogRect[0])
        $ch = [math]::Min(2 * ($Grip.rect[3] - $Grip.rect[1]), $Grip.dialogRect[3] - $Grip.dialogRect[1])
        $gx0 = $Grip.rect[0] - ($Grip.dialogRect[2] - $cw); $gx1 = $Grip.rect[2] - ($Grip.dialogRect[2] - $cw)
        $gy0 = $Grip.rect[1] - ($Grip.dialogRect[3] - $ch); $gy1 = $Grip.rect[3] - ($Grip.dialogRect[3] - $ch)
        $bmp = [System.Drawing.Bitmap]::FromFile($Png)
        try {
            $on = [bool[,]]::new($bmp.Width, $bmp.Height)
            for ($y = [math]::Max(0, $gy0); $y -lt [math]::Min($bmp.Height, $gy1); $y++) { for ($x = [math]::Max(0, $gx0); $x -lt [math]::Min($bmp.Width, $gx1); $x++) {
                $px = $bmp.GetPixel($x, $y)
                $on[$x, $y] = [math]::Abs($px.R - 191) -le 12 -and [math]::Abs($px.R - $px.G) -le 4 -and [math]::Abs($px.R - $px.B) -le 4
            } }
            $seen = [bool[,]]::new($bmp.Width, $bmp.Height)
            $parts = @()
            for ($y = 0; $y -lt $bmp.Height; $y++) { for ($x = 0; $x -lt $bmp.Width; $x++) {
                if (-not $on[$x, $y] -or $seen[$x, $y]) { continue }
                $stack = [System.Collections.Generic.Stack[int[]]]::new(); $stack.Push(@($x, $y)); $seen[$x, $y] = $true
                $x0 = $x; $x1 = $x; $y0 = $y; $y1 = $y; $n = 0
                while ($stack.Count) {
                    $q = $stack.Pop(); $n++
                    $x0 = [math]::Min($x0, $q[0]); $x1 = [math]::Max($x1, $q[0]); $y0 = [math]::Min($y0, $q[1]); $y1 = [math]::Max($y1, $q[1])
                    foreach ($dxy in @(@(1, 0), @(-1, 0), @(0, 1), @(0, -1))) {
                        $nx = $q[0] + $dxy[0]; $ny = $q[1] + $dxy[1]
                        if ($nx -ge 0 -and $ny -ge 0 -and $nx -lt $bmp.Width -and $ny -lt $bmp.Height -and $on[$nx, $ny] -and -not $seen[$nx, $ny]) { $seen[$nx, $ny] = $true; $stack.Push(@($nx, $ny)) }
                    }
                }
                $parts += [pscustomobject]@{ w = $x1 - $x0 + 1; h = $y1 - $y0 + 1; n = $n }
            } }
            $parts
        } finally { $bmp.Dispose() }
    }
    if (Test-CaseSelected 'size-grip-after-dpi-change') {
        $c = Invoke-PlayerCase -Name 'size-grip-after-dpi-change' -Clip 'long.mkv' -Switches '/play' `
            -Settings @{ MPCTheme = 1; ModernThemeMode = 0 } `
            -IniSections @{ 'Favorites\Files' = @{ Name0 = 'Long;0;0;C:\mpc-test\media\long.mkv' } } -PostCommands '2:937' `
            -ControlAt '3:grip:11200,4:dpi:0:150,8:grip:11200,9:cmd:11200:2,10:dpi:0:100' -CloseAtSec 12
        $problems = @(Get-ProcessProblem $c.Run)
        foreach ($at in 3, 8) {
            $when = if ($at -eq 3) { 'at 100%' } else { 'after the change to 150%' }
            $png = Join-Path $OutDir "size-grip-after-dpi-change-grip-$at.png"
            $grip = @($c.Run.controls) | Where-Object { $_.op -eq 'grip' -and $_.at -eq $at } | Select-Object -First 1
            if (-not (Test-Path $png) -or -not $grip -or -not $grip.gripFound) { $problems += "no grip capture $when"; continue }
            $parts = @(Get-GripSquares $png $grip)
            Note Gray ("      grip $when`: " + (($parts | ForEach-Object { "$($_.w)x$($_.h)" }) -join ' '))
            $squares = @($parts | Where-Object { $_.w -eq $_.h -and $_.n -eq $_.w * $_.h })
            $sizes = @($squares | ForEach-Object { $_.w } | Sort-Object -Unique)
            if ($parts.Count -ne 6 -or $squares.Count -ne 6 -or $sizes.Count -ne 1) {
                $problems += "the grip glyph $when is not six equal squares: $(($parts | ForEach-Object { "$($_.w)x$($_.h)" }) -join ' ')"
            }
        }
        Complete-Case 'size-grip-after-dpi-change' $problems
    }
}
finally {
    Remove-PSSession $session -ErrorAction SilentlyContinue
}

Finish
