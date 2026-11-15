<#
.SYNOPSIS
    The display suite: how the player's windows follow the DPI of the monitor
    they are on, measured on the host's own monitors.

.DESCRIPTION
    Cases:

      edit-menu-mixed-dpi    Open Options, walk the page tree to the first page
                             with a plain Edit, and right-click it (a posted
                             WM_CONTEXTMENU) with the dialog on one monitor and
                             then on a monitor at a different scaling. The
                             themed popup must scale with the dialog: the size
                             ratio between the two menus must be within 0.15 of
                             the ratio of the two DPIs, in the dark and in the
                             light modern theme. Guards clsid2/mpc-hc#4430,
                             before which CMPCThemeMenu measured its items at
                             the main window's DPI, so the menu came out the
                             same size on both monitors (378x413 at 144 and at
                             96 dpi). Skipped without two monitors at different
                             scaling; the suite never changes the scaling.

    Runs on the host, from a pane, against the interactive desktop: no rig.
    The player is copied into -OutDir with a portable ini of its own, so a
    settings file beside the exe under test is never read or written.
#>
[CmdletBinding()]
param(
    [switch] $Probe,
    [string] $VMName = '',
    [string] $OutDir = (Join-Path $PSScriptRoot 'results'),
    [Alias('Exe')] [string] $PlayerBinary,
    [string[]] $Case
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$description = 'Windows on monitors at different scaling: themed popup menus sized for the DPI of the window that tracks them; host only, no rig, needs two monitors at different scaling'
$repoRoot = Split-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path -Parent
if (-not $PlayerBinary) { $PlayerBinary = Join-Path $repoRoot 'bin\mpc-hc_x64\mpc-hc64.exe' }

if ($Probe) {
    $ready = Test-Path $PlayerBinary
    $reason = if ($ready) { '' } else { "no player at $PlayerBinary" }
    return [pscustomobject]@{ Suite = 'display'; Description = $description; Ready = $ready; Reason = $reason; NeedsRig = $false }
}

if (-not (Test-Path $PlayerBinary)) { throw "no player at $PlayerBinary" }
$PlayerBinary = (Resolve-Path $PlayerBinary).Path
New-Item -ItemType Directory -Force $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path
$passed = 0; $failed = 0; $skipped = 0
$notes = [System.Collections.Generic.List[string]]::new()
function Note { param([string] $Colour, [string] $Text) $notes.Add($Text); Write-Host "  $Text" -ForegroundColor $Colour }
function Report {
    param([string] $Name, [string[]] $Problems)
    if ($Problems.Count) { $script:failed++; Note Red "FAIL $Name`: $($Problems -join '; ')" }
    else { $script:passed++; Note Green "PASS $Name" }
}

# --- window and monitor plumbing ------------------------------------------------------

Add-Type -AssemblyName System.Drawing
if (-not ('MpcDisplay.W' -as [type])) {
    Add-Type -TypeDefinition @'
using System; using System.Text; using System.Collections.Generic; using System.Runtime.InteropServices;
namespace MpcDisplay {
public static class W {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  public delegate bool MonitorProc(IntPtr m, IntPtr dc, ref RECT r, IntPtr l);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct MONITORINFO { public int cbSize; public RECT Monitor; public RECT Work; public uint Flags; }
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] public static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr clip, MonitorProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool GetMonitorInfo(IntPtr m, ref MONITORINFO mi);
  [DllImport("shcore.dll")] public static extern int GetDpiForMonitor(IntPtr m, int type, out uint x, out uint y);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr h);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint f);
  public static string Cls(IntPtr h) { var s = new StringBuilder(256); GetClassName(h, s, 256); return s.ToString(); }
  public static string Txt(IntPtr h) { var s = new StringBuilder(256); GetWindowText(h, s, 256); return s.ToString(); }
  public static List<IntPtr> Tops(uint pid) {
    var o = new List<IntPtr>();
    EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p); if (p == pid && IsWindowVisible(h)) o.Add(h); return true; }, IntPtr.Zero);
    return o;
  }
  public static List<IntPtr> Kids(IntPtr parent) {
    var o = new List<IntPtr>();
    EnumChildWindows(parent, (h, l) => { o.Add(h); return true; }, IntPtr.Zero);
    return o;
  }
  public class Mon { public RECT Monitor; public RECT Work; public bool Primary; public uint Dpi; }
  public static List<Mon> Monitors() {
    var o = new List<Mon>();
    EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr m, IntPtr dc, ref RECT r, IntPtr l) => {
      var mi = new MONITORINFO(); mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
      GetMonitorInfo(m, ref mi);
      uint x, y; if (GetDpiForMonitor(m, 0, out x, out y) != 0) x = 0;   // MDT_EFFECTIVE_DPI
      o.Add(new Mon { Monitor = mi.Monitor, Work = mi.Work, Primary = (mi.Flags & 1) != 0, Dpi = x });
      return true;
    }, IntPtr.Zero);
    return o;
  }
}
}
'@
}
$W = [MpcDisplay.W]

