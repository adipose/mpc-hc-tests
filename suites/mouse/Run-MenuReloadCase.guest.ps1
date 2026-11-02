# Runs on the target, in the console session. Rebuilds the player's menus with a menu open, then walks the
# menu with the keyboard and closes the player. One JSON object goes to <OutDir>\result.json; the host asserts.
#
# CMainFrame::ReloadMenus deletes the old menu, which frees the MenuObject each owner drawn item keeps in its
# item data. Windows keeps a menu it is showing alive, so the open popup goes on sending WM_MEASUREITEM with
# the freed pointers. Unfixed, the next submenu crashed in CMPCThemeMenu::MeasureItem or the heap was reported
# corrupt (#4257). A change of the system metrics reaches ReloadMenus through OnSettingChange, so a user only
# has to have a menu open when one arrives. The same reload with the menu closed is the control.
#
# WM_SETTINGCHANGE is sent, not posted: it carries a string, so Windows will not post it to another process.
# The menu handle changing is the proof a reload ran. Without it a clean exit says nothing.
param([Parameter(Mandatory)] [string] $Job)

$ErrorActionPreference = 'Stop'
$j = Get-Content -Raw $Job | ConvertFrom-Json
$outDir = $j.OutDir
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory $outDir | Out-Null }
$result = [ordered]@{ case = $j.Case; error = $null; notes = @(); reloads = 0; rounds = 0; inMenuWhenSent = 0; crashBox = $null; exited = $false; exitCode = $null }
$sw = [Diagnostics.Stopwatch]::StartNew()
function Note([string] $s) { $result.notes += ('{0,6} {1}' -f [int]$sw.ElapsedMilliseconds, $s) }

. (Join-Path $PSScriptRoot 'MouseInput.guest.ps1')

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class MenuProbe {
  [DllImport("user32.dll")] public static extern IntPtr GetMenu(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr SendMessageTimeout(IntPtr h, uint m, IntPtr w, IntPtr l, uint f, uint t, out IntPtr r);
  [DllImport("user32.dll")] static extern bool GetGUIThreadInfo(uint tid, byte[] g);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  public static bool InMenu(IntPtr main) {          // GUI_INMENUMODE
    uint pid; uint tid = GetWindowThreadProcessId(main, out pid);
    byte[] g = new byte[72]; g[0] = 72;
    return GetGUIThreadInfo(tid, g) && (BitConverter.ToInt32(g, 4) & 4) != 0;
  }
}
'@

$proc = $null
$main = [IntPtr]::Zero
function Test-Over {
    $proc.Refresh()
    if ($proc.HasExited) { return $true }
    $box = [MouseRig]::FindTop([uint32]$proc.Id, '', 'Unexpected error')
    if ($box -eq [IntPtr]::Zero) { return $false }
    $script:boxText = ''
    [void][MouseRig]::EnumChildWindows($box, [MouseRig+EnumProc] { param($c, $p) $script:boxText += (Get-WindowTextOf $c) + ' '; $true }, [IntPtr]::Zero)
    $result.crashBox = $script:boxText
    Save-ScreenRegion (Join-Path $outDir 'crash-box.png') 0 0 1024 768 | Out-Null
    $true
}
function Send-Metrics {
    $r = [IntPtr]::Zero
    # SPI_SETNONCLIENTMETRICS, no section string
    [void][MenuProbe]::SendMessageTimeout($main, 0x001A, [IntPtr]0x2A, [IntPtr]::Zero, 0, 8000, [ref]$r)
}

try {
    $t = Start-TargetWindow -Exe $j.Exe -ArgumentLine "/new `"$($j.Clip)`"" -TopClass 'MediaPlayerClassicW'
    $proc = $t.Process; $main = $t.Root
    Start-Sleep -Seconds 3
    $wr = New-Object MouseRig+RECT
    [void][MouseRig]::GetWindowRect($main, [ref]$wr)

    $over = $false
    foreach ($round in 1..[int]$j.Rounds) {
        $before = [MenuProbe]::GetMenu($main)
        if (-not $j.MenuOpen) { Send-Metrics; Start-Sleep -Milliseconds 600 }
        # View is the second entry of the menu bar. Its On Top submenu is where the reports crashed.
        [void][MouseRig]::MoveTo($wr.L + 59, $wr.T + 40); Start-Sleep -Milliseconds 250
        [void][MouseRig]::Click(); Start-Sleep -Milliseconds 500
        if ($j.MenuOpen) {
            if ([MenuProbe]::InMenu($main)) { $result.inMenuWhenSent++ }
            if ($round -eq 1) { Save-ScreenRegion (Join-Path $outDir 'menu-open.png') 0 0 1024 768 | Out-Null }
            Send-Metrics; Start-Sleep -Milliseconds 600
        }
        foreach ($i in 1..14) {
            if ($over = Test-Over) { break }
            [void][MouseRig]::KeyPress([uint16]$(if (($i % 3) -eq 2) { 0x27 } else { 0x28 }))
            Start-Sleep -Milliseconds 60
        }
        if ($over) { Note "over in round $round"; break }
        foreach ($k in 1..5) { [void][MouseRig]::KeyPress([uint16]0x1B); Start-Sleep -Milliseconds 80 }
        Start-Sleep -Milliseconds 500
        if ($over = Test-Over) { Note "over after round $round"; break }
        $result.rounds = $round
        if ([MenuProbe]::GetMenu($main) -ne $before) { $result.reloads++ }
    }

    if (-not $over) {
        [void][MouseRig]::PostMessage($main, 0x0010, [IntPtr]0, [IntPtr]0)
        for ($i = 0; $i -lt 60; $i++) { Start-Sleep -Milliseconds 500; if ($over = Test-Over) { break } }
        if (-not $over) { $result.error = 'the player did not close' }
    }
    $proc.Refresh()
    if ($proc.HasExited) { $result.exited = $true; $result.exitCode = $proc.ExitCode }
} catch {
    $result.error = "$_ at line $($_.InvocationInfo.ScriptLineNumber)"
}
$result | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $outDir 'result.json')
