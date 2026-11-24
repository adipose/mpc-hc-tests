# Runs on the target, in the console session. Opens the player's Options dialog at the External Filters
# page, with one registered filter (AVI Splitter) seeded in the ini, selects the filter with a real click,
# and adds three media types through Add Media Type..., typing into the Select Media Type combo with real
# input (SendInput). Options is then closed with OK and the player with WM_CLOSE, and the ini it wrote is
# copied beside result.json; the host reads the stored types from it.
#
# Ledger 132: the dialog's combo is a CBS_DROPDOWN, and OnOK took m_guids[GetCurSel()] whenever the list had
# a selection, ignoring the text the box showed. Typing with the list closed does not show it: the combo
# clears its own selection on every edit change there. Typing with the list dropped does: closing it without
# a pick puts the selection back on the entry selected before it dropped, the typed text stays, and no
# CBN_EDITCHANGE follows. OK then stored that entry. Fixed, the dialog looks the entry up from the text.
#
# Three steps, in this order, each one Add Media Type... on the same filter:
#   pick     entry 1 selected, OK clicked: that entry is stored (MEDIATYPE_Video).
#   closed   entry 2 selected, retyped with the list closed as {e436eb7d-...}, OK: the typed GUID is stored.
#   dropped  entry 3 selected, list dropped with F4, retyped as {e436eb7e-...}, a click on the caption to
#            close the list (the list covers OK, so a click there would pick an entry), then OK: the typed
#            GUID must be stored. Unfixed, entry 3 is.
# pick and closed pass on develop as well; they hold the fix to what already worked.
#
# Selecting an entry is CB_SETCURSEL rather than a pick from the open list: the dialog has no selection
# handler, so it is in the same state either way, and the retyping that matters is real keys.
param([Parameter(Mandatory)] [string] $Job)

$ErrorActionPreference = 'Stop'
$j = Get-Content -Raw $Job | ConvertFrom-Json
$outDir = $j.OutDir
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory $outDir | Out-Null }
$result = [ordered]@{ started = (Get-Date).ToString('o'); error = $null }
$proc = $null
$dlgTitle = 'Select Media Type'

