# Runs on the target, in the console session. Right-clicks a themed edit box over and over, closing its menu
# with Escape each time, and counts the player's USER objects. One JSON object goes to <OutDir>\result.json;
# the host asserts.
#
# In the modern theme CMPCThemeEdit::OnContextMenu builds the edit's right-click menu itself: it loads
# comctl32's edit menu and owner draws its first popup. Unfixed, the loaded menu was never destroyed, and the
# popup was destroyed on its own while the loaded menu still held it, which frees nothing. Every right-click
# left the three menus behind (the loaded one, the popup, and its Unicode control character submenu), and a
# process stops getting windows and menus at 10000 USER objects.
#
# The edit is the filter box of Options > Player > Keys, which needs no media. The first few menus are not
# counted: they create what the theme makes once.
param([Parameter(Mandatory)] [string] $Job)

$ErrorActionPreference = 'Stop'
$j = Get-Content -Raw $Job | ConvertFrom-Json
$outDir = $j.OutDir
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory $outDir | Out-Null }
$result = [ordered]@{
    case = $j.Case; error = $null; notes = @(); editFound = $false; editClass = ''; foreground = $false
    clicks = 0; retries = 0; menusSeen = 0; menusClosed = 0; userBefore = $null; userAfter = $null; counts = @(); dialogOpen = $false
}
$sw = [Diagnostics.Stopwatch]::StartNew()
function Note([string] $s) { $result.notes += ('{0,6} {1}' -f [int]$sw.ElapsedMilliseconds, $s) }

. (Join-Path $PSScriptRoot 'MouseInput.guest.ps1')

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class GuiResources {
  [DllImport("user32.dll")] public static extern uint GetGuiResources(IntPtr process, uint flags);
}
'@

$proc = $null
function Get-UserObjects { [int][GuiResources]::GetGuiResources($proc.Handle, 1) }     # GR_USEROBJECTS
function Find-Menu { [MouseRig]::FindTop([uint32]$proc.Id, '#32768', '') }
function Wait-Menu([bool] $Open) {
    for ($i = 0; $i -lt 60; $i++) {
        if (((Find-Menu) -ne [IntPtr]::Zero) -eq $Open) { return $true }
        Start-Sleep -Milliseconds 25
    }
    $false
}

try {
    $t = Start-TargetWindow -Exe $j.Exe -ArgumentLine '/new' -TopClass 'MediaPlayerClassicW' -PostCommand ([int]$j.PostCommand) -DialogTitle $j.DialogTitle
    $proc = $t.Process; $dlg = $t.Root
    $result.foreground = $t.Foreground
    $edit = [MouseRig]::FindChild($dlg, [int]$j.EditId)
    if ($edit -eq [IntPtr]::Zero) { throw "no visible control with id $($j.EditId) in the dialog" }
    $result.editFound = $true
    $result.editClass = [MouseRig]::ClassOf($edit)
    $er = New-Object MouseRig+RECT
    [void][MouseRig]::GetWindowRect($edit, [ref]$er)
    $x = [int](($er.L + $er.R) / 2); $y = [int](($er.T + $er.B) / 2)

    # One right-click and one Escape. Escape is only pressed with the menu seen open: without a menu to take
    # it, it would close the Options dialog.
    function Invoke-Round {
        Move-PointerGlide $x $y
        Start-Sleep -Milliseconds 80
        [void][MouseRig]::ClickRight()
        $result.clicks++
        if (-not (Wait-Menu $true)) {
            # On the guest most right-clicks that follow a closed menu open nothing, on fixed and unfixed builds
            # alike, with the edit focused and the dialog in front; a second right-click 600 ms later always opens
            # it. So one retry, noted, and only a click that never opens a menu fails the case.
            Save-ScreenRegion (Join-Path $outDir "no-menu-$($result.clicks).png") 0 0 1024 768 | Out-Null
            Note "click $($result.clicks): no menu, foreground $([MouseRig]::ClassOf([MouseRig]::GetForegroundWindow())), focus $([MouseRig]::ClassOf([MouseRig]::FocusOf($dlg)))"
            Start-Sleep -Milliseconds 600
            [void][MouseRig]::ClickRight()
            $result.retries++
            if (-not (Wait-Menu $true)) { Note "retry: still no menu"; return $false }
            Note "retry: menu opened"
        }
        $result.menusSeen++
        if ($result.menusSeen -eq 1) { Save-ScreenRegion (Join-Path $outDir 'menu-open.png') 0 0 1024 768 | Out-Null }
        Start-Sleep -Milliseconds 80
        [void][MouseRig]::KeyPress([uint16]0x1B)
        if (-not (Wait-Menu $false)) { return $false }
        $result.menusClosed++
        # Off the edit and back, so every right-click is a fresh arrival rather than a repeat at one pixel.
        Move-PointerGlide ($x + 6) ($er.B + 30)
        $true
    }

    $ok = $true
    foreach ($i in 1..[int]$j.WarmUp) { if (-not ($ok = Invoke-Round)) { Note "warm-up round ${i}: the menu did not open or did not close"; break } }
    if ($ok) {
        Start-Sleep -Milliseconds 500
        $result.userBefore = Get-UserObjects
        $result.counts += $result.userBefore
        foreach ($i in 1..[int]$j.Rounds) {
            if (-not ($ok = Invoke-Round)) { Note "round ${i}: the menu did not open or did not close"; break }
            if (($i % 10) -eq 0) { Start-Sleep -Milliseconds 300; $result.counts += (Get-UserObjects) }
        }
        Start-Sleep -Milliseconds 500
        $result.userAfter = Get-UserObjects
    }
    $result.dialogOpen = ([MouseRig]::FindTop([uint32]$proc.Id, '', $j.DialogTitle) -ne [IntPtr]::Zero)
} catch {
    $result.error = "$_ at line $($_.InvocationInfo.ScriptLineNumber)"
}
$result | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $outDir 'result.json')
