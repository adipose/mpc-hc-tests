# Runs on the target, in the console session. Opens the player's Options dialog at the Keys page and
# double-clicks a key entry's hotkey cell with real mouse input (SendInput); the host does the asserting.
# One JSON object goes to <OutDir>\result.json, with a screen capture of the dialog beside it.
#
# #3853 (fixed by f17f348494 in 2.7.1): a double-click on a key entry did not enter edit mode. The Keys
# list is a CPlayerListCtrl constructed with bDoubleClickAction = false, so a click on the row that is
# already selected arms a 1 ms edit timer (OnLButtonDown); the timer's OnTimer asks the page to edit the
# cell, and for COL_KEY that is CPlayerListCtrl::ShowInPlaceWinHotkey, an Edit child of the list
# (IDC_WINHOTKEY1). Unfixed, the timer ran for GetDoubleClickTime() and the second click of a
# double-click arrives as WM_LBUTTONDBLCLK, which killed the timer before it could fire, so a
# double-click never opened the editor. Fixed, the 1 ms timer fires on the first click of the pair.
#
# Because the timer only arms on an already-selected row, the target row is selected by a plain click
# before the double-click; a bare double-click on an unselected row only selects it (the second click
# becomes WM_LBUTTONDBLCLK, which arms nothing) and would open the editor on no build. The selecting
# click is kept more than GetDoubleClickTime() away from the double-click so the two cannot pair into
# a double-click of their own. The click before that, on another row, gives the dialog its focus so
# no click is eaten by activation.
#
# The list is another process's window: row rectangles are read with LVM_GETITEMRECT through memory
# allocated in the player (VirtualAllocEx) and the selection with LVM_GETNEXTITEM, as
# Run-PlaylistInputCase.guest.ps1 does.
param([Parameter(Mandatory)] [string] $Job)

$ErrorActionPreference = 'Stop'
$j = Get-Content -Raw $Job | ConvertFrom-Json
$outDir = $j.OutDir
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory $outDir | Out-Null }
$result = [ordered]@{ started = (Get-Date).ToString('o'); error = $null }
$proc = $null