try {
    . (Join-Path $PSScriptRoot 'MouseInput.guest.ps1')

    $target = Start-TargetWindow -Exe $j.Exe -TopClass 'MediaPlayerClassicW' -PostCommand ([int]$j.PostCommand) -DialogTitle $j.DialogTitle
    $proc = $target.Process
    $root = $target.Root            # the Options dialog, opened at the External Filters page by LastUsedPage
    $result.foreground = $target.Foreground

    $list = [IntPtr]::Zero
    $deadline = (Get-Date).AddSeconds(15)
    while ($list -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 300
        $list = [MouseRig]::FindChild($root, [int]$j.ListId)
    }
    if ($list -eq [IntPtr]::Zero) { throw 'the filter list was not found on the External Filters page' }
    $addBtn = [MouseRig]::FindChild($root, [int]$j.AddTypeId)
    if ($addBtn -eq [IntPtr]::Zero) { throw 'the Add Media Type button was not found' }
    $result.filterCount = [MouseRig]::SendMessage($list, 0x1004, [IntPtr]::Zero, [IntPtr]::Zero).ToInt32()   # LVM_GETITEMCOUNT

    function Click-At {
        param([int] $X, [int] $Y)
        Move-PointerGlide $X $Y
        [void][MouseRig]::Click()
    }
    function Click-Center {
        param([IntPtr] $Hwnd, [int] $FromRight = -1)
        $r = New-Object MouseRig+RECT
        [void][MouseRig]::GetWindowRect($Hwnd, [ref]$r)
        $x = if ($FromRight -ge 0) { $r.R - $FromRight } else { [int](($r.L + $r.R) / 2) }
        Click-At $x ([int](($r.T + $r.B) / 2))
    }

    # A real click on the filter's label (not its check box) selects it, and the page's idle update enables
    # Add Media Type.
    $row = [MouseRig]::ListItemRect($list, 0, 2)   # LVIR_LABEL
    if ($row.R -le $row.L) { throw 'the seeded filter has no row in the list' }
    Click-At ([int](($row.L + $row.R) / 2)) ([int](($row.T + $row.B) / 2))
    Start-Sleep -Milliseconds 600
    $result.addEnabled = [MouseRig]::IsWindowEnabled($addBtn)

    function Get-CurSel { param([IntPtr] $Combo) [MouseRig]::SendMessage($Combo, 0x0147, [IntPtr]::Zero, [IntPtr]::Zero).ToInt32() }
    function Get-Dropped { param([IntPtr] $Combo) [MouseRig]::SendMessage($Combo, 0x0157, [IntPtr]::Zero, [IntPtr]::Zero) -ne [IntPtr]::Zero }

    function Invoke-AddType {
        param([int] $Index, [string] $Text = '', [switch] $Drop)
        $step = [ordered]@{}
        Click-Center $addBtn
        $dlg = [IntPtr]::Zero
        $deadline = (Get-Date).AddSeconds(10)
        while ($dlg -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 200
            $dlg = [MouseRig]::FindTop([uint32]$proc.Id, '', $dlgTitle)
        }
        $step.dialogOpened = ($dlg -ne [IntPtr]::Zero)
        if (-not $step.dialogOpened) { return $step }
        Start-Sleep -Milliseconds 400
        $combo = [MouseRig]::FindChild($dlg, [int]$j.ComboId)
        $okBtn = [MouseRig]::FindChild($dlg, 1)
        $info = New-Object MouseRig+COMBOBOXINFO
        $info.cbSize = [Runtime.InteropServices.Marshal]::SizeOf([type][MouseRig+COMBOBOXINFO])
        if ($combo -eq [IntPtr]::Zero -or $okBtn -eq [IntPtr]::Zero -or -not [MouseRig]::GetComboBoxInfo($combo, [ref]$info) -or $info.hwndItem -eq [IntPtr]::Zero) {
            throw 'the Select Media Type dialog has no editable combo or no OK button'
        }
        $edit = $info.hwndItem
        [void][MouseRig]::SendMessage($combo, 0x014E, [IntPtr]$Index, [IntPtr]::Zero)   # CB_SETCURSEL
        Start-Sleep -Milliseconds 300
        $step.selectedText = Get-WindowTextOf $edit
        if ($Text) {
            # A real click near the right end of the edit puts the caret after the text; End makes sure.
            Click-Center $edit 6
            Start-Sleep -Milliseconds 300
            $step.focusIsEdit = ([MouseRig]::FocusOf($edit) -eq $edit)
            if ($Drop) {
                [void][MouseRig]::KeyPress(0x73)   # VK_F4 drops the list, the focus staying in the edit
                Start-Sleep -Milliseconds 400
            }
            $step.dropped = Get-Dropped $combo
            [void][MouseRig]::KeyPress(0x23)   # VK_END
            foreach ($i in 1..($step.selectedText.Length + 2)) { [void][MouseRig]::KeyPress(0x08); Start-Sleep -Milliseconds 30 }   # VK_BACK
            [void][MouseRig]::KeyText($Text)
            Start-Sleep -Milliseconds 500      # OK's enabled state follows on the dialog's idle update
            $step.typed = Get-WindowTextOf $edit
            $step.curSelAfterTyping = Get-CurSel $combo
            $step.droppedAfterTyping = Get-Dropped $combo
            if ($step.droppedAfterTyping) {
                # The dropped list covers OK, so a click aimed at OK would pick a list entry. A click on the
                # caption, above the combo, closes the list without a pick, as a user clicking away does.
                $wr = New-Object MouseRig+RECT
                [void][MouseRig]::GetWindowRect($dlg, [ref]$wr)
                $origin = New-Object MouseRig+POINT
                [void][MouseRig]::ClientToScreen($dlg, [ref]$origin)
                Click-At ($wr.L + 60) ([int](($wr.T + $origin.Y) / 2))
                Start-Sleep -Milliseconds 600
                $step.droppedAfterClose = Get-Dropped $combo
                $step.textAfterClose = Get-WindowTextOf $edit
                $step.curSelAfterClose = Get-CurSel $combo
            }
        }
        Start-Sleep -Milliseconds 300
        $step.okEnabled = [MouseRig]::IsWindowEnabled($okBtn)
        Click-Center $okBtn
        Start-Sleep -Milliseconds 600
        $open = [MouseRig]::IsWindow($dlg)
        if ($open) {
            $step.dialogStuck = $true
            [void][MouseRig]::PostMessage($dlg, 0x0111, [IntPtr]2, [IntPtr]::Zero)   # WM_COMMAND, IDCANCEL
            Start-Sleep -Milliseconds 500
        }
        # A type already on the filter raises a message box owned by the page; nothing here should, but
        # it would block the next step, so it is recorded and dismissed.
        $box = [MouseRig]::FindTop([uint32]$proc.Id, '#32770', '')
        if ($box -ne [IntPtr]::Zero -and $box -ne $root) {
            $step.messageBox = [MouseRig]::TitleOf($box)
            [void][MouseRig]::PostMessage($box, 0x0111, [IntPtr]1, [IntPtr]::Zero)
            Start-Sleep -Milliseconds 400
        }
        $step
    }

    $result.pick = Invoke-AddType 1
    $result.closed = Invoke-AddType 2 $j.ClosedGuid
    $result.dropped = Invoke-AddType 3 $j.DroppedGuid -Drop

    $dr = New-Object MouseRig+RECT
    [void][MouseRig]::GetWindowRect($root, [ref]$dr)
    Save-ScreenRegion (Join-Path $outDir 'external-filters.png') $dr.L $dr.T $dr.R ([Math]::Min($dr.B, [MouseRig]::GetSystemMetrics(1)))

    # OK, so the page applies and the filters are written to the ini.
    [void][MouseRig]::PostMessage($root, 0x0111, [IntPtr]1, [IntPtr]::Zero)   # WM_COMMAND, IDOK
    Start-Sleep -Milliseconds 1500
    $result.optionsClosed = -not [MouseRig]::IsWindow($root)
} catch {
    $result.error = $_.Exception.Message + ' @ ' + $_.InvocationInfo.PositionMessage
} finally {
    if ($proc) {
        try {
            Start-Sleep -Milliseconds 800
            foreach ($t in $dlgTitle, $j.DialogTitle) {
                $dlg = [MouseRig]::FindTop([uint32]$proc.Id, '', $t)
                if ($dlg -ne [IntPtr]::Zero) {
                    [void][MouseRig]::PostMessage($dlg, 0x0111, [IntPtr]2, [IntPtr]::Zero)   # WM_COMMAND, IDCANCEL
                    Start-Sleep -Milliseconds 800
                }
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
        $ini = Join-Path (Split-Path $j.Exe -Parent) 'mpc-hc64.ini'
        if (Test-Path $ini) { Copy-Item $ini (Join-Path $outDir 'mpc-hc64.ini') -Force }
    }
    $result.finished = (Get-Date).ToString('o')
    $result | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $outDir 'result.json')
}
