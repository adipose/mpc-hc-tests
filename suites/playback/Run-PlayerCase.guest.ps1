# Runs on the target, in the console session (the player needs a desktop). Starts the player with the given
# arguments, optionally captures the virtual monitor part-way through, optionally posts WM_COMMAND messages to
# the player's window at given times, optionally probes the player's playlist list control, main toolbar and
# main window geometry at given times, optionally makes timed HTTP requests to the player's web server and
# dismisses (or accepts) dialogs those requests or the open raise, waits for the player to exit by itself,
# and kills it if it does not.
# Writes one JSON object to -Out; the host does the asserting.
param(
    [Parameter(Mandatory)] [string] $Exe,
    [string] $ArgumentLine = '',
    [Parameter(Mandatory)] [string] $Out,
    [int] $TimeoutSec = 40,
    [double] $CloseAtSec = 0,            # 0 = the player exits by itself (/close); else a close to its window at this time
    [ValidateSet('WM_CLOSE', 'SC_CLOSE')] [string] $CloseKind = 'WM_CLOSE',   # SC_CLOSE is the title-bar X
    [switch] $CloseWhenWindowAppears,    # close the moment a main window exists, while the file is still being opened
    [int] $CloseRepeat = 1,              # send the close this many times, 50 ms apart (a user clicking X twice on a hang)
    [int] $RedirectStorm = 0,            # launch this many further instances mid-playback; with one instance allowed each redirects into the first
    [string[]] $RedirectFiles = @(),     # the files they carry, in rotation (a comma-joined string is accepted too)
    [double] $StormAtSec = 2,
    [int] $StormIntervalMs = 150,
    [string] $SecondArgumentLine = '',   # base64 of a UTF-8 command line: at SecondAtSec launch one more instance
                                         # of the exe with it (quoting would not survive the hand-built task line);
                                         # several, comma-separated, are launched SecondIntervalMs apart
    [double] $SecondAtSec = 2,
    [int] $SecondIntervalMs = 300,
    [string] $PostCommands = '',         # comma-separated <seconds>:<command id>: a WM_COMMAND posted to the
                                         # player's main window at that time after start, as a menu accelerator
                                         # the user pressed; <seconds>:msg:<msg>:<wParam> (msg and wParam in
                                         # decimal, e.g. 3:msg:16:0 for WM_CLOSE) posts that raw message to the
                                         # player's frame instead (digits, dots, colons and the letters of
                                         # "msg" only, so it survives the hand-built task line unencoded)
    [string] $ProbeAt = '',              # comma-separated seconds after start: at each, read the player's
                                         # playlist list control from outside (count, selection, scroll
                                         # position, scrollbars) and the main toolbar's buttons (command ids
                                         # in order) and record them under "probes" in the JSON
                                         # (digits, dots and commas only, like PostCommands)
    [double] $CaptureAtSec = 0,          # 0 = no frame capture
    [int] $CaptureConnector = 0,
    [string] $CapturePath = '',
    [string] $RendererFile = '',         # json of renderer settings to apply for this case, and put back after
    [string] $HttpAt = '',               # comma-separated base64 entries, each the UTF-8 of
                                         # <sec>|<method>|<path>|<body> (body may be empty, POST bodies are
                                         # application/x-www-form-urlencoded): at that time after start,
                                         # request http://127.0.0.1:<HttpPort><path> (the web server binds
                                         # IPv4 only, so never localhost) with a 5 s timeout and record
                                         # {at, path, status, ms, length, bodyText, file} under "http" in
                                         # the JSON; every body is saved to http-<n>.bin beside -Out.
                                         # A 4xx/5xx is a status, not an exception; a refused connection
                                         # is status 0.
    [int] $HttpPort = 0,
    [string] $CloseDialogAt = '',        # comma-separated <sec>:<window title>: at that time, find a
                                         # top-level window of the player's process with this title (a modal
                                         # it raised) and post it IDCANCEL, so the player can still be
                                         # closed afterwards. Titles may not contain commas or colons.
    [string] $AcceptDialogAt = '',       # same shape as CloseDialogAt, but posts IDOK instead (accepts the
                                         # dialog -- the RAR entry selector's Select button, which no other
                                         # mechanism here can press). Recorded under "dialogAccepts".
    [string] $ControlAt = ''             # comma-separated steps on a dialog control found by its id, in any
                                         # visible dialog (#32770) of the player's process, so a translated
                                         # title does not matter: <sec>:probe:<ctrl> records whether it
                                         # exists and is visible, and its STM_GETICON; <sec>:combo:<ctrl>:<data>
                                         # selects the combo item whose item data is <data> and tells the
                                         # parent CBN_SELCHANGE; <sec>:cmd:<ctrl>:<id> posts WM_COMMAND <id>
                                         # to the top-level dialog holding the control (1 IDOK, 2 IDCANCEL);
                                         # <sec>:size:<ctrl>:<px> grows that dialog by px each way;
                                         # <sec>:dpi:0:<percent> sets the primary monitor's display scale
                                         # (put back to 100% when the steps are done). A probe also records
                                         # the control's and its dialog's screen rects. <sec>:fprobe:<ctrl>
                                         # probes a control of the player's frame instead (status bar,
                                         # toolbars): its screen rect and window text.
                                         # Decimal. Recorded under "controls".
)

$ErrorActionPreference = 'Continue'
$result = [ordered]@{ started = (Get-Date).ToString('o') }
$script:dpiChanged = $false

