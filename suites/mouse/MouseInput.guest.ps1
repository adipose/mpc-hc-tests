# Dot-sourced on the target by a mouse case script. Real mouse input through SendInput, and the small set of
# window helpers a case needs to aim it and to record what happened. Windows PowerShell 5.1, which is what a
# guest has; it must run in the console session (an interactive scheduled task), because SendInput reaches the
# desktop of the session it is called from and nothing else.
#
# Why real input and not posted messages: a posted WM_MOUSEMOVE goes to whichever window it is addressed to,
# whatever holds the capture, and it is queued wherever the sender happened to put it. Capture, leave tracking
# and the order input and paint messages arrive in are exactly what hover bugs depend on, and all three are only
# what Windows really does when the input comes from the input queue.

Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class MouseRig {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [StructLayout(LayoutKind.Sequential)] public struct COMBOBOXINFO {
    public int cbSize; public RECT rcItem; public RECT rcButton; public int stateButton;
    public IntPtr hwndCombo, hwndItem, hwndList;
  }
  [StructLayout(LayoutKind.Sequential)] public struct GUITHREADINFO {
    public int cbSize; public int flags;
    public IntPtr hwndActive, hwndFocus, hwndCapture, hwndMenuOwner, hwndMoveSize, hwndCaret;
    public RECT rcCaret;
  }
  [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT {
    public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo;
  }
  // 40 bytes on x64. SendInput rejects the call outright if the size is wrong, and moves nothing.
  [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public MOUSEINPUT mi; }

  [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr h);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessageW(IntPtr h, uint m, IntPtr w, StringBuilder l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool GetComboBoxInfo(IntPtr h, ref COMBOBOXINFO i);
  [DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint tid, ref GUITHREADINFO g);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr p);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);

  public static string ClassOf(IntPtr h) { StringBuilder sb = new StringBuilder(256); GetClassName(h, sb, 256); return sb.ToString(); }
  public static string TitleOf(IntPtr h) { StringBuilder sb = new StringBuilder(256); GetWindowText(h, sb, 256); return sb.ToString(); }

  // First visible top-level window of the process matching class and/or title ("" = any). Every lookup is by
  // process id: more than one player can be on a desktop.
  public static IntPtr FindTop(uint pid, string cls, string title) {
    IntPtr found = IntPtr.Zero;
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      uint wp; GetWindowThreadProcessId(h, out wp);
      if (wp != pid || !IsWindowVisible(h)) return true;
      if (!string.IsNullOrEmpty(cls) && ClassOf(h) != cls) return true;
      if (!string.IsNullOrEmpty(title) && TitleOf(h) != title) return true;
      found = h; return false;
    }, IntPtr.Zero);
    return found;
  }
  // A visible descendant with the given control id.
  public static IntPtr FindChild(IntPtr root, int id) {
    IntPtr found = IntPtr.Zero;
    EnumChildWindows(root, delegate(IntPtr h, IntPtr l) {
      if (GetDlgCtrlID(h) == id && IsWindowVisible(h)) { found = h; return false; }
      return true;
    }, IntPtr.Zero);
    return found;
  }
  // Which window holds the mouse capture on the thread that owns h.
  public static IntPtr CaptureOf(IntPtr h) {
    uint pid; uint tid = GetWindowThreadProcessId(h, out pid);
    GUITHREADINFO g = new GUITHREADINFO(); g.cbSize = Marshal.SizeOf(typeof(GUITHREADINFO));
    return GetGUIThreadInfo(tid, ref g) ? g.hwndCapture : IntPtr.Zero;
  }

  const uint MOVE = 0x0001, LDOWN = 0x0002, LUP = 0x0004, ABSOLUTE = 0x8000;
  static INPUT Ev(uint flags, int x, int y) {
    INPUT i = new INPUT(); i.type = 0;
    i.mi.dwFlags = flags;
    if ((flags & MOVE) != 0) {
      int cx = GetSystemMetrics(0), cy = GetSystemMetrics(1);
      i.mi.dx = (int)(((long)x * 65535) / (cx - 1));
      i.mi.dy = (int)(((long)y * 65535) / (cy - 1));
    }
    return i;
  }
  static uint Send(List<INPUT> l) { INPUT[] a = l.ToArray(); return SendInput((uint)a.Length, a, Marshal.SizeOf(typeof(INPUT))); }
  public static uint MoveTo(int x, int y) { List<INPUT> l = new List<INPUT>(); l.Add(Ev(MOVE | ABSOLUTE, x, y)); return Send(l); }
  public static uint Click() { List<INPUT> l = new List<INPUT>(); l.Add(Ev(LDOWN, 0, 0)); l.Add(Ev(LUP, 0, 0)); return Send(l); }
  // The click and the move after it injected in one call, so nothing can run in between.
  public static uint ClickThenMove(int x, int y) {
    List<INPUT> l = new List<INPUT>(); l.Add(Ev(LDOWN, 0, 0)); l.Add(Ev(LUP, 0, 0)); l.Add(Ev(MOVE | ABSOLUTE, x, y)); return Send(l);
  }
}
'@
[void][MouseRig]::SetProcessDPIAware()

