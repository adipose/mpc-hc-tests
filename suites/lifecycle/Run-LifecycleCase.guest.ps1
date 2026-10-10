# Runs on the target, in the console session. One case about how the player's frame comes down while
# the Options dialog is up; the host does the asserting. One JSON object goes to <OutDir>\result.json.
#
#   exit      The Options sheet is opened (ID_VIEW_OPTIONS posted), then an exit is requested the way
#             the web interface, "exit after playback" and /close do it (ID_FILE_EXIT posted to the
#             frame), or the way the taskbar does (WM_SYSCOMMAND SC_CLOSE). Which one is the job's How.
#             Recorded: the hide and destroy events of the frame and the sheet, in the order Windows
#             queued them (an out-of-context WinEvent hook, so nothing is sampled), and the exit code.
#             Before the fix the exit ran inside the sheet's modal pump: OnClose hid the frame and
#             deleted it with the sheet still up, and ShowOptions returned into the deleted frame
#             (#4257, crash dump 1000443). After it the sheet is cancelled first and the exit runs once
#             ShowOptions has returned, so the sheet is gone before the frame is even hidden.
#   reset     Options opens at Miscellaneous (LastUsedPage in the ini), Reset is clicked (BM_CLICK
#             posted) and the confirmation answered Yes. Recorded: whether the first instance exited and
#             with what code, whether a new one started, how many are running a few seconds later, and
#             the ini afterwards. A guard that a settings reset still restarts the player, on any build.
param([Parameter(Mandatory)] [string] $Job)

$ErrorActionPreference = 'Stop'
$j = Get-Content -Raw $Job | ConvertFrom-Json
$outDir = $j.OutDir
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory $outDir | Out-Null }
$result = [ordered]@{ started = (Get-Date).ToString('o'); case = $j.Case; how = $j.How; error = $null }
$script:proc = $null

