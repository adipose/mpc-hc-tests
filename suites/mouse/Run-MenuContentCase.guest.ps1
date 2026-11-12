# Opens one of the player's dynamically built submenus with real keyboard input and records what it holds:
# Favorites (CFavoritesRecent::SetupFavoritesSubMenu, filled from the profile's favorites on WM_INITMENUPOPUP)
# or File > Recent Files (SetupRecentFileSubMenu, filled from the media history). The items are read from the
# open popup's HMENU (MN_GETHMENU), so the job runs the classic theme, whose menus keep their strings; the
# modern theme's menus are owner-drawn and keep the text in the player's own memory.
#
# Job fields: Case, Exe, Clip, OutDir, Menu ('favorites' or 'recent').

param([Parameter(Mandatory)] [string] $Job)

$ErrorActionPreference = 'Stop'
$j = Get-Content -Raw $Job | ConvertFrom-Json
$outDir = $j.OutDir
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory $outDir | Out-Null }
$result = [ordered]@{ case = $j.Case; error = $null; notes = @(); parent = @(); items = @(); exited = $false; exitCode = $null }
$sw = [Diagnostics.Stopwatch]::StartNew()
function Note([string] $s) { $result.notes += ('{0,6} {1}' -f [int]$sw.ElapsedMilliseconds, $s) }

. (Join-Path $PSScriptRoot 'MouseInput.guest.ps1')

Add-Type @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class MenuRead {
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern int GetMenuItemCount(IntPtr m);
  [DllImport("user32.dll")] public static extern uint GetMenuState(IntPtr m, uint id, uint flags);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetMenuString(IntPtr m, uint id, StringBuilder s, int n, uint flags);
  // the open popup menus, topmost first, as their HMENUs
  public static List<IntPtr> OpenPopups() {
    List<IntPtr> l = new List<IntPtr>();
    EnumWindows((h, p) => {
      StringBuilder sb = new StringBuilder(64); GetClassName(h, sb, 64);
      if (sb.ToString() == "#32768" && IsWindowVisible(h)) {
        IntPtr m = SendMessage(h, 0x01E1 /* MN_GETHMENU */, IntPtr.Zero, IntPtr.Zero);
        if (m != IntPtr.Zero) l.Add(m);
      }
      return true;
    }, IntPtr.Zero);
    return l;
  }
  public static string[] Items(IntPtr m) {
    int n = GetMenuItemCount(m);
    List<string> l = new List<string>();
    for (int i = 0; i < n; i++) {
      uint st = GetMenuState(m, (uint)i, 0x400 /* MF_BYPOSITION */);
      if ((st & 0x800) != 0) { l.Add("-"); continue; }  // MF_SEPARATOR
      StringBuilder sb = new StringBuilder(512);
      GetMenuString(m, (uint)i, sb, 512, 0x400);
      l.Add(sb.ToString());
    }
    return l.ToArray();
  }
}
'@

$proc = $null
try {
    $t = Start-TargetWindow -Exe $j.Exe -ArgumentLine "/new `"$($j.Clip)`"" -TopClass 'MediaPlayerClassicW'
    $proc = $t.Process; $main = $t.Root
    if (-not $t.Foreground) { Note 'the player was not the foreground window after the caption click' }
    Start-Sleep -Seconds 3   # the clip is open, so the media history has its entry

    # Alt puts the menu bar in keyboard mode on File; Right moves along it, Down opens the selected menu.
    [void][MouseRig]::KeyPress([uint16]0x12); Start-Sleep -Milliseconds 300
    if ($j.Menu -eq 'favorites') {
        foreach ($i in 1..4) { [void][MouseRig]::KeyPress([uint16]0x27); Start-Sleep -Milliseconds 150 }   # View, Play, Navigate, Favorites
        [void][MouseRig]::KeyPress([uint16]0x28); Start-Sleep -Milliseconds 700
    } else {
        [void][MouseRig]::KeyPress([uint16]0x28); Start-Sleep -Milliseconds 700                              # File
        $file = @([MenuRead]::OpenPopups())
        if (-not $file) { throw 'the File menu did not open' }
        $result.parent = [MenuRead]::Items($file[0])
        $recent = @($result.parent | Where-Object { $_ -match '^Recent ' })
        if ($recent.Count -ne 1 -or $recent[0] -notmatch '&F') { throw "expected one 'Recent &Files' item in the File menu, found: $($recent -join ' | ')" }
        # its mnemonic opens the submenu; counting Down presses depends on where the menu put the first selection
        [void][MouseRig]::KeyPress([uint16]0x46); Start-Sleep -Milliseconds 700                              # F: Recent &Files
    }
    $open = @([MenuRead]::OpenPopups())
    Note "$($open.Count) popup(s) open"
    if ($open) { $result.items = [MenuRead]::Items($open[0]) }
    Save-ScreenRegion (Join-Path $outDir 'menu-open.png') 0 0 1024 768 | Out-Null

    foreach ($k in 1..4) { [void][MouseRig]::KeyPress([uint16]0x1B); Start-Sleep -Milliseconds 100 }
    [void][MouseRig]::PostMessage($main, 0x0010, [IntPtr]0, [IntPtr]0)
    if (-not $proc.WaitForExit(20000)) {
        $result.error = 'the player did not close'
        Save-ScreenRegion (Join-Path $outDir 'not-closed.png') 0 0 1024 768 | Out-Null   # an assert or a prompt shows here
    }
    $proc.Refresh()
    if ($proc.HasExited) { $result.exited = $true; $result.exitCode = $proc.ExitCode }
} catch {
    $result.error = "$_ at line $($_.InvocationInfo.ScriptLineNumber)"
}
$result | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $outDir 'result.json')