# Glide rather than teleport: the pointer crosses the pixels a hand would, and windows on the way see it pass.
function Move-PointerGlide {
    param([int] $X, [int] $Y, [int] $Steps = 6, [int] $StepMs = 15)
    $p = New-Object MouseRig+POINT
    [void][MouseRig]::GetCursorPos([ref]$p)
    for ($i = 1; $i -le $Steps; $i++) {
        [void][MouseRig]::MoveTo([int]($p.X + ($X - $p.X) * $i / $Steps), [int]($p.Y + ($Y - $p.Y) * $i / $Steps))
        if ($StepMs -gt 0) { Start-Sleep -Milliseconds $StepMs }
    }
}

function Get-PointerPosition {
    $p = New-Object MouseRig+POINT
    [void][MouseRig]::GetCursorPos([ref]$p)
    $p
}

# The screen itself, not the window's own drawing: what a person would see, including popups over it.
function Save-ScreenRegion {
    param([string] $Path, [int] $Left, [int] $Top, [int] $Right, [int] $Bottom)
    $w = $Right - $Left; $h = $Bottom - $Top
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($Left, $Top, 0, 0, (New-Object System.Drawing.Size $w, $h))
    $g.Dispose()
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}

function Get-WindowTextOf {
    param([IntPtr] $Hwnd)
    $sb = New-Object System.Text.StringBuilder 512
    [void][MouseRig]::SendMessageW($Hwnd, 0x000D, [IntPtr]512, $sb)      # WM_GETTEXT
    $sb.ToString()
}

# Start the program and return the window to work in: its top-level window of the given class, or, when
# -PostCommand is given, the dialog with -DialogTitle that the command opens (MPC-HC: 815 opens Options).
function Start-TargetWindow {
    param([string] $Exe, [string] $ArgumentLine, [string] $TopClass, [int] $PostCommand = 0, [string] $DialogTitle = '')
    if ($ArgumentLine) { $proc = Start-Process -FilePath $Exe -ArgumentList $ArgumentLine -PassThru }
    else { $proc = Start-Process -FilePath $Exe -PassThru }
    $procId = [uint32]$proc.Id
    $top = [IntPtr]::Zero
    for ($i = 0; $i -lt 80 -and $top -eq [IntPtr]::Zero; $i++) {
        Start-Sleep -Milliseconds 250
        $top = [MouseRig]::FindTop($procId, $TopClass, '')
    }
    if ($top -eq [IntPtr]::Zero) { throw "no top-level window of class '$TopClass' appeared" }
    Start-Sleep -Milliseconds 1500
    $root = $top
    if ($PostCommand) {
        # Re-posting until the dialog appears doubles as the wait for the program to be ready for commands.
        for ($i = 0; $i -lt 25 -and $root -eq $top; $i++) {
            [void][MouseRig]::PostMessage($top, 0x0111, [IntPtr]$PostCommand, [IntPtr]0)
            Start-Sleep -Milliseconds 800
            $dlg = [MouseRig]::FindTop($procId, '', $DialogTitle)
            if ($dlg -ne [IntPtr]::Zero) { $root = $dlg }
        }
        if ($root -eq $top) { throw "dialog '$DialogTitle' never appeared" }
        Start-Sleep -Milliseconds 1200
    }
    # Near the top-left, so a list drops downward and stays on a small guest screen.
    [void][MouseRig]::SetWindowPos($root, [IntPtr]::Zero, 40, 40, 0, 0, 0x0001 -bor 0x0004 -bor 0x0010)
    Start-Sleep -Milliseconds 400
    $wr = New-Object MouseRig+RECT
    [void][MouseRig]::GetWindowRect($root, [ref]$wr)
    # A real click on the caption makes it the foreground window the way a user would.
    [void][MouseRig]::MoveTo($wr.L + 120, $wr.T + 12); Start-Sleep -Milliseconds 200
    [void][MouseRig]::Click(); Start-Sleep -Milliseconds 400
    [pscustomobject]@{ Process = $proc; Root = $root; Rect = $wr; Foreground = ([MouseRig]::GetForegroundWindow() -eq $root) }
}