# Message numbers from winuser.h: WM_COMMAND 0x0111, WM_SYSCOMMAND 0x0112, SC_CLOSE 0xF060,
# BM_CLICK 0x00F5, IDYES 6, EVENT_OBJECT_DESTROY 0x8001, EVENT_OBJECT_HIDE 0x8003, OBJID_WINDOW 0.

Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
public static class Life {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    delegate void WinEventProc(IntPtr hook, uint ev, IntPtr hwnd, int idObject, int idChild, uint thread, uint time);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p, EnumProc f, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern int GetDlgCtrlID(IntPtr h);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr mod, WinEventProc f, uint pid, uint tid, uint flags);
    [DllImport("user32.dll")] static extern bool UnhookWinEvent(IntPtr h);
    [DllImport("user32.dll")] static extern int GetMessage(out MSG m, IntPtr h, uint a, uint b);
    [DllImport("user32.dll")] static extern bool PostThreadMessage(uint tid, uint m, IntPtr w, IntPtr l);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr h; public uint m; public IntPtr w; public IntPtr l; public uint t; public int x; public int y; }

    // visible top-level windows of a process with the given class
    public static List<IntPtr> TopLevel(uint pid, string cls) {
        var r = new List<IntPtr>();
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p != pid || !IsWindowVisible(h)) return true;
            var sb = new StringBuilder(256); GetClassName(h, sb, 256);
            if (sb.ToString() == cls) r.Add(h);
            return true;
        }, IntPtr.Zero);
        return r;
    }
    public static IntPtr Child(IntPtr parent, int id) {
        IntPtr found = IntPtr.Zero;
        EnumChildWindows(parent, (h, l) => {
            if (GetDlgCtrlID(h) == id && IsWindowVisible(h)) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    // hide and destroy events of the two windows, in the order the system queued them
    public static List<string> Events = new List<string>();
    static IntPtr frame, sheet;
    static uint hookThread;
    static WinEventProc proc;
    public static void StartHook(uint pid, IntPtr f, IntPtr s) {
        frame = f; sheet = s;
        var ready = new ManualResetEvent(false);
        var t = new Thread(() => {
            hookThread = GetCurrentThreadId();
            proc = (hook, ev, hwnd, idObject, idChild, thread, time) => {
                if (idObject != 0) return;
                string who = hwnd == frame ? "frame" : hwnd == sheet ? "sheet" : null;
                if (who == null) return;
                lock (Events) Events.Add(who + (ev == 0x8001 ? " destroy" : " hide"));
            };
            IntPtr h = SetWinEventHook(0x8001, 0x8003, IntPtr.Zero, proc, pid, 0, 0); // WINEVENT_OUTOFCONTEXT
            ready.Set();
            MSG m;
            while (GetMessage(out m, IntPtr.Zero, 0, 0) > 0) { }
            UnhookWinEvent(h);
        });
        t.IsBackground = true;
        t.Start();
        ready.WaitOne();
    }
    public static void StopHook() { PostThreadMessage(hookThread, 0x0012, IntPtr.Zero, IntPtr.Zero); } // WM_QUIT
}
'@

function Wait-For {
    param([scriptblock] $Get, [int] $Ms = 5000)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $Ms) { $v = & $Get; if ($v) { return $v }; Start-Sleep -Milliseconds 100 }
    $null
}

try {
    $exeName = [IO.Path]::GetFileNameWithoutExtension($j.Exe)
    $script:proc = Start-Process $j.Exe -ArgumentList '/new' -PassThru
    $pid0 = [uint32]$script:proc.Id
    $frame = Wait-For { [Life]::TopLevel($pid0, 'MediaPlayerClassicW') | Select-Object -First 1 } 15000
    if (-not $frame) { throw 'the player window did not appear' }
    Start-Sleep -Milliseconds 1500

    [void][Life]::PostMessage($frame, 0x0111, [IntPtr][int]$j.Ids.ViewOptions, [IntPtr]::Zero)
    $sheet = Wait-For { [Life]::TopLevel($pid0, '#32770') | Select-Object -First 1 } 10000
    if (-not $sheet) { throw 'Options did not open' }
    $result.optionsOpened = $true
    Start-Sleep -Milliseconds 800

    if ($j.Case -eq 'exit') {
        [Life]::StartHook($pid0, $frame, $sheet)
        if ($j.How -eq 'sysclose') { [void][Life]::PostMessage($frame, 0x0112, [IntPtr]0xF060, [IntPtr]::Zero) }
        else { [void][Life]::PostMessage($frame, 0x0111, [IntPtr][int]$j.Ids.FileExit, [IntPtr]::Zero) }
        $result.exited = $script:proc.WaitForExit(20000)
        Start-Sleep -Milliseconds 300
        [Life]::StopHook()
        $result.exitCode = if ($result.exited) { $script:proc.ExitCode } else { $null }
        $result.events = @([Life]::Events)
    } elseif ($j.Case -eq 'reset') {
        $button = Wait-For { $b = [Life]::Child($sheet, [int]$j.Ids.ResetButton); if ($b -ne [IntPtr]::Zero) { $b } }
        if (-not $button) { throw 'no Reset button on the page Options opened at' }
        Start-Sleep -Milliseconds 500
        [void][Life]::PostMessage($button, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)
        $yes = Wait-For {
            foreach ($w in [Life]::TopLevel($pid0, '#32770')) {
                if ($w -ne $sheet) { $y = [Life]::Child($w, 6); if ($y -ne [IntPtr]::Zero) { return $y } }
            }
        }
        if (-not $yes) { throw 'no reset confirmation' }
        Start-Sleep -Milliseconds 300
        [void][Life]::PostMessage($yes, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)

        $result.exited = $script:proc.WaitForExit(20000)
        $result.exitCode = if ($result.exited) { $script:proc.ExitCode } else { $null }
        # the new instance comes up behind its first-run prompt, since its settings are gone
        $new = Wait-For { Get-Process $exeName -ErrorAction SilentlyContinue | Where-Object Id -ne $pid0 } 15000
        $result.relaunched = [bool]$new
        Start-Sleep -Seconds 3
        $result.instancesLeft = @(Get-Process $exeName -ErrorAction SilentlyContinue).Count
        $ini = [IO.Path]::ChangeExtension($j.Exe, 'ini')
        $result.iniAfter = if (Test-Path $ini) { [IO.File]::ReadAllText($ini) } else { '' }
    } else {
        throw "unknown case $($j.Case)"
    }
} catch {
    $result.error = "$_"
} finally {
    Get-Process ([IO.Path]::GetFileNameWithoutExtension($j.Exe)) -ErrorAction SilentlyContinue | Stop-Process -Force
    $result.finished = (Get-Date).ToString('o')
    [IO.File]::WriteAllText((Join-Path $outDir 'result.json'), ($result | ConvertTo-Json -Depth 4))
}