# Per-monitor aware v2, so monitor DPIs and window rectangles are physical. The process setting fails when an
# earlier suite in the same pwsh has already fixed the awareness; the thread setting does not.
[void] $W::SetProcessDpiAwarenessContext([IntPtr] -4)
if ($W::SetThreadDpiAwarenessContext([IntPtr] -4) -eq [IntPtr]::Zero) { throw 'could not make this thread per-monitor DPI aware' }

function WaitFor([scriptblock] $f, [int] $ms = 10000) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $ms) { $r = & $f; if ($r) { return $r }; Start-Sleep -Milliseconds 100 }
    return $null
}
function Rect($h) { $r = New-Object MpcDisplay.W+RECT; [void] $W::GetWindowRect($h, [ref] $r); $r }
function Describe($m) { '{0} dpi at {1},{2} {3}x{4}{5}' -f $m.Dpi, $m.Monitor.L, $m.Monitor.T, ($m.Monitor.R - $m.Monitor.L), ($m.Monitor.B - $m.Monitor.T), $(if ($m.Primary) { ' (primary)' } else { '' }) }

$cases = @('edit-menu-mixed-dpi')
if ($Case) { $cases = $cases | Where-Object { $n = $_; $Case | Where-Object { $n -like $_ } } }

# --- edit-menu-mixed-dpi -------------------------------------------------------------------
#
# The edit's context menu is a CMPCThemeMenu tracked by the edit, in a dialog that can sit on a monitor whose
# DPI is not the main window's. Its items are owner drawn, and WM_MEASUREITEM is answered by the main frame,
# which measured them at its own DPI: on a 96 dpi monitor with the main window at 144 the menu came out 378x413,
# the size it has at 144. The fix measures at the DPI of the window that tracks the menu, so the menu shrinks
# with the dialog (262x269 against 378x413, as the native classic menu does: 264x276 against 369x375).
# The menu is found as the player's #32768 window, measured with GetWindowRect and captured with PrintWindow.

