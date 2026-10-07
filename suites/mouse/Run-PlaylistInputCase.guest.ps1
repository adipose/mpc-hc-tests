# Runs on the target, in the console session. Drives the player's playlist with real mouse and keyboard
# input (SendInput) and records what happened; the host does the asserting. One JSON object goes to
# <OutDir>\result.json, with screen captures of the player window beside it.
#
# Two behaviours, from the playlist becoming a virtual list (c3f74b6) and its follow-up fixes:
#
#   a. playlist-type-to-find         54b5aaa66b restored type-ahead search on the virtual list via
#      LVN_ODFINDITEM, and c215310313 (#3844) changed its `idx > startidx` to `idx >= startidx`: the
#      search no longer skips the item it starts from. comctl passes iStart one past the focused item
#      (measured on comctl32 v6: focus on row N, a fresh search arrives with iStart = N+1). So with
#      delta at row 3 and doge at row 4: focus charlie (row 2) and type `d`. The search starts at row 3,
#      which itself matches. `idx >= startidx` returns 3 (delta); `idx > startidx` skips it and returns 4
#      (doge). One keystroke tells the two apart. (Selecting alpha first and typing `d` lands on delta
#      under both, since row 3 is past row 1 either way; it is kept as the sanity half of the case.)
#
#   b. playlist-click-time-column-no-edit   #3899 (419dadc920), issue #3885: a click on the time column
#      of the selected entry put it into edit mode with the time copied into the editor (item 1 of the
#      issue). Fixed, the bar cancels LVN_BEGINLABELEDIT for any subitem but COL_NAME, and the case
#      watches for an Edit child of the list holding the time. (The issue's item 2, a right-click below
#      the last item opening an editor, was dropped: it passes on 2.7.1.16, a build without the fix, so
#      it cannot fail.)
#
# The list is another process's window: rows and cells are read with LVM_GETITEMRECT/LVM_GETITEMTEXTW
# through memory allocated in the player (VirtualAllocEx), and selection with LVM_GETNEXTITEM, as the
# playback suite's probes do. The list itself is found by walking the player's windows to an ancestor
# titled "Playlist" (the bar's caption), the same approach as Run-PlayerCase.guest.ps1.
param([Parameter(Mandatory)] [string] $Job)

$ErrorActionPreference = 'Stop'
$j = Get-Content -Raw $Job | ConvertFrom-Json
$outDir = $j.OutDir
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory $outDir | Out-Null }
$result = [ordered]@{ started = (Get-Date).ToString('o'); error = $null }
$proc = $null
$root = [IntPtr]::Zero

