<#
.SYNOPSIS
    The osd suite: the on-screen message in fullscreen must be the same size with the docked panels up as
    without them.

.DESCRIPTION
    In fullscreen the docked panels and toolbars sit on top of the video, so the renderer keeps its full-screen
    window while the video view shrinks. With MPC Video Renderer the OSD is a bitmap that the renderer stretches
    over its whole back buffer, and before #4277 that bitmap was sized from the shrunken view, so the message
    grew whenever a panel was shown.

    Each case plays a clip fullscreen in the target's console session, shows a message once with the playlist
    and toolbars docked and once with both gone, captures the window, and compares the two message boxes.

      osd-size-with-panels-evr-cp   the control: EVR-CP draws the OSD in a window of its own, which has never
                                    been stretched. It proves the harness measures the box on this target.
      osd-size-with-panels-mpcvr    the renderer of #4277.

    A case fails as "nothing was tested" if the view was not actually smaller with the panels up, or not the
    whole screen without them.

    The MPC Video Renderer is not part of the player build. The player loads MPCVR\MpcVideoRenderer64.ax from
    beside its own exe without any registration, so the suite deploys it there and the guest is not changed.
    It is taken from -MpcvrPath, $env:MPC_TEST_MPCVR, the build's own MPCVR folder, or a K-Lite install, in
    that order. With none of those, the MPCVR case is skipped.
