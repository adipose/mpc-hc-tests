# Runs on the target, in the console session. One case about switching the interface language at
# runtime; the host does the asserting. One JSON object goes to <OutDir>\result.json.
#
#   rtl-to-ltr  The player starts in Hebrew (InterfaceLanguage in the ini), so SetLanguage mirrors the
#               process layout and installs its CBT hook. The About box is opened (ID_HELP_ABOUT) and its
#               WS_EX_LAYOUTRTL recorded, then closed. Options opens at Player (LastUsedPage), the
#               language combo is set to English (the entry whose item data is 0) and the sheet is
#               closed with OK, which applies every page. The About box is opened again and its
#               WS_EX_LAYOUTRTL recorded. Before the fix nothing undid the layout or the hook, so the
#               English About box came up mirrored until a restart.
param([Parameter(Mandatory)] [string] $Job)

$ErrorActionPreference = 'Stop'
$j = Get-Content -Raw $Job | ConvertFrom-Json
$outDir = $j.OutDir
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory $outDir | Out-Null }
$result = [ordered]@{ started = (Get-Date).ToString('o'); case = $j.Case; error = $null }
$script:proc = $null

# Message numbers from winuser.h: WM_COMMAND 0x0111, WM_CLOSE 0x0010, IDOK 1, GWL_EXSTYLE -20,
# WS_EX_LAYOUTRTL 0x00400000, CB_GETCOUNT 0x0146, CB_SETCURSEL 0x014E, CB_GETITEMDATA 0x0150.

Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class Lang {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p, EnumProc f, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern int GetDlgCtrlID(IntPtr h);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern IntPtr GetWindowLongPtr(IntPtr h, int i);

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
    public static string Title(IntPtr h) { var sb = new StringBuilder(256); GetWindowText(h, sb, 256); return sb.ToString(); }
    public static bool IsRtl(IntPtr h) { return ((long)GetWindowLongPtr(h, -20) & 0x400000) != 0; }
}
'@

function Wait-For {
    param([scriptblock] $Get, [int] $Ms = 5000)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $Ms) { $v = & $Get; if ($v) { return $v }; Start-Sleep -Milliseconds 100 }
    $null
}
function Wait-Gone {
    param([IntPtr] $Hwnd)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ([Lang]::IsWindow($Hwnd) -and $sw.ElapsedMilliseconds -lt 5000) { Start-Sleep -Milliseconds 100 }
}
# Opens the About box, records its title and layout, closes it.
function Read-About {
    param([IntPtr] $Frame, [uint32] $ProcId)
    [void][Lang]::PostMessage($Frame, 0x0111, [IntPtr][int]$j.Ids.HelpAbout, [IntPtr]::Zero)
    $about = Wait-For { [Lang]::TopLevel($ProcId, '#32770') | Select-Object -First 1 } 10000
    if (-not $about) { throw 'the About box did not open' }
    Start-Sleep -Milliseconds 500
    $r = [ordered]@{ title = [Lang]::Title($about); rtl = [Lang]::IsRtl($about) }
    [void][Lang]::PostMessage($about, 0x0111, [IntPtr]1, [IntPtr]::Zero)
    Wait-Gone $about
    $r
}

try {
    $script:proc = Start-Process $j.Exe -ArgumentList '/new' -PassThru
    $pid0 = [uint32]$script:proc.Id
    $frame = Wait-For { [Lang]::TopLevel($pid0, 'MediaPlayerClassicW') | Select-Object -First 1 } 15000
    if (-not $frame) { throw 'the player window did not appear' }
    Start-Sleep -Milliseconds 1500
    $result.frameRtl = [Lang]::IsRtl($frame)

    $result.aboutBefore = Read-About $frame $pid0

    [void][Lang]::PostMessage($frame, 0x0111, [IntPtr][int]$j.Ids.ViewOptions, [IntPtr]::Zero)
    $sheet = Wait-For { [Lang]::TopLevel($pid0, '#32770') | Select-Object -First 1 } 10000
    if (-not $sheet) { throw 'Options did not open' }
    $combo = Wait-For { $c = [Lang]::Child($sheet, [int]$j.Ids.LanguageCombo); if ($c -ne [IntPtr]::Zero) { $c } }
    if (-not $combo) { throw 'no language combo on the page Options opened at' }
    Start-Sleep -Milliseconds 500
    $count = [int][Lang]::SendMessage($combo, 0x0146, [IntPtr]::Zero, [IntPtr]::Zero)
    $english = -1
    for ($i = 0; $i -lt $count; $i++) {
        if ([int64][Lang]::SendMessage($combo, 0x0150, [IntPtr]$i, [IntPtr]::Zero) -eq 0) { $english = $i; break }
    }
    if ($english -lt 0) { throw 'no English entry in the language combo' }
    [void][Lang]::SendMessage($combo, 0x014E, [IntPtr]$english, [IntPtr]::Zero)
    [void][Lang]::PostMessage($sheet, 0x0111, [IntPtr]1, [IntPtr]::Zero)
    Wait-Gone $sheet
    Start-Sleep -Milliseconds 500

    $result.aboutAfter = Read-About $frame $pid0

    [void][Lang]::PostMessage($frame, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
    $result.exited = $script:proc.WaitForExit(10000)
    $ini = [IO.Path]::ChangeExtension($j.Exe, 'ini')
    $result.iniAfter = if (Test-Path $ini) { [IO.File]::ReadAllText($ini) } else { '' }
} catch {
    $result.error = "$_"
} finally {
    Get-Process ([IO.Path]::GetFileNameWithoutExtension($j.Exe)) -ErrorAction SilentlyContinue | Stop-Process -Force
    $result.finished = (Get-Date).ToString('o')
    [IO.File]::WriteAllText((Join-Path $outDir 'result.json'), ($result | ConvertTo-Json -Depth 4))
}
