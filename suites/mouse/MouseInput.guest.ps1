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
  [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT {
    public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo;
  }
  // The keyboard arm of the INPUT union is smaller than the mouse arm, but SendInput still wants
  // sizeof(INPUT), so the size is pinned to the same 40 bytes.
  [StructLayout(LayoutKind.Sequential, Size=40)] public struct KEYINPUT { public uint type; public KEYBDINPUT ki; }

  [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
  [DllImport("user32.dll")] public static extern uint SendInput(uint n, KEYINPUT[] inputs, int size);
  [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint vk, uint mapType);
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
  [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern bool RedrawWindow(IntPtr h, IntPtr r, IntPtr rgn, uint flags);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
  [DllImport("kernel32.dll")] static extern IntPtr VirtualAllocEx(IntPtr p, IntPtr a, IntPtr size, uint type, uint protect);
  [DllImport("kernel32.dll")] static extern bool VirtualFreeEx(IntPtr p, IntPtr a, IntPtr size, uint type);
  [DllImport("kernel32.dll")] static extern bool WriteProcessMemory(IntPtr p, IntPtr a, int[] b, IntPtr n, out IntPtr w);
  [DllImport("kernel32.dll")] static extern bool ReadProcessMemory(IntPtr p, IntPtr a, int[] b, IntPtr n, out IntPtr r);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
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
  // A descendant with the given control id, visible or not. Some cases assert that a control is
  // hidden, so visibility must not be part of the lookup.
  public static IntPtr FindDescendant(IntPtr root, int id) {
    IntPtr found = IntPtr.Zero;
    EnumChildWindows(root, delegate(IntPtr h, IntPtr l) {
      if (GetDlgCtrlID(h) == id) { found = h; return false; }
      return true;
    }, IntPtr.Zero);
    return found;
  }
  // A descendant of the given window class, visible or not.
  public static IntPtr FindChildByClass(IntPtr root, string cls) {
    IntPtr found = IntPtr.Zero;
    EnumChildWindows(root, delegate(IntPtr h, IntPtr l) {
      if (ClassOf(h) == cls) { found = h; return false; }
      return true;
    }, IntPtr.Zero);
    return found;
  }
  // The class of the window under a screen point. Not where input goes (see the README), but what a
  // record needs to show the pointer was where the case meant it to be.
  public static string ClassAt(int x, int y) {
    POINT p = new POINT(); p.X = x; p.Y = y;
    IntPtr h = WindowFromPoint(p);
    return h == IntPtr.Zero ? "" : ClassOf(h);
  }
  // A list view row of another process, in screen coordinates: LVM_GETITEMRECT takes a pointer, so the
  // RECT is allocated in the list's process for the call. code is LVIR_BOUNDS (0), LVIR_ICON (1) or
  // LVIR_LABEL (2). An empty rect when the row does not exist.
  public static RECT ListItemRect(IntPtr list, int item, int code) {
    RECT r = new RECT();
    uint pid; GetWindowThreadProcessId(list, out pid);
    IntPtr hp = OpenProcess(0x0008 | 0x0010 | 0x0020 | 0x0400, false, pid);   // VM_OPERATION|VM_READ|VM_WRITE|QUERY_INFORMATION
    if (hp == IntPtr.Zero) return r;
    IntPtr mem = VirtualAllocEx(hp, IntPtr.Zero, (IntPtr)16, 0x3000, 4);      // MEM_COMMIT|MEM_RESERVE, PAGE_READWRITE
    int[] buf = new int[] { code, 0, 0, 0 }; IntPtr n;
    IntPtr ok = IntPtr.Zero;
    if (mem != IntPtr.Zero) {
      WriteProcessMemory(hp, mem, buf, (IntPtr)16, out n);
      ok = SendMessage(list, 0x100E, (IntPtr)item, mem);                           // LVM_GETITEMRECT
      ReadProcessMemory(hp, mem, buf, (IntPtr)16, out n);
      VirtualFreeEx(hp, mem, IntPtr.Zero, 0x8000);
    }
    CloseHandle(hp);
    if (ok == IntPtr.Zero) return r;
    POINT a = new POINT(); a.X = buf[0]; a.Y = buf[1]; POINT b = new POINT(); b.X = buf[2]; b.Y = buf[3];
    ClientToScreen(list, ref a); ClientToScreen(list, ref b);
    r.L = a.X; r.T = a.Y; r.R = b.X; r.B = b.Y;
    return r;
  }
  // Which window holds the mouse capture on the thread that owns h.
  public static IntPtr CaptureOf(IntPtr h) {
    uint pid; uint tid = GetWindowThreadProcessId(h, out pid);
    GUITHREADINFO g = new GUITHREADINFO(); g.cbSize = Marshal.SizeOf(typeof(GUITHREADINFO));
    return GetGUIThreadInfo(tid, ref g) ? g.hwndCapture : IntPtr.Zero;
  }
  // Which window holds the keyboard focus on the thread that owns h.
  public static IntPtr FocusOf(IntPtr h) {
    uint pid; uint tid = GetWindowThreadProcessId(h, out pid);
    GUITHREADINFO g = new GUITHREADINFO(); g.cbSize = Marshal.SizeOf(typeof(GUITHREADINFO));
    return GetGUIThreadInfo(tid, ref g) ? g.hwndFocus : IntPtr.Zero;
  }

  const uint MOVE = 0x0001, LDOWN = 0x0002, LUP = 0x0004, RDOWN = 0x0008, RUP = 0x0010, WHEEL = 0x0800, ABSOLUTE = 0x8000;
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
  public static uint ClickRight() { List<INPUT> l = new List<INPUT>(); l.Add(Ev(RDOWN, 0, 0)); l.Add(Ev(RUP, 0, 0)); return Send(l); }
  // The left button's two halves on their own, for a drag or a press held while the pointer moves.
  public static uint ButtonDown() { List<INPUT> l = new List<INPUT>(); l.Add(Ev(LDOWN, 0, 0)); return Send(l); }
  public static uint ButtonUp() { List<INPUT> l = new List<INPUT>(); l.Add(Ev(LUP, 0, 0)); return Send(l); }
  // One wheel event at the pointer; 120 is one notch, negative is towards the user. It arrives through the
  // input queue, so a WH_MOUSE hook in the target sees it, which a posted WM_MOUSEWHEEL never passes.
  public static uint Wheel(int delta) {
    INPUT i = new INPUT(); i.type = 0; i.mi.dwFlags = WHEEL; i.mi.mouseData = unchecked((uint)delta);
    List<INPUT> l = new List<INPUT>(); l.Add(i); return Send(l);
  }
  // One real key press (down, up) with the scan code the layout would produce, as a hand would type it.
  public static uint KeyPress(ushort vk) {
    KEYINPUT d = new KEYINPUT(); d.type = 1; d.ki.wVk = vk; d.ki.wScan = (ushort)MapVirtualKey(vk, 0);
    KEYINPUT u = d; u.ki.dwFlags = 0x0002;   // KEYEVENTF_KEYUP
    KEYINPUT[] a = new KEYINPUT[] { d, u };
    return SendInput(2, a, Marshal.SizeOf(typeof(KEYINPUT)));
  }
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

# A window's part of the screen, clipped to the screen; the whole screen when too little of the window is on
# it (a panel auto-hidden off the edge, or a window dragged off). Returns the region captured, which is what
# maps a screen point to a pixel of the capture.
function Save-WindowShot {
    param([string] $Path, [IntPtr] $Hwnd)
    $sw = [MouseRig]::GetSystemMetrics(0); $sh = [MouseRig]::GetSystemMetrics(1)
    $r = New-Object MouseRig+RECT
    [void][MouseRig]::GetWindowRect($Hwnd, [ref]$r)
    $L = [Math]::Max(0, $r.L); $T = [Math]::Max(0, $r.T); $R = [Math]::Min($sw, $r.R); $B = [Math]::Min($sh, $r.B)
    if ($R - $L -lt 50 -or $B - $T -lt 50) { $L = 0; $T = 0; $R = $sw; $B = $sh }
    Save-ScreenRegion $Path $L $T $R $B
    @{ L = $L; T = $T; R = $R; B = $B }
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
