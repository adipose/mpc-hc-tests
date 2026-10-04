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

$description = 'Real mouse input in the console session; asserts on what the screen showed (combo box hover, #4276)'
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

# --- target -------------------------------------------------------------------

. $transport
$cfg = Get-TestBedConfig
$session = Connect-TestGuest -Guest $VMName
try {
    $console = Invoke-Command -Session $session { (Get-CimInstance Win32_ComputerSystem).UserName }
    $consoleUser = if ($cfg.GuestConsoleUser) { $cfg.GuestConsoleUser } else { ("$console" -split '\\')[-1] }
    if (-not $consoleUser) { throw 'Nobody is logged on at the guest console; real mouse input needs a desktop.' }

    # Deploy: the two guest scripts, the control program, and the player (the Options dialog needs the exe and
    # the icon library, nothing else).
    $stage = Join-Path $OutDir 'player-stage'
    if (Test-Path $stage) { Get-ChildItem $stage -Recurse -File | ForEach-Object { [IO.File]::Delete($_.FullName) } }
    New-Item -ItemType Directory -Force $stage | Out-Null
    Copy-Item (Join-Path $playerDir 'mpc-hc64.exe') $stage
    if (Test-Path (Join-Path $playerDir 'mpciconlib.dll')) { Copy-Item (Join-Path $playerDir 'mpciconlib.dll') $stage }
    $zip = Join-Path $OutDir 'player.zip'
    if (Test-Path $zip) { [IO.File]::Delete($zip) }
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip

    Invoke-Command -Session $session {
        Get-Process mpc-hc64, combocase -ErrorAction SilentlyContinue | Stop-Process -Force
        foreach ($d in 'C:\mpc-test', 'C:\mpc-test\mouse', 'C:\mpc-test\mouse\out') { if (-not (Test-Path $d)) { New-Item -ItemType Directory $d | Out-Null } }
    }
    Copy-Item -ToSession $session $zip 'C:\mpc-test\mouse\player.zip' -Force
    foreach ($f in 'MouseInput.guest.ps1', 'Run-ComboHoverCase.guest.ps1') { Copy-Item -ToSession $session (Join-Path $PSScriptRoot $f) 'C:\mpc-test\mouse\' -Force }
    if ($combocase) { Copy-Item -ToSession $session $combocase 'C:\mpc-test\mouse\combocase.exe' -Force }
    Invoke-Command -Session $session {
        if (Test-Path 'C:\mpc-test\mouse\player') { Remove-Item 'C:\mpc-test\mouse\player' -Recurse -Force }
        Expand-Archive 'C:\mpc-test\mouse\player.zip' 'C:\mpc-test\mouse\player' -Force
        # The case runs as the console user, who has to be able to write its results here.
        & icacls 'C:\mpc-test\mouse' /grant 'Users:(OI)(CI)M' /T | Out-Null
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

    # --- evidence ---------------------------------------------------------------

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
}
finally {
    Remove-PSSession $session -ErrorAction SilentlyContinue
}

Finish
