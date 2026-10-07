<#
.SYNOPSIS
    The mouse suite: drives the player with real mouse input in the target's console session, and asserts on
    what the screen showed.

.DESCRIPTION
    Hover-driven behaviour cannot be tested by posting window messages. A posted WM_MOUSEMOVE goes to the
    window it is addressed to whatever holds the capture, and lands in the queue wherever the sender put it,
    so capture, leave tracking and the order of input and paint messages are all the test's own invention.
    This suite injects input with SendInput from an interactive scheduled task on the target, which is the
    one way those three are what Windows really does.

    The cases so far are about drop-down-list combo boxes (issue #4276): with the list just opened and the
    pointer already over an item, the closed part of the combo must still show the selected item; closing
    without a pick must leave the selection alone; clicking an item must select it.

    Two more cases drive the playlist (Run-PlaylistInputCase.guest.ps1): typing a name's first letters
    must move the selection to it without skipping the item the search starts from (#3844), and a click on
    the time column of the selected entry must not open an editor holding the time (#3885). A fourth case
    (Run-KeysEditCase.guest.ps1) double-clicks a key entry's hotkey cell in Options > Player > Keys, which
    must open the in-place hotkey editor (#3853).

    Two control cases run first, against combocase.exe, a small program with no player code in it:

      control-plain-windows-combo    a plain comctl32 combo never shows the hovered item, which is what
                                     makes the player doing so a defect rather than Windows behaviour;
      control-harness-detects-echo   a combo that invalidates itself on mouse-leave does show it, which
                                     proves this harness can see the defect at all. If this one fails, a
                                     pass on the player cases means nothing.

    Evidence is the screen itself (CopyFromScreen in the console session), cut down to the combo's face and
    compared with the same face once everything has settled. See README.md for the traps.
#>
[CmdletBinding()]
param(
    [switch] $Probe,
    [string] $VMName = '',
    [string] $OutDir = (Join-Path $PSScriptRoot 'results'),
    [string] $PlayerBinary
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$description = 'Real mouse input in the console session; asserts on what the screen showed (combo box hover, #4276; playlist input, #3844 #3885; Keys page editing, #3853)'
$testsRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$repoRoot = Split-Path $testsRoot -Parent
$transport = Join-Path $testsRoot 'emulator\tools\GuestTransport.ps1'

if ($Probe) {
    $ready = $true; $reason = ''
    if (-not (Test-Path $transport)) { $ready = $false; $reason = 'emulator submodule not initialised (git submodule update --init tests/emulator)' }
    return [pscustomobject]@{ Suite = 'mouse'; Description = $description; Ready = $ready; Reason = $reason }
}

New-Item -ItemType Directory -Force $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path
$passed = 0; $failed = 0; $skipped = 0
$notes = [System.Collections.Generic.List[string]]::new()
function Note { param([string] $Colour, [string] $Text) $notes.Add($Text); Write-Host "  $Text" -ForegroundColor $Colour }
function Finish { [pscustomobject]@{ Suite = 'mouse'; Passed = $passed; Failed = $failed; Skipped = $skipped; Notes = $notes } }
function Complete-Case {
    param([string] $Name, [string[]] $Problems)
    $Problems = @($Problems | Where-Object { $_ })
    if ($Problems.Count -eq 0) { $script:passed++; Note Green "PASS $Name" }
    else { $script:failed++; Note Red "FAIL ${Name}: $($Problems -join ' | ')" }
}

# --- what is driven -----------------------------------------------------------

# The player's numbers come from the checkout's resource.h when this repository is mounted in one, so a
# renumbering there does not silently point the suite at another control. The defaults are develop's.
function Get-ResourceId {
    param([string] $Name, [int] $Default)
    $header = Join-Path $repoRoot 'src\mpc-hc\resource.h'
    if (Test-Path $header) {
        $hit = Select-String -Path $header -Pattern ("^#define\s+{0}\s+(\d+)" -f [regex]::Escape($Name)) | Select-Object -First 1
        if ($hit) { return [int]$hit.Matches[0].Groups[1].Value }
    }
    $Default
}
$idOptions      = Get-ResourceId 'ID_VIEW_OPTIONS' 815
$idThemePage    = Get-ResourceId 'IDD_PPAGETHEME' 10038
$idKeysPage     = Get-ResourceId 'IDD_PPAGEACCELTBL' 10032
$idKeysList     = Get-ResourceId 'IDC_LIST1' 11160               # the keys list on the Keys page
$idWinHotkey    = Get-ResourceId 'IDC_WINHOTKEY1' 11070          # the in-place hotkey editor
$idFontCombo    = Get-ResourceId 'IDC_COMBO5' 11004           # OSD font: over a hundred items
$idSeekbarCombo = Get-ResourceId 'IDC_TIMEONSEEKBAR' 22100    # three items

# The hover lands this long after the click that opens the list. The defect shows up to about 100 ms; the
# last value is the settled reference the others are compared with.
$quickDelays = 0, 30, 60, 100
$referenceDelay = 800

$playerDir = if ($PlayerBinary) { Split-Path (Resolve-Path $PlayerBinary).Path -Parent }
             elseif (Test-Path (Join-Path $repoRoot 'bin\mpc-hc_x64\mpc-hc64.exe')) { Join-Path $repoRoot 'bin\mpc-hc_x64' }
             else { $null }
if (-not $playerDir) { throw 'No player build: pass -PlayerBinary or build this repository (bin\mpc-hc_x64\mpc-hc64.exe).' }

$combocase = & (Join-Path $PSScriptRoot 'combocase\Build-ComboCase.ps1')

# Six short clips for the playlist cases, named so type-to-find has something to find: alpha, bravo,
# charlie, delta, doge, echo. doge is the second d-name: the type-ahead assertion turns on the search
# reaching delta rather than skipping past it. One video-only 4 s clip is generated once (gitignored
# media\) and copied under each name on the guest; video-only because a guest need not have an audio
# device at all.
$plClip = Join-Path $PSScriptRoot 'media\pl-clip.mkv'
if (-not (Test-Path $plClip)) {
    $ffmpeg = (Get-Command ffmpeg -ErrorAction SilentlyContinue).Source
    if ($ffmpeg) {
        New-Item -ItemType Directory -Force (Join-Path $PSScriptRoot 'media') | Out-Null
        & $ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'color=c=red:s=320x180:r=30:d=4' -c:v libx264 -pix_fmt yuv420p -preset veryfast $plClip
        if ($LASTEXITCODE -ne 0) { Remove-Item $plClip -Force -ErrorAction SilentlyContinue }
    }
}
$havePlaylistMedia = Test-Path $plClip

# --- target -------------------------------------------------------------------

. $transport
$cfg = Get-TestBedConfig
$session = Connect-TestGuest -Guest $VMName
try {
    $console = Invoke-Command -Session $session { (Get-CimInstance Win32_ComputerSystem).UserName }
    $consoleUser = if ($cfg.GuestConsoleUser) { $cfg.GuestConsoleUser } else { ("$console" -split '\\')[-1] }
    if (-not $consoleUser) { throw 'Nobody is logged on at the guest console; real mouse input needs a desktop.' }

    # Deploy: the guest scripts, the control program, and the player. The combo cases only open the
    # Options dialog (exe and icon library), but the playlist cases really play short clips, so the stage
    # gets what playback needs: LAV Filters to decode, and D3DX9_43.dll or EVR-CP stops on a modal
    # "missing d3dx9_43.dll" box on a clean guest (the installer ships it from distrib\x64, two levels
    # above bin\mpc-hc_x64).
    $stage = Join-Path $OutDir 'player-stage'
    if (Test-Path $stage) { Get-ChildItem $stage -Recurse -File | ForEach-Object { [IO.File]::Delete($_.FullName) } }
    New-Item -ItemType Directory -Force $stage | Out-Null
    Copy-Item (Join-Path $playerDir 'mpc-hc64.exe') $stage
    if (Test-Path (Join-Path $playerDir 'mpciconlib.dll')) { Copy-Item (Join-Path $playerDir 'mpciconlib.dll') $stage }
    $lavDir = Join-Path $playerDir 'LAVFilters64'
    $haveLav = Test-Path (Join-Path $lavDir 'LAVSplitter.ax')
    if ($haveLav) {
        New-Item -ItemType Directory -Force (Join-Path $stage 'LAVFilters64') | Out-Null
        Get-ChildItem $lavDir -File | Where-Object { $_.Extension -in '.ax', '.dll', '.manifest' } | Copy-Item -Destination (Join-Path $stage 'LAVFilters64')
    }
    $d3dx = @((Join-Path $playerDir 'D3DX9_43.dll'), (Join-Path $playerDir '..\..\distrib\x64\D3DX9_43.dll')) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($d3dx) { Copy-Item $d3dx (Join-Path $stage 'D3DX9_43.dll') }
    $zip = Join-Path $OutDir 'player.zip'
    if (Test-Path $zip) { [IO.File]::Delete($zip) }
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip

    Invoke-Command -Session $session {
        Get-Process mpc-hc64, combocase -ErrorAction SilentlyContinue | Stop-Process -Force
        foreach ($d in 'C:\mpc-test', 'C:\mpc-test\mouse', 'C:\mpc-test\mouse\out') { if (-not (Test-Path $d)) { New-Item -ItemType Directory $d | Out-Null } }
    }
    Copy-Item -ToSession $session $zip 'C:\mpc-test\mouse\player.zip' -Force
    foreach ($f in 'MouseInput.guest.ps1', 'Run-ComboHoverCase.guest.ps1', 'Run-PlaylistInputCase.guest.ps1', 'Run-KeysEditCase.guest.ps1') { Copy-Item -ToSession $session (Join-Path $PSScriptRoot $f) 'C:\mpc-test\mouse\' -Force }
    if ($combocase) { Copy-Item -ToSession $session $combocase 'C:\mpc-test\mouse\combocase.exe' -Force }
    Invoke-Command -Session $session {
        if (Test-Path 'C:\mpc-test\mouse\player') { Remove-Item 'C:\mpc-test\mouse\player' -Recurse -Force }
        Expand-Archive 'C:\mpc-test\mouse\player.zip' 'C:\mpc-test\mouse\player' -Force
        # The case runs as the console user, who has to be able to write its results here. The grant is
        # inheritable, so the media copied in below picks it up too.
        & icacls 'C:\mpc-test\mouse' /grant 'Users:(OI)(CI)M' /T | Out-Null
    }
    if ($havePlaylistMedia) {
        Copy-Item -ToSession $session $plClip 'C:\mpc-test\mouse\pl-clip.mkv' -Force
        Invoke-Command -Session $session {
            $pl = 'C:\mpc-test\mouse\media\pl'
            if (Test-Path $pl) { Remove-Item $pl -Recurse -Force }
            New-Item -ItemType Directory $pl | Out-Null
            foreach ($n in 'alpha', 'bravo', 'charlie', 'delta', 'doge', 'echo') { Copy-Item 'C:\mpc-test\mouse\pl-clip.mkv' "$pl\$n.mkv" }
        }
    }
    $version = Invoke-Command -Session $session { (Get-Item 'C:\mpc-test\mouse\player\mpc-hc64.exe').VersionInfo.ProductVersion }
    Note Gray "player under test: $version from $playerDir"

    # --- one job ----------------------------------------------------------------

    function Invoke-ComboJob {
        param(
            [string] $Name,
            [string] $Exe,
            [string] $TopClass,
            [int[]] $ComboIds,
            [int[]] $DelaysMs,
            [int] $PostCommand = 0,
            [string] $DialogTitle = '',
            [string] $IniText = '',          # non-empty: a fresh portable profile for the player
            [switch] $Pick
        )
        $guestOut = "C:\mpc-test\mouse\out\$Name"
        $job = @{
            Exe = $Exe; ArgumentLine = ''; TopClass = $TopClass; PostCommand = $PostCommand; DialogTitle = $DialogTitle
            ComboIds = $ComboIds; DelaysMs = $DelaysMs; Pick = [bool]$Pick; OutDir = $guestOut
        } | ConvertTo-Json
        $json = Invoke-Command -Session $session -ArgumentList $job, $guestOut, $IniText, $consoleUser {
            param($job, $out, $iniText, $user)
            $ErrorActionPreference = 'Continue'
            Get-Process mpc-hc64, combocase -ErrorAction SilentlyContinue | Stop-Process -Force
            if (Test-Path $out) { Remove-Item $out -Recurse -Force }
            New-Item -ItemType Directory $out | Out-Null
            & icacls $out /grant 'Users:(OI)(CI)M' | Out-Null
            if ($iniText) {
                # An ini beside the exe puts the player in portable mode: nothing of the last case, or of whoever
                # used this guest before, carries over, and no user hive is involved.
                Get-ChildItem 'C:\mpc-test\mouse\player' -Filter '*.ini' | ForEach-Object { [IO.File]::Delete($_.FullName) }
                [IO.File]::WriteAllText('C:\mpc-test\mouse\player\mpc-hc64.ini', $iniText, [Text.Encoding]::Unicode)
            }
            [IO.File]::WriteAllText('C:\mpc-test\mouse\job.json', $job)

            $taskArgs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\mpc-test\mouse\Run-ComboHoverCase.guest.ps1 -Job C:\mpc-test\mouse\job.json'
            $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $taskArgs
            $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive
            Register-ScheduledTask -TaskName 'MpcMouseCase' -Action $action -Principal $principal -Force | Out-Null
            Start-ScheduledTask -TaskName 'MpcMouseCase'
            $deadline = (Get-Date).AddSeconds(240)
            while (-not (Test-Path "$out\result.json") -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
            Unregister-ScheduledTask -TaskName 'MpcMouseCase' -Confirm:$false
            Get-Process mpc-hc64, combocase -ErrorAction SilentlyContinue | Stop-Process -Force
            if (Test-Path "$out\result.json") { Get-Content "$out\result.json" -Raw } else { $null }
        }
        if (-not $json) { throw "job $Name produced no result on the guest" }
        $local = Join-Path $OutDir $Name
        if (Test-Path $local) { Get-ChildItem $local -File | ForEach-Object { [IO.File]::Delete($_.FullName) } }
        New-Item -ItemType Directory -Force $local | Out-Null
        Copy-Item -FromSession $session "$guestOut\*" -Destination $local -Force
        $run = $json | ConvertFrom-Json
        if ($run.error) { throw "job $Name failed on the guest: $($run.error)" }
        [pscustomobject]@{ Run = $run; Dir = $local }
    }

    # The playlist job: one launch of the player with the six clips playing, Run-PlaylistInputCase driving
    # real mouse and keyboard input at the playlist. Same scheduled-task shape as the combo job.
    function Invoke-PlaylistJob {
        param([string] $Name, [string] $ArgumentLine, [string] $IniText)
        $guestOut = "C:\mpc-test\mouse\out\$Name"
        $job = @{ Exe = 'C:\mpc-test\mouse\player\mpc-hc64.exe'; ArgumentLine = $ArgumentLine; OutDir = $guestOut } | ConvertTo-Json
        $json = Invoke-Command -Session $session -ArgumentList $job, $guestOut, $IniText, $consoleUser {
            param($job, $out, $iniText, $user)
            $ErrorActionPreference = 'Continue'
            Get-Process mpc-hc64, combocase -ErrorAction SilentlyContinue | Stop-Process -Force
            if (Test-Path $out) { Remove-Item $out -Recurse -Force }
            New-Item -ItemType Directory $out | Out-Null
            & icacls $out /grant 'Users:(OI)(CI)M' | Out-Null
            Get-ChildItem 'C:\mpc-test\mouse\player' -Filter '*.ini' | ForEach-Object { [IO.File]::Delete($_.FullName) }
            # A command-line open would replace a restored playlist, but do not leave one around either way.
            Remove-Item 'C:\mpc-test\mouse\player\default.mpcpl' -Force -ErrorAction SilentlyContinue
            [IO.File]::WriteAllText('C:\mpc-test\mouse\player\mpc-hc64.ini', $iniText, [Text.Encoding]::Unicode)
            [IO.File]::WriteAllText('C:\mpc-test\mouse\job.json', $job)

            $taskArgs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\mpc-test\mouse\Run-PlaylistInputCase.guest.ps1 -Job C:\mpc-test\mouse\job.json'
            $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $taskArgs
            $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive
            Register-ScheduledTask -TaskName 'MpcMouseCase' -Action $action -Principal $principal -Force | Out-Null
            Start-ScheduledTask -TaskName 'MpcMouseCase'
            $deadline = (Get-Date).AddSeconds(240)
            while (-not (Test-Path "$out\result.json") -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
            Unregister-ScheduledTask -TaskName 'MpcMouseCase' -Confirm:$false
            Get-Process mpc-hc64, combocase -ErrorAction SilentlyContinue | Stop-Process -Force
            if (Test-Path "$out\result.json") { Get-Content "$out\result.json" -Raw } else { $null }
        }
        if (-not $json) { throw "job $Name produced no result on the guest" }
        $local = Join-Path $OutDir $Name
        if (Test-Path $local) { Get-ChildItem $local -File | ForEach-Object { [IO.File]::Delete($_.FullName) } }
        New-Item -ItemType Directory -Force $local | Out-Null
        Copy-Item -FromSession $session "$guestOut\*" -Destination $local -Force
        $run = $json | ConvertFrom-Json
        if ($run.error) { throw "job $Name failed on the guest: $($run.error)" }
        [pscustomobject]@{ Run = $run; Dir = $local }
    }

    # The Keys job: one launch of the player with no media, Options opened at the Keys page,
    # Run-KeysEditCase driving a real double-click at the keys list. Same scheduled-task shape as the
    # playlist job.
    function Invoke-KeysJob {
        param([string] $Name, [string] $IniText)
        $guestOut = "C:\mpc-test\mouse\out\$Name"
        $job = @{
            Exe = 'C:\mpc-test\mouse\player\mpc-hc64.exe'; ArgumentLine = ''; OutDir = $guestOut
            PostCommand = $idOptions; DialogTitle = 'Options'; ListId = $idKeysList
        } | ConvertTo-Json
        $json = Invoke-Command -Session $session -ArgumentList $job, $guestOut, $IniText, $consoleUser {
            param($job, $out, $iniText, $user)
            $ErrorActionPreference = 'Continue'
            Get-Process mpc-hc64, combocase -ErrorAction SilentlyContinue | Stop-Process -Force
            if (Test-Path $out) { Remove-Item $out -Recurse -Force }
            New-Item -ItemType Directory $out | Out-Null
            & icacls $out /grant 'Users:(OI)(CI)M' | Out-Null
            Get-ChildItem 'C:\mpc-test\mouse\player' -Filter '*.ini' | ForEach-Object { [IO.File]::Delete($_.FullName) }
            # A command-line open would replace a restored playlist, but do not leave one around either way.
            Remove-Item 'C:\mpc-test\mouse\player\default.mpcpl' -Force -ErrorAction SilentlyContinue
            [IO.File]::WriteAllText('C:\mpc-test\mouse\player\mpc-hc64.ini', $iniText, [Text.Encoding]::Unicode)
            [IO.File]::WriteAllText('C:\mpc-test\mouse\job.json', $job)

            $taskArgs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\mpc-test\mouse\Run-KeysEditCase.guest.ps1 -Job C:\mpc-test\mouse\job.json'
            $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $taskArgs
            $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive
            Register-ScheduledTask -TaskName 'MpcMouseCase' -Action $action -Principal $principal -Force | Out-Null
            Start-ScheduledTask -TaskName 'MpcMouseCase'
            $deadline = (Get-Date).AddSeconds(240)
            while (-not (Test-Path "$out\result.json") -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
            Unregister-ScheduledTask -TaskName 'MpcMouseCase' -Confirm:$false
            Get-Process mpc-hc64, combocase -ErrorAction SilentlyContinue | Stop-Process -Force
            if (Test-Path "$out\result.json") { Get-Content "$out\result.json" -Raw } else { $null }
        }
        if (-not $json) { throw "job $Name produced no result on the guest" }
        $local = Join-Path $OutDir $Name
        if (Test-Path $local) { Get-ChildItem $local -File | ForEach-Object { [IO.File]::Delete($_.FullName) } }
        New-Item -ItemType Directory -Force $local | Out-Null
        Copy-Item -FromSession $session "$guestOut\*" -Destination $local -Force
        $run = $json | ConvertFrom-Json
        if ($run.error) { throw "job $Name failed on the guest: $($run.error)" }
        [pscustomobject]@{ Run = $run; Dir = $local }
    }

    Add-Type -AssemblyName System.Drawing

    # How many pixels of a combo's face differ between two captures. The face is the part that shows the
    # selected item: inside the border, left of the drop-down button.
    function Get-FaceDifference {
        param([string] $PngA, [string] $PngB, $Combo, $Shot)
        $a = [System.Drawing.Bitmap]::FromFile($PngA); $b = [System.Drawing.Bitmap]::FromFile($PngB)
        try {
            $x0 = $Combo.rect.L + 3 - $Shot.L; $x1 = $Combo.button.L - 2 - $Shot.L
            $y0 = $Combo.rect.T + 3 - $Shot.T; $y1 = $Combo.rect.B - 3 - $Shot.T
            $count = 0
            for ($y = $y0; $y -lt $y1; $y++) {
                for ($x = $x0; $x -lt $x1; $x++) {
                    $p = $a.GetPixel($x, $y); $q = $b.GetPixel($x, $y)
                    if ([math]::Max([math]::Max([math]::Abs($p.R - $q.R), [math]::Abs($p.G - $q.G)), [math]::Abs($p.B - $q.B)) -gt 48) { $count++ }
                }
            }
            $count
        } finally { $a.Dispose(); $b.Dispose() }
    }

    function Get-Record {
        param($Job, [int] $ComboId, [string] $Run, [string] $State)
        @($Job.Run.records | Where-Object { $_.combo -eq $ComboId -and $_.run -eq $Run -and $_.state -eq $State })[0]
    }

    # With the list just opened and the pointer on an item, the face must be the same face as once everything
    # has settled. -ExpectEcho inverts it, for the control that proves the harness can see the defect.
    function Test-ComboHover {
        param($Job, [int[]] $ComboIds, [switch] $ExpectEcho)
        $problems = @()
        foreach ($id in $ComboIds) {
            $combo = @($Job.Run.combos | Where-Object { $_.id -eq $id })[0]
            if (-not $combo -or -not $combo.found) { $problems += "combo $id was not found in the window"; continue }
            $ref = Get-Record $Job $id "d$referenceDelay" 'hover'
            # A case only means something if the pointer really reached the list and moved its selection.
            if (-not $ref -or -not $ref.listOpen -or $ref.sel -eq $combo.selected) { $problems += "combo ${id}: the settled hover never reached the list"; continue }
            $echoes = @()
            foreach ($delay in $quickDelays) {
                $hover = Get-Record $Job $id "d$delay" 'hover'
                if (-not $hover -or -not $hover.listOpen -or $hover.sel -eq $combo.selected) { $problems += "combo $id at $delay ms: the hover did not move the list selection, so nothing was tested"; continue }
                $diff = Get-FaceDifference (Join-Path $Job.Dir $hover.png) (Join-Path $Job.Dir $ref.png) $combo $Job.Run.shot
                if ($diff -gt 8) { $echoes += "$delay ms ($diff px)" }
                $closed = Get-Record $Job $id "d$delay" 'closed'
                if ($closed.listOpen) { $problems += "combo $id at $delay ms: the list was still open after the closing click" }
                elseif ($closed.sel -ne $combo.selected) { $problems += "combo $id at $delay ms: closing without a pick left item $($closed.sel) selected, it was $($combo.selected)" }
            }
            if ($ExpectEcho) {
                if (-not $echoes) { $problems += "combo ${id}: no change of the face was seen at any delay" }
            } elseif ($echoes) {
                $problems += "combo $id ('$($combo.text)' selected): the face shows something else with the pointer on a list item, at $($echoes -join ', ')"
            }
        }
        $problems
    }

    function Test-ComboPick {
        param($Job, [int[]] $ComboIds)
        $problems = @()
        foreach ($id in $ComboIds) {
            $combo = @($Job.Run.combos | Where-Object { $_.id -eq $id })[0]
            if (-not $combo -or -not $combo.found) { $problems += "combo $id was not found in the window"; continue }
            $hover = Get-Record $Job $id 'pick' 'hover'; $closed = Get-Record $Job $id 'pick' 'closed'
            if (-not $hover -or -not $hover.listOpen -or $hover.sel -eq $combo.selected) { $problems += "combo ${id}: the pointer never reached a list item to click"; continue }
            if ($closed.listOpen) { $problems += "combo ${id}: the list stayed open after an item was clicked" }
            elseif ($closed.sel -ne $hover.sel) { $problems += "combo ${id}: clicking item $($hover.sel) left item $($closed.sel) selected" }
        }
        $problems
    }

    # Shared gate for the playlist cases: a run only means something if the list was found holding the
    # six clips, alpha really was playing (the title names it), and the list really had keyboard focus
    # when the driving started.
    function Test-PlaylistBase {
        param($Job)
        $run = $Job.Run
        if (-not $run.list -or -not $run.list.found) { return @('the playlist list control was not found') }
        $problems = @()
        if ($run.list.count -ne 6) { $problems += "the playlist holds $($run.list.count) entries, expected 6" }
        if (-not $run.list.visible) { $problems += 'the playlist was not shown at start' }
        if ($run.list.titleAtStart -notlike '*alpha*') { $problems += "alpha.mkv never played: the title is '$($run.list.titleAtStart)'" }
        if ($problems.Count) { return $problems }
        if (-not $run.setup.foregroundIsPlayer) { $problems += 'the player was not the foreground window when input started' }
        if (-not $run.setup.focusIsList) { $problems += 'the playlist list did not have keyboard focus after the setup clicks' }
        $problems
    }

    function Test-PlaylistTypeToFind {
        param($Job)
        $problems = @(Test-PlaylistBase $Job)
        if ($problems.Count) { return $problems }
        $b = $Job.Run.caseA
        if (-not $b) { return $problems + 'the guest run ended before the type-to-find steps' }
        if ($b.selAlpha -ne 0) { $problems += "the click on alpha left entry $($b.selAlpha) selected, expected 0" }
        if ($b.selAfterD1 -ne 3) { $problems += "typing 'd' with alpha selected left entry $($b.selAfterD1) selected, expected 3 (delta)" }
        if ($b.selCharlie -ne 2) { $problems += "the click on charlie left entry $($b.selCharlie) selected, expected 2" }
        # The keystroke that tells c215310313 from the unfixed `idx > startidx`: charlie selected (row 2),
        # so comctl starts the search at row 3, which is delta and itself matches. The fixed handler
        # returns it; the unfixed one skips past it and lands on doge (row 4).
        if ($b.selAfterD2 -ne 3) { $problems += "typing 'd' with charlie selected left entry $($b.selAfterD2) selected, expected 3 (delta): the search skipped the item it started from" }
        $problems
    }

    function Test-PlaylistTimeColumn {
        param($Job)
        $problems = @(Test-PlaylistBase $Job)
        if ($problems.Count) { return $problems }
        $cc = $Job.Run.caseB
        if (-not $cc) { return $problems + 'the guest run ended before the time-column steps' }
        if (-not $cc.timeTextRow0) { $problems += "the time column never showed the played entry's duration" }
        if ($cc.selBravo -ne 1) { $problems += "the click on bravo left entry $($cc.selBravo) selected, expected 1" }
        # A click on the selected entry may start renaming it; what #3885 reported is the editor taking
        # the time cell's text ("it copies time there").
        # Measured on 2.7.1.16: the editor opens empty on an entry with no duration yet; develop opens it on
        # the name.
        if ($cc.editSeenTime -and "$($cc.editTextTime)" -ne "$($cc.nameRow1)") {
            $problems += "a click on the time column opened an editor holding '$($cc.editTextTime)', not the entry's name '$($cc.nameRow1)' (#3885 item 1)"
        }
        $problems
    }

    function Test-KeysEdit {
        param($Job)
        $run = $Job.Run
        if (-not $run.list -or -not $run.list.found) { return @('the Keys page list control was not found') }
        $problems = @()
        if ($run.list.count -lt 3) { $problems += "the Keys list holds $($run.list.count) entries, expected many" }
        if ($problems.Count) { return $problems }
        if (-not $run.setup.foregroundIsDialog) { $problems += 'the Options dialog was not the foreground window when input started' }
        if (-not $run.setup.focusIsList) { $problems += 'the Keys list did not have keyboard focus after the setup click' }
        if ($problems.Count) { return $problems }
        $k = $run.caseK
        if (-not $k) { return $problems + 'the guest run ended before the double-click step' }
        if ($k.selectedBeforeDbl -ne 1) { $problems += "the click on the key cell left row $($k.selectedBeforeDbl) selected, expected 1" }
        # The unfixed build arms a GetDoubleClickTime() edit timer on the first click and the second click
        # of the double-click (WM_LBUTTONDBLCLK) kills it before it fires; the fixed build's 1 ms timer
        # fires on that first click. So the editor is the fix, seen from outside.
        if (-not $k.editSeen) { $problems += 'no in-place editor (an Edit child of the list) appeared within 1 s of the double-click (#3853)' }
        elseif ($k.editId -ne $idWinHotkey) { $problems += "the in-place editor's control id is $($k.editId), expected $idWinHotkey (IDC_WINHOTKEY1)" }
        $problems
    }

    # --- cases ------------------------------------------------------------------

    # 1. The controls. 101 is a plain comctl32 combo; 105 is the same combo, invalidated on mouse-leave.
    if ($combocase) {
        $c = Invoke-ComboJob -Name 'control' -Exe 'C:\mpc-test\mouse\combocase.exe' -TopClass 'ComboCase' -ComboIds 101, 105 -DelaysMs ($quickDelays + $referenceDelay)
        Complete-Case 'control-plain-windows-combo' (Test-ComboHover $c 101)
        $control = @(Test-ComboHover $c 105 -ExpectEcho)
        Complete-Case 'control-harness-detects-echo' $control
        if ($control.Count) { Note Yellow 'the harness did not reproduce a known echo on this target, so a pass below proves nothing' }
    } else {
        $skipped += 2
        Note Yellow 'controls not run: no Visual Studio C++ toolset to build combocase.exe with; the player cases below are unproven without them'
    }

    # 2. The player, in both themes: the defect of #4276 was in neither's painting but in an invalidate both
    #    share, so one theme passing says nothing about the other.
    foreach ($theme in @{ Name = 'modern'; Value = 1 }, @{ Name = 'classic'; Value = 0 }) {
        $ini = "[Settings]`r`nUpdaterAutoCheck=0`r`nKeepHistory=0`r`nMPCTheme=$($theme.Value)`r`nModernThemeMode=0`r`nLastUsedPage=$idThemePage`r`nOSDFont=Calibri`r`n"
        $c = Invoke-ComboJob -Name "player-$($theme.Name)" -Exe 'C:\mpc-test\mouse\player\mpc-hc64.exe' -TopClass 'MediaPlayerClassicW' `
                 -PostCommand $idOptions -DialogTitle 'Options' -ComboIds $idFontCombo, $idSeekbarCombo `
                 -DelaysMs ($quickDelays + $referenceDelay) -IniText $ini -Pick
        Complete-Case "combo-hover-keeps-selected-item-$($theme.Name)" (Test-ComboHover $c $idFontCombo, $idSeekbarCombo)
        Complete-Case "combo-click-selects-item-$($theme.Name)" (Test-ComboPick $c $idFontCombo, $idSeekbarCombo)
    }

    # 3-4. The playlist under real input. One job drives both cases in one player instance: type-to-find
    #    (54b5aaa66b, c215310313; #3844) and a click on the time column that must not open an in-place
    #    editor holding the time (419dadc920; #3885 item 1). LoopMode=0 and AfterPlayback=0 so nothing
    #    advances by itself. The guest script's header has the reasoning for each assertion.
    if ($havePlaylistMedia -and $haveLav) {
        $plIni = "[Settings]`r`nUpdaterAutoCheck=0`r`nKeepHistory=0`r`nAllowMultipleInstances=0`r`nLoop=0`r`nLoopMode=0`r`nAfterPlayback=0`r`nShowOSD=0`r`n`r`n[ToolBars\Playlist]`r`nVisible=1`r`n"
        $argLine = (@('alpha', 'bravo', 'charlie', 'delta', 'doge', 'echo') | ForEach-Object { '"C:\mpc-test\mouse\media\pl\{0}.mkv"' -f $_ }) -join ' '
        $c = Invoke-PlaylistJob -Name 'playlist-input' -ArgumentLine "$argLine /play" -IniText $plIni
        Complete-Case 'playlist-type-to-find' (Test-PlaylistTypeToFind $c)
        Complete-Case 'playlist-click-time-column-no-edit' (Test-PlaylistTimeColumn $c)
    } else {
        $skipped += 2
        $why = @()
        if (-not $havePlaylistMedia) { $why += 'no media\pl-clip.mkv and no ffmpeg on PATH to make one' }
        if (-not $haveLav) { $why += "no LAVFilters64 beside the player ($playerDir)" }
        Note Yellow "playlist cases not run: $($why -join '; ')"
    }

    # 5. The Keys page of Options: a double-click on a key entry's hotkey cell must open the in-place
    #    hotkey editor (#3853, f17f348494). It plays nothing, so it runs even when the playlist cases are
    #    skipped, in its own player instance.
    $keysIni = "[Settings]`r`nUpdaterAutoCheck=0`r`nKeepHistory=0`r`nLastUsedPage=$idKeysPage`r`n"
    $c = Invoke-KeysJob -Name 'keys-edit' -IniText $keysIni
    Complete-Case 'keys-double-click-edits' (Test-KeysEdit $c)
}
finally {
    Remove-PSSession $session -ErrorAction SilentlyContinue
}

Finish