try {
    . (Join-Path $PSScriptRoot 'MouseInput.guest.ps1')

    # The cross-process row-rectangle read needs the memory APIs, and the double-click is measured
    # against GetDoubleClickTime.
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
  [DllImport("user32.dll")] public static extern uint GetDoubleClickTime();
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
}
'@

    $target = Start-TargetWindow -Exe $j.Exe -TopClass 'MediaPlayerClassicW' -PostCommand ([int]$j.PostCommand) -DialogTitle $j.DialogTitle
    $proc = $target.Process
    $root = $target.Root            # the Options dialog, opened at the Keys page by LastUsedPage
    $result.foreground = $target.Foreground
    $result.screen = @{ W = [MouseRig]::GetSystemMetrics(0); H = [MouseRig]::GetSystemMetrics(1) }

    # The keys list: the page's SysListView32, found by its control id. Other pages keep lists under the
    # same id, but only the shown page's is visible, which is what FindChild asks for.
    $list = [IntPtr]::Zero
    $deadline = (Get-Date).AddSeconds(15)
    while ($list -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 300
        $list = [MouseRig]::FindChild($root, [int]$j.ListId)
    }
    $count = -1
    if ($list -ne [IntPtr]::Zero) {
        $count = [MouseRig]::SendMessage($list, 0x1004, [IntPtr]::Zero, [IntPtr]::Zero).ToInt32()   # LVM_GETITEMCOUNT
    }
    $result.list = [ordered]@{ found = ($list -ne [IntPtr]::Zero); count = $count }
    if ($list -eq [IntPtr]::Zero) { throw 'the Keys page list control was not found' }

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

    # The in-place hotkey editor is an Edit child of the list view (CEditWithButton subclasses a plain
    # Edit; the window class stays "Edit"). Watching for one is how edit mode is seen from outside.
    function Test-EditChild {
        param([IntPtr] $List)
        $script:editHit = $false
        $script:editHwnd = [IntPtr]::Zero
        $script:editId = 0
        $cb = [MouseRig+EnumProc] {
            param($hWnd, $lParam)
            if ([MouseRig]::ClassOf($hWnd) -eq 'Edit') {
                $script:editHit = $true
                $script:editHwnd = $hWnd
                $script:editId = [MouseRig]::GetDlgCtrlID($hWnd)
                return $false
            }
            return $true
        }
        [void][MouseRig]::EnumChildWindows($List, $cb, [IntPtr]::Zero)
        $script:editHit
    }

    function Get-ListSelection {
        param([IntPtr] $List)
        [MouseRig]::SendMessage($List, 0x100C, [IntPtr]::new(-1), [IntPtr]::new(2)).ToInt32()   # LVM_GETNEXTITEM, LVNI_SELECTED
    }

    # Geometry. Rows 0 and 1 are at the top of an unscrolled list, always visible. The hotkey column is
    # COL_KEY (1); a column width reads back without a struct.
    $rows = @{}
    foreach ($i in 0..1) {
        $rows[$i] = Read-ListItemRect $list $i
        if (-not $rows[$i]) { throw "no item rectangle for keys row $i" }
    }
    $itemHeight = $rows[0].B - $rows[0].T
    $colCmdWidth = [MouseRig]::SendMessage($list, 0x101D, [IntPtr]0, [IntPtr]0).ToInt32()   # LVM_GETCOLUMNWIDTH (LVM_FIRST + 29), COL_CMD
    $colKeyWidth = [MouseRig]::SendMessage($list, 0x101D, [IntPtr]1, [IntPtr]0).ToInt32()   # COL_KEY
    $origin = New-Object MpcPlWin+POINT
    [void][MpcPlWin]::ClientToScreen($list, [ref]$origin)
    $result.list.itemHeight = $itemHeight
    $result.list.doubleClickTime = [int][MpcPlWin]::GetDoubleClickTime()

    function RowPoint { param([int] $Row, [int] $OffsetX)
        @{ X = $origin.X + $OffsetX; Y = $origin.Y + $rows[$Row].T + [int]($itemHeight / 2) }
    }
    $keyX = $colCmdWidth + [int]($colKeyWidth / 2)

    # Focus the way a user gives it: a click on another row's command cell, which also activates the
    # dialog, so no click of the double-click later is eaten by activation.
    $p0 = RowPoint 0 ([int]($colCmdWidth / 2))
    Move-PointerGlide $p0.X $p0.Y
    [void][MouseRig]::Click()
    Start-Sleep -Milliseconds 400
    $result.setup = [ordered]@{
        foregroundIsDialog = ([MouseRig]::GetForegroundWindow() -eq $root)
        focusIsList        = ([MouseRig]::FocusOf($list) -eq $list)
        selected           = (Get-ListSelection $list)
    }

    # Select the target row (row 1) by its key cell, then a real double-click at the same point. The
    # wait after the selecting click is past the double-click time, so that click pairs with nothing;
    # the two clicks after it are 100 ms apart, within the time, so the second arrives as
    # WM_LBUTTONDBLCLK.
    $p1 = RowPoint 1 $keyX
    Move-PointerGlide $p1.X $p1.Y
    [void][MouseRig]::Click()
    Start-Sleep -Milliseconds ($result.list.doubleClickTime + 250)
    $selectedBeforeDbl = Get-ListSelection $list
    [void][MouseRig]::Click()
    Start-Sleep -Milliseconds 100
    [void][MouseRig]::Click()
    $t0 = Get-Date
    $editSeen = $false
    $editSeenAt = $null
    $editId = 0
    while (((Get-Date) - $t0).TotalSeconds -lt 1) {
        if (-not $editSeen -and (Test-EditChild $list)) {
            $editSeen = $true
            $editSeenAt = [math]::Round(((Get-Date) - $t0).TotalSeconds, 2)
            $editId = $script:editId
        }
        Start-Sleep -Milliseconds 50
    }
    $dr = New-Object MouseRig+RECT
    [void][MouseRig]::GetWindowRect($root, [ref]$dr)
    Save-ScreenRegion (Join-Path $outDir 'keys-dblclick.png') $dr.L $dr.T $dr.R ([Math]::Min($dr.B, [MouseRig]::GetSystemMetrics(1)))

    # Cancel closes the dialog so nothing the editor holds is saved. (Escape is no way out: a hotkey editor
    # takes Escape as the key to assign, measured on develop.)
    $result.caseK = [ordered]@{
        selectedBeforeDbl    = $selectedBeforeDbl
        editSeen             = $editSeen
        editSeenAt           = $editSeenAt
        editId               = $editId
    }
    [void][MouseRig]::PostMessage($root, 0x0111, [IntPtr]2, [IntPtr]::Zero)   # WM_COMMAND, IDCANCEL
    $dialogClosed = $false
    $deadline = (Get-Date).AddSeconds(5)
    while (-not $dialogClosed -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 300
        $dialogClosed = ([MouseRig]::FindTop([uint32]$proc.Id, '', $j.DialogTitle) -eq [IntPtr]::Zero)
    }
    $result.dialogClosed = $dialogClosed
} catch {
    $result.error = $_.Exception.Message + ' @ ' + $_.InvocationInfo.PositionMessage
} finally {
    if ($proc) {
        try {
            $dlg = [MouseRig]::FindTop([uint32]$proc.Id, '', $j.DialogTitle)
            if ($dlg -ne [IntPtr]::Zero) {
                [void][MouseRig]::PostMessage($dlg, 0x0111, [IntPtr]2, [IntPtr]::Zero)   # WM_COMMAND, IDCANCEL
                Start-Sleep -Milliseconds 800
            }
            $main = [MouseRig]::FindTop([uint32]$proc.Id, 'MediaPlayerClassicW', '')
            if ($main -ne [IntPtr]::Zero) {
                [void][MouseRig]::PostMessage($main, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE
            }
            if (-not $proc.WaitForExit(15000)) {
                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                $result.killedOnClose = $true
            } else {
                $result.exitCode = $proc.ExitCode
            }
        } catch {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        }
    }
    if ($script:hProc) { [void][MpcPlWin]::CloseHandle($script:hProc) }
    $result.finished = (Get-Date).ToString('o')
    $result | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $outDir 'result.json')
}