try {
    . (Join-Path $PSScriptRoot 'MouseInput.guest.ps1')

    # Everything MouseInput.guest.ps1 does not already carry: the ancestor walk needs GetParent, the
    # cross-process reads need the memory APIs, and the type-ahead wait is measured in double-click times.
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public class MpcPlWin {
  [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr VirtualAllocEx(IntPtr h, IntPtr addr, UIntPtr size, uint type, uint protect);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool VirtualFreeEx(IntPtr h, IntPtr addr, UIntPtr size, uint type);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool WriteProcessMemory(IntPtr h, IntPtr addr, byte[] buf, UIntPtr size, out UIntPtr written);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, UIntPtr size, out UIntPtr read);
  [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetDoubleClickTime();
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
}
'@

    $target = Start-TargetWindow -Exe $j.Exe -ArgumentLine $j.ArgumentLine -TopClass 'MediaPlayerClassicW'
    $proc = $target.Process
    $root = $target.Root
    $wr = $target.Rect
    $result.foreground = $target.Foreground
    $result.screen = @{ W = [MouseRig]::GetSystemMetrics(0); H = [MouseRig]::GetSystemMetrics(1) }

    # The playlist's list control, found from outside the player. The player has several SysListView32
    # windows (the Subresync bar keeps one too), so a candidate is the playlist's only if its parent chain
    # includes a window titled "Playlist" -- the bar's caption, docked or floating.
    function Find-PlaylistListView {
        param([int] $ProcessId)
        $candidates = New-Object System.Collections.Generic.List[IntPtr]
        $childCallback = [MouseRig+EnumProc] {
            param($hWnd, $lParam)
            if ([MouseRig]::ClassOf($hWnd) -eq 'SysListView32') { $candidates.Add($hWnd) }
            return $true
        }
        $topCallback = [MouseRig+EnumProc] {
            param($hWnd, $lParam)
            $wp = [uint32]0
            [void][MouseRig]::GetWindowThreadProcessId($hWnd, [ref]$wp)
            if ($wp -eq $ProcessId) { [void][MouseRig]::EnumChildWindows($hWnd, $childCallback, [IntPtr]::Zero) }
            return $true
        }
        [void][MouseRig]::EnumWindows($topCallback, [IntPtr]::Zero)
        foreach ($candidate in $candidates) {
            $walk = $candidate
            while ($walk -ne [IntPtr]::Zero) {
                if ([MouseRig]::TitleOf($walk) -eq 'Playlist') { return $candidate }
                $walk = [MpcPlWin]::GetParent($walk)
            }
        }
        # No parent chain titled Playlist: a sole candidate can only be the playlist's list.
        if ($candidates.Count -eq 1) { return $candidates[0] }
        [IntPtr]::Zero
    }

    $script:hProc = [MpcPlWin]::OpenProcess(0x0438, $false, [uint32]$proc.Id)   # VM_OPERATION|VM_READ|VM_WRITE|QUERY_INFORMATION

    # A row's bounding rectangle in the list's client coordinates. The message's lParam is a pointer, so
    # the RECT lives in the player's address space for the duration of the call.
    function Read-ListItemRect {
        param([IntPtr] $List, [int] $Index)
        $size = ([UIntPtr]::new([uint64]16))
        $mem = [MpcPlWin]::VirtualAllocEx($hProc, [IntPtr]::Zero, $size, 0x1000, 0x04)   # MEM_COMMIT, PAGE_READWRITE
        if ($mem -eq [IntPtr]::Zero) { return $null }
        try {
            $in = New-Object byte[] 16        # RECT.Left = LVIR_BOUNDS (0) on the way in
            $w = [UIntPtr]::Zero
            [void][MpcPlWin]::WriteProcessMemory($hProc, $mem, $in, $size, [ref]$w)
            if ([MouseRig]::SendMessage($List, 0x100E, [IntPtr]$Index, $mem) -eq [IntPtr]::Zero) { return $null }  # LVM_GETITEMRECT
            $out = New-Object byte[] 16
            $r = [UIntPtr]::Zero
            [void][MpcPlWin]::ReadProcessMemory($hProc, $mem, $out, $size, [ref]$r)
            @{ L = [BitConverter]::ToInt32($out, 0); T = [BitConverter]::ToInt32($out, 4)
               R = [BitConverter]::ToInt32($out, 8); B = [BitConverter]::ToInt32($out, 12) }
        } finally {
            [void][MpcPlWin]::VirtualFreeEx($hProc, $mem, [UIntPtr]::Zero, 0x8000)       # MEM_RELEASE
        }
    }

    # A cell's text, for the time column: LVIF_TEXT, LVITEMW on x64 (mask@0, iItem@4, iSubItem@8,
    # pszText@24, cchTextMax@32), the text buffer right behind the struct.
    function Read-ListItemText {
        param([IntPtr] $List, [int] $Index, [int] $SubItem)
        $size = ([UIntPtr]::new([uint64]576))
        $mem = [MpcPlWin]::VirtualAllocEx($hProc, [IntPtr]::Zero, $size, 0x1000, 0x04)
        if ($mem -eq [IntPtr]::Zero) { return $null }
        try {
            $in = New-Object byte[] 576
            [Array]::Copy([BitConverter]::GetBytes([uint32]1), 0, $in, 0, 4)             # LVIF_TEXT
            [Array]::Copy([BitConverter]::GetBytes($Index), 0, $in, 4, 4)
            [Array]::Copy([BitConverter]::GetBytes($SubItem), 0, $in, 8, 4)
            [Array]::Copy([BitConverter]::GetBytes($mem.ToInt64() + 64), 0, $in, 24, 8)  # pszText
            [Array]::Copy([BitConverter]::GetBytes([int32]256), 0, $in, 32, 4)           # cchTextMax
            $w = [UIntPtr]::Zero
            [void][MpcPlWin]::WriteProcessMemory($hProc, $mem, $in, $size, [ref]$w)
            [void][MouseRig]::SendMessage($List, 0x1073, [IntPtr]$Index, $mem)           # LVM_GETITEMTEXTW
            $out = New-Object byte[] 512
            $r = [UIntPtr]::Zero
            [void][MpcPlWin]::ReadProcessMemory($hProc, [IntPtr]($mem.ToInt64() + 64), $out, ([UIntPtr]::new([uint64]512)), [ref]$r)
            $s = [Text.Encoding]::Unicode.GetString($out)
            $nul = $s.IndexOf([char]0)
            if ($nul -ge 0) { $s.Substring(0, $nul) } else { $s }
        } finally {
            [void][MpcPlWin]::VirtualFreeEx($hProc, $mem, [UIntPtr]::Zero, 0x8000)
        }
    }

    # An in-place editor in the playlist is an Edit child of the list view (the themed subclass keeps the
    # window class). Watching for one is how a label edit that should not have started is seen.
    function Test-EditChild {
        param([IntPtr] $List)
        $script:editHit = $false
        $script:editHwnd = [IntPtr]::Zero
        $cb = [MouseRig+EnumProc] {
            param($hWnd, $lParam)
            if ([MouseRig]::ClassOf($hWnd) -eq 'Edit') { $script:editHit = $true; $script:editHwnd = $hWnd; return $false }
            return $true
        }
        [void][MouseRig]::EnumChildWindows($List, $cb, [IntPtr]::Zero)
        $script:editHit
    }

    # What an in-place editor holds. WM_GETTEXT is marshalled across processes by the system, which
    # GetWindowText is not for another process's control.
    Add-Type -Namespace MpcPlText -Name Win -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr SendMessageTimeoutW(System.IntPtr hWnd, uint msg, System.IntPtr wParam, System.Text.StringBuilder lParam, uint flags, uint timeout, out System.IntPtr result);
'@
    function Get-EditText {
        param([IntPtr] $Edit)
        if ($Edit -eq [IntPtr]::Zero) { return $null }
        $sb = New-Object System.Text.StringBuilder 512
        $r = [IntPtr]::Zero
        [void][MpcPlText.Win]::SendMessageTimeoutW($Edit, 0x000D, [IntPtr]512, $sb, 0x2, 1000, [ref]$r)   # WM_GETTEXT, SMTO_ABORTIFHUNG
        $sb.ToString()
    }

    function Get-ListSelection {
        param([IntPtr] $List)
        [MouseRig]::SendMessage($List, 0x100C, [IntPtr]::new(-1), [IntPtr]::new(2)).ToInt32()   # LVM_GETNEXTITEM, LVNI_SELECTED
    }

    # Every capture is the whole main window, so the title bar and the playlist are both in the evidence.
    function Save-PlayerShot {
        param([string] $Name)
        $r = New-Object MouseRig+RECT
        [void][MouseRig]::GetWindowRect($root, [ref]$r)
        $b = [Math]::Min($r.B, [MouseRig]::GetSystemMetrics(1))
        Save-ScreenRegion (Join-Path $outDir "$Name.png") $r.L $r.T $r.R $b
    }

    # --- settle: the playlist list shown, six entries, alpha playing ----------------------------

    $list = [IntPtr]::Zero
    $deadline = (Get-Date).AddSeconds(20)
    while ($list -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $list = Find-PlaylistListView $proc.Id
    }
    $count = -1
    if ($list -ne [IntPtr]::Zero) {
        $count = [MouseRig]::SendMessage($list, 0x1004, [IntPtr]::Zero, [IntPtr]::Zero).ToInt32()   # LVM_GETITEMCOUNT
    }
    $titleAtStart = ''
    $deadline = (Get-Date).AddSeconds(15)
    while ($titleAtStart -notlike '*alpha*' -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 300
        $titleAtStart = Get-WindowTextOf $root
    }
    $result.list = [ordered]@{
        found = ($list -ne [IntPtr]::Zero); count = $count; titleAtStart = $titleAtStart
        visible = ($list -ne [IntPtr]::Zero -and [MouseRig]::IsWindowVisible($list))
    }
    if ($list -eq [IntPtr]::Zero) { throw 'the playlist list control was not found' }

    # Geometry. A row bounds rectangle spans every column, so its width is the client width; the time
    # column is the rightmost one (COL_TIME), its width readable without a struct.
    $rows = @{}
    foreach ($i in 0..5) {
        $rows[$i] = Read-ListItemRect $list $i
        if (-not $rows[$i]) { throw "no item rectangle for playlist row $i" }
    }
    $itemHeight = $rows[0].B - $rows[0].T
    $clientWidth = $rows[0].R - $rows[0].L
    $timeColWidth = [MouseRig]::SendMessage($list, 0x101D, [IntPtr]1, [IntPtr]0).ToInt32()   # LVM_GETCOLUMNWIDTH (LVM_FIRST + 29), COL_TIME
    $origin = New-Object MpcPlWin+POINT
    [void][MpcPlWin]::ClientToScreen($list, [ref]$origin)
    $result.list.itemHeight = $itemHeight
    $result.list.clientWidth = $clientWidth
    $result.list.timeColWidth = $timeColWidth
    $result.list.doubleClickTime = [int][MpcPlWin]::GetDoubleClickTime()

    function RowPoint { param([int] $Row, [int] $OffsetX)
        @{ X = $origin.X + $OffsetX; Y = $origin.Y + $rows[$Row].T + [int]($itemHeight / 2) }
    }
    # The name column starts with an owner-drawn row number; 40 px in is on the name at any sane DPI.
    function NamePoint { param([int] $Row) RowPoint $Row ([Math]::Min(40, [int](($clientWidth - $timeColWidth) / 2))) }
    function TimePoint { param([int] $Row) RowPoint $Row ($clientWidth - [int]($timeColWidth / 2)) }
    $emptyPoint = RowPoint 5 40
    $emptyPoint = @{ X = $emptyPoint.X; Y = $emptyPoint.Y + $itemHeight + 20 }

    # Focus the way a user gives it: a click on the empty part of the list (which also leaves no timer
    # state), then a click on an item. The list must hold the keyboard focus or typing goes elsewhere.
    Move-PointerGlide $emptyPoint.X $emptyPoint.Y
    [void][MouseRig]::Click()
    Start-Sleep -Milliseconds 400
    $p0 = NamePoint 0
    Move-PointerGlide $p0.X $p0.Y
    [void][MouseRig]::Click()
    Start-Sleep -Milliseconds 500
    $result.setup = [ordered]@{
        foregroundIsPlayer = ([MouseRig]::GetForegroundWindow() -eq $root)
        focusIsList        = ([MouseRig]::FocusOf($list) -eq $list)
        selected           = (Get-ListSelection $list)
    }
    Save-PlayerShot 'setup'

    # --- case a: playlist-type-to-find -----------------------------------------------------------
    # a1: select alpha (row 0), type `d`. The search starts at row 1 and delta (row 3) is the first match
    #     under both the fixed and the unfixed comparison.
    # a2: after the type-ahead timeout (comctl keeps the accumulated string for roughly twice the
    #     double-click time; two seconds clears it), select charlie (row 2) and type `d` again. Now the
    #     item the search starts from -- row 3, delta -- matches itself. The fixed handler returns it; the
    #     unfixed one skips past it to doge (row 4), which is exactly the #3844 complaint.
    $p2 = NamePoint 2
    $selAlpha = -1; $selAfterD1 = -1; $selCharlie = -1; $selAfterD2 = -1
    Move-PointerGlide $p0.X $p0.Y
    [void][MouseRig]::Click()
    Start-Sleep -Milliseconds 400
    $selAlpha = Get-ListSelection $list
    [void][MouseRig]::KeyPress(0x44)   # 'D'
    $selAfterD1 = $selAlpha
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt 1.5 -and $selAfterD1 -eq $selAlpha) {
        Start-Sleep -Milliseconds 100
        $selAfterD1 = Get-ListSelection $list
    }
    Save-PlayerShot 'a1-type-d'

    $waitMs = [Math]::Max(2000, 3 * [int][MpcPlWin]::GetDoubleClickTime())
    Start-Sleep -Milliseconds $waitMs
    Move-PointerGlide $p2.X $p2.Y
    [void][MouseRig]::Click()
    Start-Sleep -Milliseconds 400
    $selCharlie = Get-ListSelection $list
    [void][MouseRig]::KeyPress(0x44)   # 'D'
    $selAfterD2 = $selCharlie
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt 1.5 -and $selAfterD2 -eq $selCharlie) {
        Start-Sleep -Milliseconds 100
        $selAfterD2 = Get-ListSelection $list
    }
    Save-PlayerShot 'a2-type-d'
    $result.caseA = [ordered]@{
        selAlpha = $selAlpha; selAfterD1 = $selAfterD1
        selCharlie = $selCharlie; selAfterD2 = $selAfterD2
        typeAheadWaitMs = $waitMs
    }

    # --- case b: playlist-click-time-column-no-edit ----------------------------------------------
    # Durations reach the column from playing (SetCurTime) -- the guest has no MediaInfo library, so only
    # played rows show one. Row 0 (alpha) played at start; wait for its time cell as proof the column is
    # populated, then work on row 1 (bravo), which is neither playing nor selected.
    $timeTextRow0 = ''
    $deadline = (Get-Date).AddSeconds(15)
    while (-not $timeTextRow0 -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $timeTextRow0 = Read-ListItemText $list 0 1
    }

    # Select bravo by its name, then a single real click on its time cell, and watch past the
    # double-click time -- the interval the in-place-edit timer runs on. A click on the selected entry may
    # start a rename of it (LVS_EDITLABELS; the time column's own edit is cancelled in
    # OnLvnBeginlabeleditList), so an editor is allowed: what #3885 reported is the editor taking the
    # time cell's text. Its text is recorded, then it is dismissed.
    $p1n = NamePoint 1
    Move-PointerGlide $p1n.X $p1n.Y
    [void][MouseRig]::Click()
    Start-Sleep -Milliseconds 400
    $selBravo = Get-ListSelection $list
    $p1t = TimePoint 1
    Move-PointerGlide $p1t.X $p1t.Y
    [void][MouseRig]::Click()
    $t0 = Get-Date
    $editSeenTime = $false
    $editTextTime = $null
    while (((Get-Date) - $t0).TotalSeconds -lt 1.5) {
        if (Test-EditChild $list) {
            $editSeenTime = $true
            $text = Get-EditText $script:editHwnd
            if ($text) { $editTextTime = $text }
        }
        Start-Sleep -Milliseconds 50
    }
    Save-PlayerShot 'b-time-click'
    if ($editSeenTime) {
        [void][MouseRig]::KeyPress(0x1B)   # Escape: cancel the rename without changing the entry
        Start-Sleep -Milliseconds 400
    }
    $result.caseB = [ordered]@{
        timeTextRow0     = $timeTextRow0
        selBravo         = $selBravo
        editSeenTime     = $editSeenTime
        editTextTime     = $editTextTime
        nameRow1         = (Read-ListItemText $list 1 0)
    }
    Save-PlayerShot 'b-after-escape'
} catch {
    $result.error = $_.Exception.Message + ' @ ' + $_.InvocationInfo.PositionMessage
} finally {
    if ($root -ne [IntPtr]::Zero) {
        [void][MouseRig]::PostMessage($root, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE
        if ($proc -and -not $proc.WaitForExit(15000)) {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            $result.killedOnClose = $true
        } elseif ($proc) {
            $result.exitCode = $proc.ExitCode
        }
    } elseif ($proc) {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    }
    if ($script:hProc) { [void][MpcPlWin]::CloseHandle($script:hProc) }
    $result.finished = (Get-Date).ToString('o')
    $result | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $outDir 'result.json')
}