function Test-EditMenu {
    param([string] $Name, [int] $ThemeMode, $MainMon, $DialogMon)
    $problems = @()
    $dir = Join-Path $OutDir $Name
    $playerDir = Join-Path $dir 'player'
    if (Test-Path $playerDir) { Remove-Item $playerDir -Recurse -Force }
    New-Item -ItemType Directory -Force $playerDir | Out-Null
    Copy-Item $PlayerBinary $playerDir
    $iconLib = Join-Path (Split-Path $PlayerBinary -Parent) 'mpciconlib.dll'
    if (Test-Path $iconLib) { Copy-Item $iconLib $playerDir }
    Set-Content (Join-Path $playerDir 'mpc-hc64.ini') "[Settings]`r`nMPCTheme=1`r`nModernThemeMode=$ThemeMode`r`nUpdaterAutoCheck=0`r`n" -Encoding Unicode

    $proc = Start-Process (Join-Path $playerDir 'mpc-hc64.exe') -ArgumentList '/new' -PassThru
    $ownPid = [uint32] $proc.Id
    $sizes = @()
    try {
        $main = WaitFor { $W::Tops($ownPid) | Where-Object { $W::Cls($_) -like 'MediaPlayerClassicW*' } | Select-Object -First 1 } 30000
        if (-not $main) { throw 'no main window within 30 s' }
        $mw = $MainMon.Work
        [void] $W::SetWindowPos($main, [IntPtr]::Zero, $mw.L + 50, $mw.T + 50, [Math]::Min(1000, $mw.R - $mw.L - 100), [Math]::Min(700, $mw.B - $mw.T - 100), 0x14)   # NOZORDER|NOACTIVATE
        Start-Sleep 1
        $mainDpi = $W::GetDpiForWindow($main)
        if ($mainDpi -ne $MainMon.Dpi) { throw "main window is at $mainDpi dpi after the move, its monitor at $($MainMon.Dpi)" }

        [void] $W::PostMessage($main, 0x111, [IntPtr] 815, [IntPtr]::Zero)   # WM_COMMAND ID_VIEW_OPTIONS
        $dlg = WaitFor { $W::Tops($ownPid) | Where-Object { $W::Cls($_) -eq '#32770' } | Select-Object -First 1 }
        if (-not $dlg) { throw 'no Options dialog' }
        Start-Sleep 1
        $findEdit = { $W::Kids($dlg) | Where-Object { $W::Cls($_) -eq 'Edit' -and $W::IsWindowVisible($_) -and ($W::Cls($W::GetParent($_)) -ne 'ComboBox') } | Select-Object -First 1 }
        $tree = $W::Kids($dlg) | Where-Object { $W::Cls($_) -eq 'SysTreeView32' } | Select-Object -First 1
        if (-not $tree) { throw 'no page tree in the Options dialog' }
        $item = $W::SendMessage($tree, 0x110A, [IntPtr] 0, [IntPtr]::Zero)   # TVM_GETNEXTITEM TVGN_ROOT
        $n = 0
        while (-not (& $findEdit) -and $item -ne [IntPtr]::Zero -and $n -lt 40) {
            $item = $W::SendMessage($tree, 0x110A, [IntPtr] 6, $item)   # TVGN_NEXTVISIBLE
            if ($item -ne [IntPtr]::Zero) { [void] $W::SendMessage($tree, 0x110B, [IntPtr] 9, $item); Start-Sleep -Milliseconds 600 }   # TVM_SELECTITEM TVGN_CARET
            $n++
        }
        if (-not (& $findEdit)) { throw "no page with a plain Edit after $n steps through the tree" }

        foreach ($place in @(@{ name = 'main'; mon = $MainMon }, @{ name = 'other'; mon = $DialogMon })) {
            $wk = $place.mon.Work
            [void] $W::SetWindowPos($dlg, [IntPtr]::Zero, $wk.L + 50, $wk.T + 50, 0, 0, 0x15)   # NOSIZE|NOZORDER|NOACTIVATE
            Start-Sleep -Milliseconds 1500
            $dlgDpi = $W::GetDpiForWindow($dlg)
            if ($dlgDpi -ne $place.mon.Dpi) { throw "the dialog is at $dlgDpi dpi on the $($place.name) monitor, which is at $($place.mon.Dpi)" }
            $edit = & $findEdit
            if (-not $edit) { throw "no visible edit with the dialog on the $($place.name) monitor" }
            $er = Rect $edit
            $cx = [int] (($er.L + $er.R) / 2); $cy = [int] (($er.T + $er.B) / 2)
            $lp = [IntPtr] [long] ((($cy -band 0xFFFF) -shl 16) -bor ($cx -band 0xFFFF))
            [void] $W::PostMessage($edit, 0x7B, $edit, $lp)   # WM_CONTEXTMENU at the edit's centre
            $menu = WaitFor { $W::Tops($ownPid) | Where-Object { $W::Cls($_) -eq '#32768' } | Select-Object -First 1 } 5000
            if (-not $menu) { $problems += "no popup menu with the dialog on the $($place.name) monitor"; break }
            Start-Sleep -Milliseconds 700
            $mr = Rect $menu
            # not $w: PowerShell names are case-insensitive, and $W is the window class
            $menuW = $mr.R - $mr.L; $menuH = $mr.B - $mr.T
            $png = Join-Path $dir "$($place.name)-$($place.mon.Dpi)dpi.png"
            if ($menuW -gt 0 -and $menuH -gt 0) {
                $bmp = New-Object Drawing.Bitmap $menuW, $menuH
                $g = [Drawing.Graphics]::FromImage($bmp); $hdc = $g.GetHdc(); [void] $W::PrintWindow($menu, $hdc, 2); $g.ReleaseHdc($hdc); $g.Dispose()
                $bmp.Save($png, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
            }
            $sizes += [pscustomobject]@{ Place = $place.name; DialogDpi = $dlgDpi; MenuDpi = $W::GetDpiForWindow($menu); Width = $menuW; Height = $menuH }
            [void] $W::PostMessage($menu, 0x100, [IntPtr] 0x1B, [IntPtr]::Zero)   # WM_KEYDOWN VK_ESCAPE
            [void] (WaitFor { -not ($W::Tops($ownPid) | Where-Object { $W::Cls($_) -eq '#32768' }) } 3000)
            Start-Sleep -Milliseconds 500
        }
        $sizes | ConvertTo-Json | Set-Content (Join-Path $dir 'sizes.json')
        Note Gray ("{0}: edit found {1} page(s) into the tree; {2}" -f $Name, $n,(($sizes | ForEach-Object { '{0} {1}x{2} at {3} dpi' -f $_.Place, $_.Width, $_.Height, $_.DialogDpi }) -join ', '))

        if ($sizes.Count -eq 2) {
            $s1 = $sizes[0]; $s2 = $sizes[1]
            $r = [double] $DialogMon.Dpi / $MainMon.Dpi
            if ($s1.Width -le 0 -or $s1.Height -le 0) { $problems += "menu on the main monitor is $($s1.Width)x$($s1.Height)" }
            else {
                $rw = $s2.Width / $s1.Width; $rh = $s2.Height / $s1.Height
                $verdict = 'width ratio {0:N2}, height ratio {1:N2}, DPI ratio {2:N2}' -f $rw, $rh, $r
                Note Gray "${Name}: $verdict"
                if ([Math]::Abs($rw - $r) -gt 0.15 -or [Math]::Abs($rh - $r) -gt 0.15) {
                    $problems += "menu $($s1.Width)x$($s1.Height) at $($s1.DialogDpi) dpi, $($s2.Width)x$($s2.Height) at $($s2.DialogDpi) dpi: $verdict, not within 0.15"
                }
            }
        }

        [void] $W::PostMessage($dlg, 0x111, [IntPtr] 2, [IntPtr]::Zero)   # IDCANCEL
        Start-Sleep 1
        [void] $W::PostMessage($main, 0x10, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE
        if (-not $proc.WaitForExit(10000)) { $problems += 'player did not close on WM_CLOSE within 10 s' }
    } catch {
        $problems += "$_"
    } finally {
        if (-not $proc.HasExited) { Stop-Process -Id $ownPid -Force }
    }
    Report $Name $problems
}

if ($cases -contains 'edit-menu-mixed-dpi') {
    $name = 'edit-menu-mixed-dpi'
    $mons = @($W::Monitors())
    Note Gray ("monitors: " + (($mons | ForEach-Object { Describe $_ }) -join '; '))
    # The main window on the primary when some monitor differs from it, otherwise on any monitor that has a
    # differently scaled partner.
    $mainMon = $null; $dialogMon = $null
    foreach ($m in @($mons | Sort-Object { -not $_.Primary })) {
        $other = $mons | Where-Object { $_.Dpi -ne $m.Dpi -and $_.Dpi -gt 0 } | Select-Object -First 1
        if ($m.Dpi -gt 0 -and $other) { $mainMon = $m; $dialogMon = $other; break }
    }
    if (-not $mainMon) {
        $skipped++; Note Yellow "SKIP $name`: needs two monitors at different scaling ($($mons.Count) monitor(s), all at $(@($mons | ForEach-Object Dpi | Select-Object -Unique) -join '/') dpi)"
    } else {
        Note Gray "$name`: main window on $(Describe $mainMon), dialog on $(Describe $dialogMon); player: $PlayerBinary"
        Test-EditMenu "$name-dark" 0 $mainMon $dialogMon
        Test-EditMenu "$name-light" 1 $mainMon $dialogMon
    }
}

[pscustomobject]@{ Suite = 'display'; Passed = $passed; Failed = $failed; Skipped = $skipped; Notes = $notes }