#>
[CmdletBinding()]
param(
    [switch] $Probe,
    [string] $VMName = '',
    [string] $OutDir = (Join-Path $PSScriptRoot 'results'),
    [string] $PlayerBinary,
    [string] $MpcvrPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$description = 'Fullscreen OSD message size with the docked panels up and without them (#4277)'
$testsRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$repoRoot = Split-Path $testsRoot -Parent
$transport = Join-Path $testsRoot 'emulator\tools\GuestTransport.ps1'

if ($Probe) {
    $ready = $true; $reason = ''
    if (-not (Test-Path $transport)) { $ready = $false; $reason = 'emulator submodule not initialised (git submodule update --init tests/emulator)' }
    elseif (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { $ready = $false; $reason = 'ffmpeg not on PATH (tests\emulator\tools\Install-TestBed.ps1 installs it)' }
    return [pscustomobject]@{ Suite = 'osd'; Description = $description; Ready = $ready; Reason = $reason }
}

New-Item -ItemType Directory -Force $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path
$passed = 0; $failed = 0; $skipped = 0
$notes = [System.Collections.Generic.List[string]]::new()
function Note { param([string] $Colour, [string] $Text) $notes.Add($Text); Write-Host "  $Text" -ForegroundColor $Colour }
function Finish { [pscustomobject]@{ Suite = 'osd'; Passed = $passed; Failed = $failed; Skipped = $skipped; Notes = $notes } }
function Complete-Case {
    param([string] $Name, [string[]] $Problems)
    $Problems = @($Problems | Where-Object { $_ })
    if ($Problems.Count -eq 0) { $script:passed++; Note Green "PASS $Name" }
    else { $script:failed++; Note Red "FAIL ${Name}: $($Problems -join ' | ')" }
}

# --- what is driven -------------------------------------------------------------

# The command ids come from the checkout's resource.h when this repository is mounted in one. The defaults are
# develop's.
function Get-ResourceId {
    param([string] $Name, [int] $Default)
    $header = Join-Path $repoRoot 'src\mpc-hc\resource.h'
    if (Test-Path $header) {
        $hit = Select-String -Path $header -Pattern ("^#define\s+{0}\s+(\d+)" -f [regex]::Escape($Name)) | Select-Object -First 1
        if ($hit) { return [int]$hit.Matches[0].Groups[1].Value }
    }
    $Default
}
$ids = @{
    IdPlaylist   = Get-ResourceId 'ID_VIEW_PLAYLIST' 824
    IdFullscreen = Get-ResourceId 'ID_VIEW_FULLSCREEN' 830
    IdPlayPause  = Get-ResourceId 'ID_PLAY_PLAYPAUSE' 889
}

# The modern theme in dark mode, pinned so the message box has a known fill colour (CMPCTheme::ContentBGColor)
# whatever the guest's app mode is. The OSD is made opaque so that colour is what reaches the screen.
$boxFill = 0x202020
$renderers = @{ 'evr-cp' = 11; 'mpcvr' = 14 }
function Get-Ini([int] $Renderer) {
    "[Settings]`r`nUpdaterAutoCheck=0`r`nKeepHistory=0`r`nDSVidRen=$Renderer`r`nShowOSD=1`r`nOSDTransparency=0`r`n" +
    "MPCTheme=1`r`nModernThemeMode=0`r`nHideFullscreenControls=1`r`nHideFullscreenControlsDelay=5000`r`nHideFullscreenDockedPanels=1`r`n"
}

$playerDir = if ($PlayerBinary) { Split-Path (Resolve-Path $PlayerBinary).Path -Parent }
             elseif (Test-Path (Join-Path $repoRoot 'bin\mpc-hc_x64\mpc-hc64.exe')) { Join-Path $repoRoot 'bin\mpc-hc_x64' }
             else { $null }
if (-not $playerDir) { throw 'No player build: pass -PlayerBinary or build this repository (bin\mpc-hc_x64\mpc-hc64.exe).' }

if (-not $MpcvrPath) {
    $MpcvrPath = @($env:MPC_TEST_MPCVR,
                   (Join-Path $playerDir 'MPCVR\MpcVideoRenderer64.ax'),
                   "${env:ProgramFiles(x86)}\K-Lite Codec Pack\MPC-HC64\MPCVR\MpcVideoRenderer64.ax",
                   "$env:ProgramFiles\K-Lite Codec Pack\MPC-HC64\MPCVR\MpcVideoRenderer64.ax") |
                 Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
}

# A plain clip with a black band at the top, where the message sits, so nothing in the picture can be taken for
# the box.
$media = Join-Path $PSScriptRoot 'media'
$clip = Join-Path $media 'osd.mp4'
if (-not (Test-Path $clip)) {
    New-Item -ItemType Directory -Force $media | Out-Null
    & ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'testsrc2=size=640x360:rate=25' -t 60 -c:v libx264 -preset veryfast -pix_fmt yuv420p $clip
    if ($LASTEXITCODE -ne 0) { throw "ffmpeg failed producing $clip" }
}

# --- target ---------------------------------------------------------------------

. $transport
$cfg = Get-TestBedConfig
$session = Connect-TestGuest -Guest $VMName
try {
    $console = Invoke-Command -Session $session { (Get-CimInstance Win32_ComputerSystem).UserName }
    $consoleUser = if ($cfg.GuestConsoleUser) { $cfg.GuestConsoleUser } else { ("$console" -split '\\')[-1] }
    if (-not $consoleUser) { throw 'Nobody is logged on at the guest console; the player needs a desktop.' }

    # Deploy: the guest script, the clip, and the player with what it loads from beside itself (LAV Filters,
    # and the MPC Video Renderer in its MPCVR folder).
    $stage = Join-Path $OutDir 'player-stage'
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    New-Item -ItemType Directory -Force $stage | Out-Null
    Copy-Item (Join-Path $playerDir 'mpc-hc64.exe') $stage
    if (Test-Path (Join-Path $playerDir 'mpciconlib.dll')) { Copy-Item (Join-Path $playerDir 'mpciconlib.dll') $stage }
    if (Test-Path (Join-Path $playerDir 'LAVFilters64')) { Copy-Item (Join-Path $playerDir 'LAVFilters64') $stage -Recurse }
    if ($MpcvrPath) {
        New-Item -ItemType Directory -Force (Join-Path $stage 'MPCVR') | Out-Null
        Copy-Item $MpcvrPath (Join-Path $stage 'MPCVR\MpcVideoRenderer64.ax')
    }
    $zip = Join-Path $OutDir 'player.zip'
    if (Test-Path $zip) { [IO.File]::Delete($zip) }
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip

    Invoke-Command -Session $session {
        Get-Process mpc-hc64 -ErrorAction SilentlyContinue | Stop-Process -Force
        foreach ($d in 'C:\mpc-test', 'C:\mpc-test\osd', 'C:\mpc-test\osd\out') { if (-not (Test-Path $d)) { New-Item -ItemType Directory $d | Out-Null } }
    }
    Copy-Item -ToSession $session $zip 'C:\mpc-test\osd\player.zip' -Force
    Copy-Item -ToSession $session $clip 'C:\mpc-test\osd\osd.mp4' -Force
    Copy-Item -ToSession $session (Join-Path $PSScriptRoot 'Run-OsdCase.guest.ps1') 'C:\mpc-test\osd\' -Force
    Invoke-Command -Session $session {
        if (Test-Path 'C:\mpc-test\osd\player') { Remove-Item 'C:\mpc-test\osd\player' -Recurse -Force }
        Expand-Archive 'C:\mpc-test\osd\player.zip' 'C:\mpc-test\osd\player' -Force
        # The case runs as the console user, who has to be able to write its results and the player's ini here.
        & icacls 'C:\mpc-test\osd' /grant 'Users:(OI)(CI)M' /T | Out-Null
    }
    $version = Invoke-Command -Session $session { (Get-Item 'C:\mpc-test\osd\player\mpc-hc64.exe').VersionInfo.ProductVersion }
    Note Gray "player under test: $version from $playerDir"
    if ($MpcvrPath) { Note Gray "MPC Video Renderer: $((Get-Item $MpcvrPath).VersionInfo.FileVersion) from $MpcvrPath" }

    # --- one case -------------------------------------------------------------------

    function Invoke-OsdJob {
        param([string] $Name, [int] $Renderer)
        $guestOut = "C:\mpc-test\osd\out\$Name"
        $job = (@{ Exe = 'C:\mpc-test\osd\player\mpc-hc64.exe'; Clip = 'C:\mpc-test\osd\osd.mp4'; OutDir = $guestOut; Fill = $boxFill } + $ids) | ConvertTo-Json
        $json = Invoke-Command -Session $session -ArgumentList $job, $guestOut, (Get-Ini $Renderer), $consoleUser {
            param($job, $out, $iniText, $user)
            $ErrorActionPreference = 'Continue'
            Get-Process mpc-hc64 -ErrorAction SilentlyContinue | Stop-Process -Force
            if (Test-Path $out) { Remove-Item $out -Recurse -Force }
            New-Item -ItemType Directory $out | Out-Null
            & icacls $out /grant 'Users:(OI)(CI)M' | Out-Null
            # An ini beside the exe puts the player in portable mode: nothing of the last case, or of whoever used
            # this guest before, carries over.
            Get-ChildItem 'C:\mpc-test\osd\player' -Filter '*.ini' | ForEach-Object { [IO.File]::Delete($_.FullName) }
            [IO.File]::WriteAllText('C:\mpc-test\osd\player\mpc-hc64.ini', $iniText, [Text.Encoding]::Unicode)
            [IO.File]::WriteAllText('C:\mpc-test\osd\job.json', $job)

            $taskArgs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\mpc-test\osd\Run-OsdCase.guest.ps1 -JobFile C:\mpc-test\osd\job.json'
            $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $taskArgs
            $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive
            Register-ScheduledTask -TaskName 'MpcOsdCase' -Action $action -Principal $principal -Force | Out-Null
            Start-ScheduledTask -TaskName 'MpcOsdCase'
            $deadline = (Get-Date).AddSeconds(180)
            while (-not (Test-Path "$out\result.json") -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
            Unregister-ScheduledTask -TaskName 'MpcOsdCase' -Confirm:$false
            Get-Process mpc-hc64 -ErrorAction SilentlyContinue | Stop-Process -Force
            if (Test-Path "$out\result.json") { Get-Content "$out\result.json" -Raw } else { $null }
        }
        if (-not $json) { throw "case $Name produced no result on the guest" }
        $local = Join-Path $OutDir $Name
        if (Test-Path $local) { Remove-Item $local -Recurse -Force }
        New-Item -ItemType Directory -Force $local | Out-Null
        Copy-Item -FromSession $session "$guestOut\*" -Destination $local -Force
        $run = $json | ConvertFrom-Json
        if ($run.error) { throw "case $Name failed on the guest: $($run.error)" }
        $run
    }

    # The message box with the panels up must be the box without them, to within rounding.
    function Test-OsdSize {
        param($Run, [string] $Module)
        $problems = @()
        if (-not (@($Run.renderer) -match [regex]::Escape($Module))) { return "the renderer did not load: $Module not in the process (loaded: $(@($Run.renderer) -join ', '))" }
        $panels = @($Run.shots | Where-Object name -eq 'panels')[0]
        $clear = @($Run.shots | Where-Object name -eq 'no-panels')[0]
        $screen = $Run.screen
        if ($panels.view.w -ge $screen.w -and $panels.view.h -ge $screen.h) { $problems += "the panels were not docked in the first shot (view $($panels.view.w)x$($panels.view.h) on a $($screen.w)x$($screen.h) screen), so nothing was tested" }
        if ($clear.view.w -ne $screen.w -or $clear.view.h -ne $screen.h) { $problems += "the reference shot still had panels docked (view $($clear.view.w)x$($clear.view.h) on a $($screen.w)x$($screen.h) screen)" }
        if (-not $panels.box) { $problems += 'no message box was found with the panels up' }
        if (-not $clear.box) { $problems += 'no message box was found without the panels' }
        if ($problems) { return $problems }
        $dw = $panels.box.w - $clear.box.w; $dh = $panels.box.h - $clear.box.h
        if ([math]::Abs($dw) -gt 2 -or [math]::Abs($dh) -gt 2) {
            $problems += "the message box is $($panels.box.w)x$($panels.box.h) with the panels up and $($clear.box.w)x$($clear.box.h) without them"
        }
        $problems
    }

    # --- cases ------------------------------------------------------------------------

    # 1. The control: the window OSD of EVR-CP. If this fails the harness cannot measure the box on this target,
    #    and the MPCVR result below means nothing.
    $r = Invoke-OsdJob -Name 'evr-cp' -Renderer $renderers['evr-cp']
    $control = @(Test-OsdSize $r 'evr.dll')
    Complete-Case 'osd-size-with-panels-evr-cp' $control
    if ($control.Count) { Note Yellow 'the control failed, so the MPCVR case below proves nothing on this target' }

    # 2. The bitmap OSD that MPCVR stretches over its back buffer (#4277).
    if ($MpcvrPath) {
        $r = Invoke-OsdJob -Name 'mpcvr' -Renderer $renderers['mpcvr']
        Complete-Case 'osd-size-with-panels-mpcvr' (Test-OsdSize $r 'MpcVideoRenderer64.ax')
    } else {
        $skipped++
        Note Yellow 'osd-size-with-panels-mpcvr skipped: no MpcVideoRenderer64.ax (pass -MpcvrPath or set MPC_TEST_MPCVR)'
    }
}
finally {
    Remove-PSSession $session -ErrorAction SilentlyContinue
}

Finish