if ($true) {   # always: Send-Close finds the player's frame by class for every close, not only these options
    # The title-bar X posts WM_SYSCOMMAND/SC_CLOSE to the window, not WM_CLOSE; the player has handled it on its
    # own path since e21c9fcfff, so both ways of closing belong under test. The posted commands are WM_COMMAND,
    # the same message a menu accelerator sends. The playlist probe sends the list control plain integer
    # list-view messages, which are safe cross-process (no pointers, no structs); the toolbar probe's
    # TB_GETBUTTON writes a TBBUTTON, which is what the memory APIs below are for.
    Add-Type -Namespace MpcTest -Name User32 -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern bool PostMessageW(System.IntPtr hWnd, uint msg, System.IntPtr wParam, System.IntPtr lParam);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern System.IntPtr SendMessageW(System.IntPtr hWnd, uint msg, System.IntPtr wParam, System.IntPtr lParam);
public delegate bool EnumWindowsProc(System.IntPtr hWnd, System.IntPtr lParam);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool EnumWindows(EnumWindowsProc callback, System.IntPtr lParam);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool EnumChildWindows(System.IntPtr hWndParent, EnumWindowsProc callback, System.IntPtr lParam);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern uint GetWindowThreadProcessId(System.IntPtr hWnd, out uint processId);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetClassNameW(System.IntPtr hWnd, System.Text.StringBuilder className, int maxCount);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetWindowTextW(System.IntPtr hWnd, System.Text.StringBuilder text, int maxCount);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool IsWindowVisible(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern System.IntPtr GetParent(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
public static extern System.IntPtr GetWindowLongPtrW(System.IntPtr hWnd, int index);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern int GetDlgCtrlID(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern System.IntPtr GetAncestor(System.IntPtr hWnd, uint flags);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool GetWindowRect(System.IntPtr hWnd, [System.Runtime.InteropServices.Out] int[] rect);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetWindowPos(System.IntPtr hWnd, System.IntPtr after, int x, int y, int cx, int cy, uint flags);
'@
}

if ($ProbeAt) {
    # The toolbar probe reads TBBUTTONs out of the player: TB_GETBUTTON's lParam is a pointer, so the
    # struct lives in the player's address space for the call and comes back over ReadProcessMemory,
    # the same approach as the mouse suite's Run-PlaylistInputCase.guest.ps1.
    Add-Type -Namespace MpcTest -Name Kernel32 -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern System.IntPtr OpenProcess(uint access, bool inherit, uint processId);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern System.IntPtr VirtualAllocEx(System.IntPtr process, System.IntPtr address, System.UIntPtr size, uint type, uint protect);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern bool VirtualFreeEx(System.IntPtr process, System.IntPtr address, System.UIntPtr size, uint type);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern bool ReadProcessMemory(System.IntPtr process, System.IntPtr address, byte[] buffer, System.UIntPtr size, out System.UIntPtr read);
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern bool CloseHandle(System.IntPtr handle);
'@

    # The window-geometry part of the probe: the main window's rect (invisible resize
    # borders included, what the player's GetWindowRect sees), its DWM extended frame
    # bounds (the visible part -- their difference is the invisible border the player
    # inflates its work area by), whether it is maximized, and the primary monitor's
    # work area. The zoom cases assert on all four.
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace MpcTest {
    public struct WinRect { public int left; public int top; public int right; public int bottom; }
    public static class Geometry {
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out WinRect rect);
        [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool SystemParametersInfoW(int action, int param, out WinRect rect, int winIni);
        [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hWnd, int attribute, out WinRect rect, int size);
    }
}
'@
}

# The playlist's list control, found from outside the player. The player has several SysListView32 windows
# (the Subresync bar keeps one too), so a candidate is the playlist's only if its parent chain includes a
# window titled "Playlist": CPlayerPlaylistBar::Create passes ResStr(IDS_PLAYLIST_CAPTION) as the bar's
# window name, and the floating mini-frame carries the same caption. Docked or floating decides where the
# list sits, so the search starts from every top-level window of the player's process and walks down.
function Find-PlaylistListView {
    param([int] $ProcessId)
    $candidates = [System.Collections.Generic.List[IntPtr]]::new()
    $childCallback = [MpcTest.User32+EnumWindowsProc] {
        param($hWnd, $lParam)
        $className = [Text.StringBuilder]::new(64)
        [void] [MpcTest.User32]::GetClassNameW($hWnd, $className, $className.Capacity)
        if ($className.ToString() -eq 'SysListView32') { $candidates.Add($hWnd) }
        return $true
    }
    $topCallback = [MpcTest.User32+EnumWindowsProc] {
        param($hWnd, $lParam)
        $procId = [uint32] 0
        [void] [MpcTest.User32]::GetWindowThreadProcessId($hWnd, [ref] $procId)
        if ($procId -eq $ProcessId) { [void] [MpcTest.User32]::EnumChildWindows($hWnd, $childCallback, [IntPtr]::Zero) }
        return $true
    }
    [void] [MpcTest.User32]::EnumWindows($topCallback, [IntPtr]::Zero)
    foreach ($candidate in $candidates) {
        $walk = $candidate
        while ($walk -ne [IntPtr]::Zero) {
            $title = [Text.StringBuilder]::new(256)
            [void] [MpcTest.User32]::GetWindowTextW($walk, $title, $title.Capacity)
            if ($title.ToString() -eq 'Playlist') { return $candidate }
            $walk = [MpcTest.User32]::GetParent($walk)
        }
    }
    # No parent chain titled Playlist: a sole candidate can only be the playlist's list.
    if ($candidates.Count -eq 1) { return $candidates[0] }
    [IntPtr]::Zero
}

# The command id of one button of a toolbar in the player's process. TB_GETBUTTON (WM_USER + 23) writes
# a TBBUTTON at its lParam -- on x64 iBitmap int @0, idCommand int @4, fsState @8, fsStyle @9, six
# reserved bytes, dwData @16, iString @24, 32 bytes in all (CommCtrl.h) -- so the struct lives in the
# player's address space for the call and the id is read back from offset 4.
function Get-RemoteToolbarButtonId {
    param([IntPtr] $Toolbar, [int] $Index, [IntPtr] $ProcessHandle, [IntPtr] $RemoteBuffer)
    [void] [MpcTest.User32]::SendMessageW($Toolbar, 0x0417, [IntPtr] $Index, $RemoteBuffer)   # TB_GETBUTTON
    $out = New-Object byte[] 32
    $read = [UIntPtr]::Zero
    [void] [MpcTest.Kernel32]::ReadProcessMemory($ProcessHandle, $RemoteBuffer, $out, ([UIntPtr]::new([uint64]32)), [ref] $read)
    [BitConverter]::ToInt32($out, 4)
}

# The player toolbar, found from outside the player. CPlayerToolBar is a CToolBar, so its window class
# is ToolbarWindow32 and other windows of that class may exist in the process; a candidate is the
# player toolbar when its first button is ID_LEFTSEPARATOR (957) -- PlaceButtons adds it before
# anything else, whichever layout branch runs, and no other toolbar has it.
function Find-PlayerToolbar {
    param([int] $ProcessId, [IntPtr] $ProcessHandle, [IntPtr] $RemoteBuffer)
    $candidates = [System.Collections.Generic.List[IntPtr]]::new()
    $childCallback = [MpcTest.User32+EnumWindowsProc] {
        param($hWnd, $lParam)
        $className = [Text.StringBuilder]::new(64)
        [void] [MpcTest.User32]::GetClassNameW($hWnd, $className, $className.Capacity)
        if ($className.ToString() -eq 'ToolbarWindow32') { $candidates.Add($hWnd) }
        return $true
    }
    $topCallback = [MpcTest.User32+EnumWindowsProc] {
        param($hWnd, $lParam)
        $procId = [uint32] 0
        [void] [MpcTest.User32]::GetWindowThreadProcessId($hWnd, [ref] $procId)
        if ($procId -eq $ProcessId) { [void] [MpcTest.User32]::EnumChildWindows($hWnd, $childCallback, [IntPtr]::Zero) }
        return $true
    }
    [void] [MpcTest.User32]::EnumWindows($topCallback, [IntPtr]::Zero)
    foreach ($candidate in $candidates) {
        if ((Get-RemoteToolbarButtonId $candidate 0 $ProcessHandle $RemoteBuffer) -eq 957) { return $candidate }   # ID_LEFTSEPARATOR
    }
    # No candidate starts with the left separator: a sole ToolbarWindow32 can only be the player toolbar.
    if ($candidates.Count -eq 1) { return $candidates[0] }
    [IntPtr]::Zero
}

# One probe of the playlist's list control: LVM_GETITEMCOUNT, LVM_GETNEXTITEM (first selected, first
# focused), LVM_GETTOPINDEX, LVM_GETCOUNTPERPAGE, visibility and the scrollbar style bits. A list view
# sets WS_HSCROLL/WS_VSCROLL while the scrollbar is shown, so the style says whether one is there.
# Also one probe of the player toolbar: TB_BUTTONCOUNT (WM_USER + 24) and, per button, the idCommand
# of its TBBUTTON, recorded as toolbarIds in button order. And one probe of the main window's
# geometry: window rect, DWM extended frame bounds (frameRect), maximized, and the primary
# monitor's work area.
function Get-PlaylistProbe {
    param([double] $At, [int] $ProcessId)
    $h = Find-PlaylistListView $ProcessId
    $probe = [ordered]@{ at = $At; found = ($h -ne [IntPtr]::Zero) }
    if ($h -ne [IntPtr]::Zero) {
        $probe.count    = [MpcTest.User32]::SendMessageW($h, 0x1004, [IntPtr]::Zero, [IntPtr]::Zero).ToInt32()         # LVM_GETITEMCOUNT
        $probe.selected = [MpcTest.User32]::SendMessageW($h, 0x100C, [IntPtr]::new(-1), [IntPtr]::new(2)).ToInt32()  # LVM_GETNEXTITEM, LVNI_SELECTED
        $probe.focused  = [MpcTest.User32]::SendMessageW($h, 0x100C, [IntPtr]::new(-1), [IntPtr]::new(1)).ToInt32()  # LVM_GETNEXTITEM, LVNI_FOCUSED
        $probe.top      = [MpcTest.User32]::SendMessageW($h, 0x1027, [IntPtr]::Zero, [IntPtr]::Zero).ToInt32()       # LVM_GETTOPINDEX
        $probe.perPage  = [MpcTest.User32]::SendMessageW($h, 0x1028, [IntPtr]::Zero, [IntPtr]::Zero).ToInt32()       # LVM_GETCOUNTPERPAGE
        $probe.visible  = [MpcTest.User32]::IsWindowVisible($h)
        $style = [MpcTest.User32]::GetWindowLongPtrW($h, -16).ToInt64()                                              # GWL_STYLE
        $probe.hscroll  = [bool] ($style -band 0x00100000)                                                           # WS_HSCROLL
        $probe.vscroll  = [bool] ($style -band 0x00200000)                                                           # WS_VSCROLL
    }
    $probe.toolbarIds = $null
    $hProc = [MpcTest.Kernel32]::OpenProcess(0x0438, $false, [uint32] $ProcessId)   # VM_OPERATION|VM_READ|VM_WRITE|QUERY_INFORMATION
    if ($hProc -ne [IntPtr]::Zero) {
        try {
            $mem = [MpcTest.Kernel32]::VirtualAllocEx($hProc, [IntPtr]::Zero, ([UIntPtr]::new([uint64]32)), 0x1000, 0x04)   # MEM_COMMIT, PAGE_READWRITE
            if ($mem -ne [IntPtr]::Zero) {
                try {
                    $toolbar = Find-PlayerToolbar $ProcessId $hProc $mem
                    if ($toolbar -ne [IntPtr]::Zero) {
                        $buttons = [MpcTest.User32]::SendMessageW($toolbar, 0x0418, [IntPtr]::Zero, [IntPtr]::Zero).ToInt32()   # TB_BUTTONCOUNT
                        $probe.toolbarIds = @(for ($i = 0; $i -lt $buttons; $i++) { Get-RemoteToolbarButtonId $toolbar $i $hProc $mem })
                    }
                } finally {
                    [void] [MpcTest.Kernel32]::VirtualFreeEx($hProc, $mem, [UIntPtr]::Zero, 0x8000)   # MEM_RELEASE
                }
            }
        } finally {
            [void] [MpcTest.Kernel32]::CloseHandle($hProc)
        }
    }
    # Window geometry: the main frame by class, like Send-Close (Process.MainWindowHandle
    # is cached and behind a modal can name nothing).
    $probe.mainRect = $null
    $probe.frameRect = $null
    $probe.maximized = $null
    $probe.workArea = $null
    $main = Find-ProcessWindow -ProcessId $ProcessId -Class 'MediaPlayerClassicW'
    if ($main -ne [IntPtr]::Zero) {
        $wr = New-Object MpcTest.WinRect
        if ([MpcTest.Geometry]::GetWindowRect($main, [ref] $wr)) {
            $probe.mainRect = [ordered]@{ left = $wr.left; top = $wr.top; right = $wr.right; bottom = $wr.bottom }
        }
        $fr = New-Object MpcTest.WinRect
        if ([MpcTest.Geometry]::DwmGetWindowAttribute($main, 9, [ref] $fr, 16) -eq 0) {   # DWMWA_EXTENDED_FRAME_BOUNDS
            $probe.frameRect = [ordered]@{ left = $fr.left; top = $fr.top; right = $fr.right; bottom = $fr.bottom }
        }
        $probe.maximized = [MpcTest.Geometry]::IsZoomed($main)
    }
    $wa = New-Object MpcTest.WinRect
    if ([MpcTest.Geometry]::SystemParametersInfoW(0x0030, 0, [ref] $wa, 0)) {   # SPI_GETWORKAREA, primary monitor
        $probe.workArea = [ordered]@{ left = $wa.left; top = $wa.top; right = $wa.right; bottom = $wa.bottom }
    }
    $probe
}

# One request to the player's web server. A 4xx/5xx is an answer with a status, not an exception;
# a refused connection (or a timeout while the server is stuck) leaves the status 0. Every body is
# written to http-<Index>.bin beside the result JSON; a text body is also quoted (first 4000 chars)
# in the entry itself.
function Send-WebProbe {
    param([double] $At, [string] $Method, [string] $Path, [string] $Body, [int] $Port, [string] $OutDir, [int] $Index)
    $entry = [ordered]@{ at = $At; path = $Path; status = 0; ms = 0; length = 0; bodyText = $null; file = $null }
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $response = $null
    try {
        $request = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$Port$Path")
        $request.Method = $Method
        $request.Timeout = 5000
        $request.ReadWriteTimeout = 5000
        # The answer itself is the evidence: a 301/404 from a not-yet-ready server must be
        # recorded, not silently followed into a redirect loop.
        $request.AllowAutoRedirect = $false
        if ($Method -eq 'POST') {
            $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
            $request.ContentType = 'application/x-www-form-urlencoded'
            $request.ContentLength = $bytes.Length
            $stream = $request.GetRequestStream()
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Close()
        }
        try {
            $response = $request.GetResponse()
        } catch [System.Net.WebException] {
            $response = $_.Exception.Response   # an error status still carries a response
        }
    } catch { }
    $entry.ms = [int] $watch.ElapsedMilliseconds
    if ($response) {
        $entry.status = [int] $response.StatusCode
        $isText = $response.ContentType -match '^(text/|application/json)'
        $memory = New-Object System.IO.MemoryStream
        $response.GetResponseStream().CopyTo($memory)
        $bytes = $memory.ToArray()
        $response.Close()
        $entry.length = $bytes.Length
        if ($Index -gt 0) {   # index 0 is a poll probe, whose body nobody keeps
            $entry.file = "http-$Index.bin"
            [System.IO.File]::WriteAllBytes((Join-Path $OutDir $entry.file), $bytes)
        }
        if ($isText) {
            $text = [Text.Encoding]::UTF8.GetString($bytes)
            if ($text.Length -gt 4000) { $text = $text.Substring(0, 4000) }
            $entry.bodyText = $text
        }
    }
    $entry
}

# A modal dialog the player raised (e.g. Options from a web command) belongs to the player's process
# as a top-level window. Posting IDCANCEL is what the Cancel button does; closing it matters because a
# modal can leave the main window's WM_CLOSE unanswered.
function Find-ProcessWindow {
    param([int] $ProcessId, [string] $Title = $null, [string] $Class = $null)
    $found = [System.Collections.Generic.List[IntPtr]]::new()
    $callback = [MpcTest.User32+EnumWindowsProc] {
        param($hWnd, $lParam)
        $procId = [uint32] 0
        [void] [MpcTest.User32]::GetWindowThreadProcessId($hWnd, [ref] $procId)
        if ($procId -eq $ProcessId) {
            $text = [Text.StringBuilder]::new(256)
            if ($Title) { [void] [MpcTest.User32]::GetWindowTextW($hWnd, $text, $text.Capacity) }
            else { [void] [MpcTest.User32]::GetClassNameW($hWnd, $text, $text.Capacity) }
            if ($text.ToString() -eq $(if ($Title) { $Title } else { $Class })) { $found.Add($hWnd); return $false }
        }
        return $true
    }
    [void] [MpcTest.User32]::EnumWindows($callback, [IntPtr]::Zero)
    if ($found.Count) { $found[0] } else { [IntPtr]::Zero }
}

# Returns whether the dialog is gone afterwards. WM_CLOSE first (a property sheet's frame acts on it);
# IDCANCEL if it is still there.
function Close-PlayerDialog {
    param([int] $ProcessId, [string] $Title)
    $dlg = Find-ProcessWindow -ProcessId $ProcessId -Title $Title
    if ($dlg -eq [IntPtr]::Zero) { return $false }
    [void] [MpcTest.User32]::PostMessageW($dlg, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE
    Start-Sleep -Milliseconds 500
    if ((Find-ProcessWindow -ProcessId $ProcessId -Title $Title) -ne [IntPtr]::Zero) {
        [void] [MpcTest.User32]::PostMessageW($dlg, 0x0111, [IntPtr] 2, [IntPtr]::Zero)   # WM_COMMAND, IDCANCEL
        Start-Sleep -Milliseconds 500
    }
    return ((Find-ProcessWindow -ProcessId $ProcessId -Title $Title) -eq [IntPtr]::Zero)
}

# The accepting twin of Close-PlayerDialog: post IDOK (the modal's default button) and
# report whether the dialog is gone afterwards. A modal pumps messages, so a posted
# WM_COMMAND is dispatched the same as a button click.
function Accept-PlayerDialog {
    param([int] $ProcessId, [string] $Title)
    $dlg = Find-ProcessWindow -ProcessId $ProcessId -Title $Title
    if ($dlg -eq [IntPtr]::Zero) { return $false }
    [void] [MpcTest.User32]::PostMessageW($dlg, 0x0111, [IntPtr] 1, [IntPtr]::Zero)   # WM_COMMAND, IDOK
    Start-Sleep -Milliseconds 500
    return ((Find-ProcessWindow -ProcessId $ProcessId -Title $Title) -eq [IntPtr]::Zero)
}

# A visible control with this id in any visible dialog (#32770) of the process, searched through every
# level of children (a property sheet's page is a dialog inside the sheet). Dialog ids are not unique
# across dialogs, which is why only dialogs are searched and not the player's frame.
function Find-DialogControl {
    param([int] $ProcessId, [int] $ControlId, [string] $TopClass = '#32770')
    $dialogs = [System.Collections.Generic.List[IntPtr]]::new()
    $top = [MpcTest.User32+EnumWindowsProc] {
        param($hWnd, $lParam)
        $procId = [uint32] 0
        [void] [MpcTest.User32]::GetWindowThreadProcessId($hWnd, [ref] $procId)
        if ($procId -eq $ProcessId -and [MpcTest.User32]::IsWindowVisible($hWnd)) {
            $cls = [Text.StringBuilder]::new(64)
            [void] [MpcTest.User32]::GetClassNameW($hWnd, $cls, $cls.Capacity)
            if ($cls.ToString() -eq $TopClass) { $dialogs.Add($hWnd) }
        }
        return $true
    }
    [void] [MpcTest.User32]::EnumWindows($top, [IntPtr]::Zero)
    $found = [System.Collections.Generic.List[IntPtr]]::new()
    $child = [MpcTest.User32+EnumWindowsProc] {
        param($hWnd, $lParam)
        if ([MpcTest.User32]::GetDlgCtrlID($hWnd) -eq $ControlId -and [MpcTest.User32]::IsWindowVisible($hWnd)) { $found.Add($hWnd); return $false }
        return $true
    }
    foreach ($dlg in $dialogs) {
        [void] [MpcTest.User32]::EnumChildWindows($dlg, $child, [IntPtr]::Zero)
        if ($found.Count) { return $found[0] }
    }
    [IntPtr]::Zero
}

# The primary monitor's display scale, set live through DisplayConfig: DISPLAYCONFIG_DEVICE_INFO_SET_DPI_SCALE
# (-4), undocumented but what Settings > Display uses since 1703. The value is a step relative to the
# monitor's recommended scale, which GET_DPI_SCALE (-3) gives as minus its minimum. Windows sends the
# player's windows on that monitor WM_DPICHANGED, as a user changing the scale does. Must run in the
# console user's session, which this script does.
function Set-PrimaryScale {
    param([int] $Percent)
    if (-not ('MpcTest.Dpi' -as [type])) {
        Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace MpcTest {
public static class Dpi {
    [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint paths, out uint modes);
    [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint paths, byte[] pathArray, ref uint modes, byte[] modeArray, IntPtr topology);
    [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(byte[] packet);
    [DllImport("user32.dll")] static extern int DisplayConfigSetDeviceInfo(byte[] packet);
    static readonly int[] Steps = { 100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500 };
    static byte[] Packet(int type, int size, byte[] paths, int i) {
        var b = new byte[size];
        BitConverter.GetBytes(type).CopyTo(b, 0);
        BitConverter.GetBytes(size).CopyTo(b, 4);
        Array.Copy(paths, i * 72, b, 8, 12);   // DISPLAYCONFIG_PATH_INFO.sourceInfo: adapterId (LUID), id
        return b;
    }
    public static int SetPrimary(int percent) {
        uint np, nm;
        GetDisplayConfigBufferSizes(2, out np, out nm);   // QDC_ONLY_ACTIVE_PATHS
        var paths = new byte[np * 72]; var modes = new byte[nm * 64];
        int q = QueryDisplayConfig(2, ref np, paths, ref nm, modes, IntPtr.Zero);
        if (q != 0) return q;
        for (int i = 0; i < np; i++) {
            var name = Packet(1, 20 + 64, paths, i);   // DISPLAYCONFIG_SOURCE_DEVICE_NAME: viewGdiDeviceName
            DisplayConfigGetDeviceInfo(name);
            if (System.Text.Encoding.Unicode.GetString(name, 20, 64).TrimEnd('\0') != System.Windows.Forms.Screen.PrimaryScreen.DeviceName) continue;
            var get = Packet(-3, 32, paths, i);
            DisplayConfigGetDeviceInfo(get);
            int recommended = Math.Abs(BitConverter.ToInt32(get, 20));
            var set = Packet(-4, 24, paths, i);
            BitConverter.GetBytes(Array.IndexOf(Steps, percent) - recommended).CopyTo(set, 20);
            return DisplayConfigSetDeviceInfo(set);
        }
        return -1;
    }
}
}
'@
    }
    [MpcTest.Dpi]::SetPrimary($Percent)
}

function Invoke-ControlStep {
    param([int] $ProcessId, $Step)
    if ($Step.op -eq 'dpi') {
        # <sec>:dpi:0:<percent>, no control: the primary monitor's scale. The runner puts it back to 100%.
        $script:dpiChanged = $true
        return [ordered]@{ at = $Step.at; op = 'dpi'; ctrl = 0; percent = $Step.value; result = (Set-PrimaryScale ([int] $Step.value)) }
    }
    # fprobe is a probe of a control in the player's own frame (its status bar, its toolbars) rather than in a dialog.
    $topClass = if ($Step.op -eq 'fprobe') { 'MediaPlayerClassicW' } else { '#32770' }
    $ctrl = Find-DialogControl -ProcessId $ProcessId -ControlId $Step.ctrl -TopClass $topClass
    $record = [ordered]@{ at = $Step.at; op = $Step.op; ctrl = $Step.ctrl; found = ($ctrl -ne [IntPtr]::Zero) }
    if ($ctrl -eq [IntPtr]::Zero) { return $record }
    $root = [MpcTest.User32]::GetAncestor($ctrl, 2)   # GA_ROOT: the top-level dialog
    $title = [Text.StringBuilder]::new(256)
    [void] [MpcTest.User32]::GetWindowTextW($root, $title, $title.Capacity)
    $record.dialog = $title.ToString()
    if ($Step.op -eq 'fprobe') {
        $text = [Text.StringBuilder]::new(1024)
        [void] [MpcTest.User32]::GetWindowTextW($ctrl, $text, $text.Capacity)
        $record.text = $text.ToString()
        $rect = [int[]]::new(4); [void] [MpcTest.User32]::GetWindowRect($ctrl, $rect); $record.rect = $rect
    } elseif ($Step.op -eq 'probe') {
        $record.icon = ([MpcTest.User32]::SendMessageW($ctrl, 0x0171, [IntPtr]::Zero, [IntPtr]::Zero) -ne [IntPtr]::Zero)   # STM_GETICON
        # Screen rects (left, top, right, bottom) of the control and of its top-level dialog.
        $rect = [int[]]::new(4); [void] [MpcTest.User32]::GetWindowRect($ctrl, $rect); $record.rect = $rect
        $rect = [int[]]::new(4); [void] [MpcTest.User32]::GetWindowRect($root, $rect); $record.dialogRect = $rect
    } elseif ($Step.op -eq 'combo') {
        $count = [int] [MpcTest.User32]::SendMessageW($ctrl, 0x0146, [IntPtr]::Zero, [IntPtr]::Zero)   # CB_GETCOUNT
        $index = -1
        for ($i = 0; $i -lt $count; $i++) {
            if ([long] [MpcTest.User32]::SendMessageW($ctrl, 0x0150, [IntPtr] $i, [IntPtr]::Zero) -eq $Step.value) { $index = $i; break }   # CB_GETITEMDATA
        }
        $record.index = $index
        if ($index -ge 0) {
            [void] [MpcTest.User32]::SendMessageW($ctrl, 0x014E, [IntPtr] $index, [IntPtr]::Zero)   # CB_SETCURSEL
            # WM_COMMAND (CBN_SELCHANGE << 16 | id) to the parent: what a user's pick tells the page.
            [void] [MpcTest.User32]::PostMessageW([MpcTest.User32]::GetParent($ctrl), 0x0111, [IntPtr] ((1 -shl 16) -bor $Step.ctrl), $ctrl)
        }
    } elseif ($Step.op -eq 'cmd') {
        $record.delivered = [bool] [MpcTest.User32]::PostMessageW($root, 0x0111, [IntPtr] $Step.value, [IntPtr]::Zero)
    } elseif ($Step.op -eq 'grip') {
        # The dialog's size grip: ResizableLib creates it as a ScrollBar with SBS_SIZEGRIP (0x10) and id 0, so
        # it is found by class and style under the dialog that holds <ctrl>. Its screen rect, and the screen
        # around it (twice its size, from the dialog's bottom-right corner) saved as <out>-grip-<sec>.png beside
        # -Out (Invoke-PlayerCase copies it back), with the counts of light (all channels > 200) and dark (all < 80) pixels in the grip itself.
        $grips = [System.Collections.Generic.List[IntPtr]]::new()
        $cb = [MpcTest.User32+EnumWindowsProc] {
            param($hWnd, $lParam)
            $cls = [Text.StringBuilder]::new(64)
            [void] [MpcTest.User32]::GetClassNameW($hWnd, $cls, $cls.Capacity)
            if ($cls.ToString() -eq 'ScrollBar' -and ([long] [MpcTest.User32]::GetWindowLongPtrW($hWnd, -16) -band 0x10) -and [MpcTest.User32]::IsWindowVisible($hWnd)) { $grips.Add($hWnd); return $false }
            return $true
        }
        [void] [MpcTest.User32]::EnumChildWindows($root, $cb, [IntPtr]::Zero)
        $record.gripFound = ($grips.Count -gt 0)
        if ($grips.Count) {
            $g = [int[]]::new(4); [void] [MpcTest.User32]::GetWindowRect($grips[0], $g); $record.rect = $g
            $d = [int[]]::new(4); [void] [MpcTest.User32]::GetWindowRect($root, $d); $record.dialogRect = $d
            Add-Type -AssemblyName System.Drawing
            $gw = $g[2] - $g[0]; $gh = $g[3] - $g[1]
            if ($gw -gt 0 -and $gh -gt 0) {
                $bmp = [System.Drawing.Bitmap]::new($gw, $gh)
                $gfx = [System.Drawing.Graphics]::FromImage($bmp)
                $gfx.CopyFromScreen($g[0], $g[1], 0, 0, $bmp.Size)
                $light = 0; $dark = 0
                for ($y = 0; $y -lt $gh; $y++) { for ($x = 0; $x -lt $gw; $x++) {
                    $px = $bmp.GetPixel($x, $y)
                    if ($px.R -gt 200 -and $px.G -gt 200 -and $px.B -gt 200) { $light++ } elseif ($px.R -lt 80 -and $px.G -lt 80 -and $px.B -lt 80) { $dark++ }
                } }
                $record.pixels = $gw * $gh; $record.light = $light; $record.dark = $dark
                $gfx.Dispose(); $bmp.Dispose()
                $cw = [math]::Min(2 * $gw, $d[2] - $d[0]); $ch = [math]::Min(2 * $gh, $d[3] - $d[1])
                $crop = [System.Drawing.Bitmap]::new($cw, $ch)
                $gfx = [System.Drawing.Graphics]::FromImage($crop)
                $gfx.CopyFromScreen($d[2] - $cw, $d[3] - $ch, 0, 0, $crop.Size)
                $file = Join-Path (Split-Path $Out) ('{0}-grip-{1}.png' -f [IO.Path]::GetFileNameWithoutExtension($Out), $Step.at)
                $crop.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
                $record.file = Split-Path $file -Leaf
                $gfx.Dispose(); $crop.Dispose()
            }
        }
    } elseif ($Step.op -eq 'size') {
        # Grow the top-level dialog by <value> px each way, as a user dragging its corner: the player
        # gets WM_SIZE from its own thread's SetWindowPos handling. Asynchronous, because a synchronous
        # SetWindowPos on another process's window waits for it, and a player that crashes in its
        # WM_SIZE (the case this is for) never answers: the runner hung and wrote no result.
        $rect = [int[]]::new(4)
        [void] [MpcTest.User32]::GetWindowRect($root, $rect)
        $record.delivered = [MpcTest.User32]::SetWindowPos($root, [IntPtr]::Zero, 0, 0,
            ($rect[2] - $rect[0] + $Step.value), ($rect[3] - $rect[1] + $Step.value), 0x4016)   # SWP_ASYNCWINDOWPOS|SWP_NOMOVE|SWP_NOZORDER|SWP_NOACTIVATE
    }
    $record
}

function Send-Close {
    param($Process, [string] $Kind)
    if ($Kind -eq 'SC_CLOSE') {
        $Process.Refresh()
        if ($Process.HasExited -or $Process.MainWindowHandle -eq [IntPtr]::Zero) { return $false }
        return [MpcTest.User32]::PostMessageW($Process.MainWindowHandle, 0x0112, [IntPtr]0xF060, [IntPtr]::Zero)
    }
    if ($Process.HasExited) { return $false }
    # The player's own frame, by class: Process.MainWindowHandle is cached and, after a modal dialog, can
    # name nothing (measured: the close after an Options dialog reached no window).
    $main = Find-ProcessWindow -ProcessId $Process.Id -Class 'MediaPlayerClassicW'
    if ($main -ne [IntPtr]::Zero) { return [bool] [MpcTest.User32]::PostMessageW($main, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) }   # WM_CLOSE
    $Process.Refresh()
    return $Process.CloseMainWindow()
}

# MPC Video Renderer keeps its settings in the registry rather than in the player's ini, and under
# the user that runs the player -- which is this process, not the host's session. Apply them here,
# and put back exactly what was there, whatever happens later in the script.
$rendererKey = 'HKCU:\Software\MPC-BE Filters\MPC Video Renderer'
$rendererSaved = @{}
$rendererNames = @()
$rendererExisted = Test-Path $rendererKey
if ($RendererFile -and (Test-Path $RendererFile)) {
    $wanted = Get-Content $RendererFile -Raw | ConvertFrom-Json
    if (-not $rendererExisted) { New-Item -Path $rendererKey -Force | Out-Null }
    foreach ($p in $wanted.PSObject.Properties) {
        $rendererNames += $p.Name
        $was = (Get-ItemProperty -Path $rendererKey -Name $p.Name -ErrorAction SilentlyContinue).($p.Name)
        if ($null -ne $was) { $rendererSaved[$p.Name] = $was }
        Set-ItemProperty -Path $rendererKey -Name $p.Name -Value ([int]$p.Value) -Type DWord
    }
    $result.renderer = ($wanted.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ' '
}

# An empty line is a launch with no file at all (a case about what the player restores by itself), and
# Start-Process refuses an empty -ArgumentList.
$p = if ($ArgumentLine) { Start-Process -FilePath $Exe -ArgumentList $ArgumentLine -PassThru } else { Start-Process -FilePath $Exe -PassThru }
$result.pid = $p.Id

# The frame capture is an event in the time-ordered sequence below (kind 'capture'), so a
# case can drive the player first and capture after: posting commands at 4 and 6 s and
# capturing at 8.5 s captures the player those commands drove. No capture happens outside
# the sequence.
if ($RedirectStorm -gt 0) {
    # With AllowMultipleInstances=0 each further instance hands its file to the running player over WM_COPYDATA
    # and exits, and the running player closes what it has and opens the new file: the redirect path, at speed.
    $stormFiles = @($RedirectFiles | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
    $elapsed = ((Get-Date) - [datetime]$result.started).TotalSeconds
    if ($StormAtSec -gt $elapsed) { Start-Sleep -Milliseconds ([int](($StormAtSec - $elapsed) * 1000)) }
    $instances = @()
    for ($i = 0; $i -lt $RedirectStorm; $i++) {
        if ($i -gt 0) { Start-Sleep -Milliseconds $StormIntervalMs }
        $inst = Start-Process -FilePath $Exe -ArgumentList ('"{0}"' -f $stormFiles[$i % $stormFiles.Count]) -PassThru
        # Open the handle now: a process that exited before anything opened its handle reports $null for ExitCode.
        $null = $inst.Handle
        $instances += @{ proc = $inst; launchedAt = Get-Date }
    }
    Start-Sleep -Seconds 2
    $processName = [IO.Path]::GetFileNameWithoutExtension($Exe)
    $result.processesAfterStorm = @(Get-Process $processName -ErrorAction SilentlyContinue).Count
    $result.firstAliveAfterStorm = -not $p.HasExited
    $result.redirects = @($instances | ForEach-Object {
        # Each instance gets 10 s from its own launch, not from here, so 30 hung ones cannot stack past the host timeout.
        $remainingMs = [math]::Max(0, [int](10000 - ((Get-Date) - $_.launchedAt).TotalMilliseconds))
        $exited = if ($_.proc.HasExited) { $true } else { $_.proc.WaitForExit($remainingMs) }
        @{ exited = $exited; exitCode = if ($exited) { $_.proc.ExitCode } else { $null } }
    })
}

if ($SecondArgumentLine) {
    # One more instance of the same exe with its own command line: with AllowMultipleInstances=0 it hands the
    # line to the running player over WM_COPYDATA and exits. What the player does with it (/add, a start
    # position, a multi-file open) is what the case is about; how the instance exits is part of the result.
    # Several lines arrive as one selection when they are closer together than the player's redirect threshold,
    # which is how Explorer hands over a multi-file open: one instance per file.
    $elapsed = ((Get-Date) - [datetime]$result.started).TotalSeconds
    if ($SecondAtSec -gt $elapsed) { Start-Sleep -Milliseconds ([int](($SecondAtSec - $elapsed) * 1000)) }
    $seconds = @()
    foreach ($encoded in ($SecondArgumentLine -split ',')) {
        if ($seconds.Count) { Start-Sleep -Milliseconds $SecondIntervalMs }
        $line = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded))
        $inst = Start-Process -FilePath $Exe -ArgumentList $line -PassThru
        # Open the handle now: a process that exited before anything opened its handle reports $null for ExitCode.
        $null = $inst.Handle
        $seconds += $inst
    }
    $result.secondExited = $true
    $result.secondExitCode = 0
    foreach ($inst in $seconds) {
        $exited = if ($inst.HasExited) { $true } else { $inst.WaitForExit(10000) }
        if (-not $exited) { $result.secondExited = $false; $result.secondExitCode = $null }
        elseif ($result.secondExitCode -eq 0 -and $inst.ExitCode -ne 0) { $result.secondExitCode = $inst.ExitCode }
    }
}

if ($PostCommands -or $ProbeAt -or $HttpAt -or $CloseDialogAt -or $AcceptDialogAt -or $ControlAt -or $CaptureAtSec -gt 0) {
    # Posts, probes, web requests and dialog closes are one time-ordered sequence; at the same
    # second the post goes first, so a probe can observe what its command did. Delivered (for a
    # post) means a main window existed and PostMessageW accepted the message; MFC still drops a
    # command whose ON_UPDATE_COMMAND_UI reports it disabled, which is why cases post only once
    # playback is underway.
    # Events are pscustomobjects, not ordered dictionaries: in Windows PowerShell 5.1 (which this task
    # runs under) Sort-Object does not sort dictionaries by key - it leaves them in insertion order.
    $events = @()
    if ($PostCommands) {
        foreach ($entry in ($PostCommands -split ',')) {
            $parts = $entry -split ':'
            $at = [double]::Parse($parts[0], [Globalization.CultureInfo]::InvariantCulture)
            if ($parts[1] -eq 'msg') {
                # <sec>:msg:<msg>:<wParam> in decimal: that raw message, not a WM_COMMAND
                $events += [pscustomobject]@{ at = $at; id = 0; kind = 'post'; msg = [int] $parts[2]; wParam = [int] $parts[3] }
            } else {
                $events += [pscustomobject]@{ at = $at; id = [int] $parts[1]; kind = 'post'; msg = 0; wParam = 0 }
            }
        }
    }
    if ($ProbeAt) {
        foreach ($entry in ($ProbeAt -split ',')) {
            $events += [pscustomobject]@{ at = [double]::Parse($entry, [Globalization.CultureInfo]::InvariantCulture); id = 0; kind = 'probe' }
        }
    }
    if ($HttpAt) {
        $httpIndex = 0
        foreach ($encoded in ($HttpAt -split ',')) {
            $httpIndex++
            $parts = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)) -split '\|', 4
            $events += [pscustomobject]@{ at = [double]::Parse($parts[0], [Globalization.CultureInfo]::InvariantCulture); id = $httpIndex; kind = 'http'; method = $parts[1]; path = $parts[2]; body = $parts[3] }
        }
    }
    if ($CloseDialogAt) {
        foreach ($entry in ($CloseDialogAt -split ',')) {
            $parts = $entry -split ':', 2
            $events += [pscustomobject]@{ at = [double]::Parse($parts[0], [Globalization.CultureInfo]::InvariantCulture); id = 0; kind = 'dialog'; title = $parts[1] }
        }
    }
    if ($AcceptDialogAt) {
        foreach ($entry in ($AcceptDialogAt -split ',')) {
            $parts = $entry -split ':', 2
            $events += [pscustomobject]@{ at = [double]::Parse($parts[0], [Globalization.CultureInfo]::InvariantCulture); id = 0; kind = 'accept'; title = $parts[1] }
        }
    }
    if ($ControlAt) {
        foreach ($entry in ($ControlAt -split ',')) {
            $parts = $entry -split ':'
            $events += [pscustomobject]@{ at = [double]::Parse($parts[0], [Globalization.CultureInfo]::InvariantCulture); id = 0; kind = 'control'
                                          op = $parts[1]; ctrl = [int] $parts[2]; value = $(if ($parts.Count -gt 3) { [long] $parts[3] } else { 0 }) }
        }
    }
    if ($CaptureAtSec -gt 0) {
        $events += [pscustomobject]@{ at = $CaptureAtSec; id = 0; kind = 'capture' }
    }
    # At the same second: post first, then http, then dialog close or accept, then control steps,
    # then the frame capture, then probe (the probe sees the rest).
    $kindOrder = @{ post = 0; http = 1; dialog = 2; accept = 3; control = 4; capture = 5; probe = 6 }
    $controls = @()
    $posts = @()
    $probes = @()
    $webAnswers = @()
    $dialogCloses = @()
    $dialogAccepts = @()
    foreach ($step in ($events | Sort-Object at, { $kindOrder[$_.kind] })) {
        $elapsed = ((Get-Date) - [datetime]$result.started).TotalSeconds
        if ($step.at -gt $elapsed) { Start-Sleep -Milliseconds ([int](($step.at - $elapsed) * 1000)) }
        if ($step.kind -eq 'probe') {
            $probes += Get-PlaylistProbe $step.at $p.Id
        } elseif ($step.kind -eq 'http') {
            $webAnswers += Send-WebProbe -At $step.at -Method $step.method -Path $step.path -Body $step.body -Port $HttpPort -OutDir (Split-Path $Out) -Index $step.id
        } elseif ($step.kind -eq 'dialog') {
            $dialogCloses += [ordered]@{ at = $step.at; title = $step.title; delivered = (Close-PlayerDialog $p.Id $step.title) }
        } elseif ($step.kind -eq 'accept') {
            $dialogAccepts += [ordered]@{ at = $step.at; title = $step.title; delivered = (Accept-PlayerDialog $p.Id $step.title) }
        } elseif ($step.kind -eq 'control') {
            $controls += Invoke-ControlStep $p.Id $step
        } elseif ($step.kind -eq 'capture') {
            $result.aliveAtCapture = -not $p.HasExited
            $result.capture = (& 'C:\vdisplay\vdisplayctl.exe' capture $CaptureConnector $CapturePath | Out-String).Trim()
            $result.captureExit = $LASTEXITCODE
        } elseif ($step.msg) {
            # A raw message to the frame itself, found by class like Send-Close: Process.MainWindowHandle
            # is cached and behind a modal can name nothing, which is exactly when this form is used.
            $main = Find-ProcessWindow -ProcessId $p.Id -Class 'MediaPlayerClassicW'
            $delivered = ($main -ne [IntPtr]::Zero) -and
                         [MpcTest.User32]::PostMessageW($main, $step.msg, [IntPtr] $step.wParam, [IntPtr]::Zero)
            $posts += [ordered]@{ at = $step.at; id = 0; msg = $step.msg; delivered = [bool] $delivered }
        } else {
            $p.Refresh()
            $delivered = (-not $p.HasExited) -and ($p.MainWindowHandle -ne [IntPtr]::Zero) -and
                         [MpcTest.User32]::PostMessageW($p.MainWindowHandle, 0x0111, [IntPtr] $step.id, [IntPtr]::Zero)
            $posts += [ordered]@{ at = $step.at; id = $step.id; delivered = [bool] $delivered }
        }
    }
    if ($PostCommands) { $result.posts = $posts }
    if ($ProbeAt) { $result.probes = $probes }
    if ($HttpAt) { $result.http = $webAnswers }
    if ($CloseDialogAt) { $result.dialogCloses = $dialogCloses }
    if ($AcceptDialogAt) { $result.dialogAccepts = $dialogAccepts }
    if ($ControlAt) { $result.controls = $controls }
    # A case that changed the display scale leaves the guest at 100% for whoever runs next, whatever the
    # case did; the guests run at 100%.
    if ($script:dpiChanged) { $result.dpiRestored = Set-PrimaryScale 100 }
}

$closeWatch = $null
$closeNow = $false
if ($CloseWhenWindowAppears) {
    # Close while the file is still being opened: poll for a main window and send the moment there is one.
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        $p.Refresh()
        if ($p.HasExited) { break }
        if ($p.MainWindowHandle -ne [IntPtr]::Zero) {
            $result.windowAt = ((Get-Date) - [datetime]$result.started).TotalSeconds
            break
        }
        Start-Sleep -Milliseconds 20
    }
    $closeNow = $true
} elseif ($CloseAtSec -gt 0) {
    $elapsed = ((Get-Date) - [datetime]$result.started).TotalSeconds
    if ($CloseAtSec -gt $elapsed) { Start-Sleep -Milliseconds ([int](($CloseAtSec - $elapsed) * 1000)) }
    $closeNow = $true
}

if ($closeNow) {
    # As the user closing the window: the player's own shutdown runs, which is what writes the last position.
    # A repeat is a second click on X while the first one seems to have hung the player.
    $closeWatch = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt $CloseRepeat; $i++) {
        if ($i -gt 0) { Start-Sleep -Milliseconds 50 }
        $sent = Send-Close $p $CloseKind
        if ($i -eq 0) { $result.closeSent = [bool]$sent }
    }
    $result.closedAt = (Get-Date).ToString('o')
}

$result.closeToExitSec = $null
$result.timedOut = -not $p.WaitForExit($TimeoutSec * 1000)
if (-not $result.timedOut -and $closeWatch) {
    # How long the player's own shutdown took once the close was in its queue; a freeze on that path is a finding.
    $result.closeToExitSec = [math]::Round($closeWatch.Elapsed.TotalSeconds, 3)
}
if ($result.timedOut) {
    # A player that never exits is a finding in itself; do not leave it holding the audio device and the file.
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    $result.exitCode = $null
} else {
    $result.exitCode = $p.ExitCode
}

Start-Sleep -Seconds 3      # the audio driver writes its capture from a work item after the stream closes

if ($rendererNames.Count) {
    foreach ($n in $rendererNames) {
        if ($rendererSaved.ContainsKey($n)) { Set-ItemProperty -Path $rendererKey -Name $n -Value ([int]$rendererSaved[$n]) -Type DWord }
        else { Remove-ItemProperty -Path $rendererKey -Name $n -ErrorAction SilentlyContinue }
    }
    if (-not $rendererExisted) { Remove-Item $rendererKey -Recurse -Force -ErrorAction SilentlyContinue }
}

$result.finished = (Get-Date).ToString('o')
$result | ConvertTo-Json -Depth 4 | Set-Content $Out
