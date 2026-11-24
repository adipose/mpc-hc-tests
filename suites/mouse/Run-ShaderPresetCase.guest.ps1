# Runs on the target, in the console session. Opens the player's Options dialog at the Shaders page, with
# presets alpha, bravo and delta seeded in the ini, and retypes a selected preset's name in the presets
# combo with real input (SendInput) before pressing Save or Delete; the host does the asserting. One JSON
# object goes to <OutDir>\result.json, with a screen capture of the dialog beside it.
#
# Ledger 129: the presets box is a CBS_DROPDOWN combo, and Load, Save and Delete went by GetCurSel()
# while the box shows the edit text. The two can disagree. Typing with the list closed is not the way:
# the combo clears its own selection on every edit change there (measured, curSel -1 after typing on
# develop), and the page reselects on an exact match. The way is typing with the list dropped and then
# clicking away. Closing the list puts the item the typing moved to into the edit (b -> bravo), puts the
# selection back on the item selected before the list dropped (alpha), and sends no CBN_EDITCHANGE. So
# Delete removed alpha while the box showed bravo. Fixed, the page looks the preset up from the edit
# text, so Delete removes bravo.
#
# Four steps, each starting from alpha selected:
#   save       list closed, alpha retyped as charlie, Save clicked: charlie added, alpha kept.
#   delnew     list closed, alpha retyped as zulu: Delete disabled, nothing removed.
#   deldrop    list dropped with F4, b typed, then a click on Delete: the first click only closes the
#              list (recorded), the second deletes. Whatever the box showed must go, alpha must stay.
#              Unfixed, alpha goes.
#   delexist   list closed, alpha retyped as delta, Delete clicked: delta goes, alpha stays.
# save, delnew and delexist pass on develop as well; they hold the fix to what already worked.
#
# Selecting alpha is CB_SETCURSEL rather than a pick from the open list: the page has no selection handler,
# so the page is in the same state either way, and the retyping that matters is real keys.
param([Parameter(Mandatory)] [string] $Job)

$ErrorActionPreference = 'Stop'
$j = Get-Content -Raw $Job | ConvertFrom-Json
$outDir = $j.OutDir
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory $outDir | Out-Null }
$result = [ordered]@{ started = (Get-Date).ToString('o'); error = $null }
$proc = $null

try {
    . (Join-Path $PSScriptRoot 'MouseInput.guest.ps1')

    $target = Start-TargetWindow -Exe $j.Exe -TopClass 'MediaPlayerClassicW' -PostCommand ([int]$j.PostCommand) -DialogTitle $j.DialogTitle
    $proc = $target.Process
    $root = $target.Root            # the Options dialog, opened at the Shaders page by LastUsedPage
    $result.foreground = $target.Foreground

    $combo = [IntPtr]::Zero
    $deadline = (Get-Date).AddSeconds(15)
    while ($combo -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 300
        $combo = [MouseRig]::FindChild($root, [int]$j.ComboId)
    }
    if ($combo -eq [IntPtr]::Zero) { throw 'the presets combo was not found on the Shaders page' }
    $info = New-Object MouseRig+COMBOBOXINFO
    $info.cbSize = [Runtime.InteropServices.Marshal]::SizeOf([type][MouseRig+COMBOBOXINFO])
    if (-not [MouseRig]::GetComboBoxInfo($combo, [ref]$info) -or $info.hwndItem -eq [IntPtr]::Zero) { throw 'the presets combo has no edit control (not CBS_DROPDOWN?)' }
    $edit = $info.hwndItem
    $saveBtn = [MouseRig]::FindChild($root, [int]$j.SaveId)
    $deleteBtn = [MouseRig]::FindChild($root, [int]$j.DeleteId)
    if ($saveBtn -eq [IntPtr]::Zero -or $deleteBtn -eq [IntPtr]::Zero) { throw 'the Save or Delete preset button was not found' }

    # CB_GETCOUNT / CB_GETLBTEXT: user32 marshals the text of a combo's list across processes.
    function Get-Presets {
        $n = [MouseRig]::SendMessage($combo, 0x0146, [IntPtr]::Zero, [IntPtr]::Zero).ToInt32()
        $names = @()
        for ($i = 0; $i -lt $n; $i++) {
            $sb = New-Object System.Text.StringBuilder 512
            [void][MouseRig]::SendMessageW($combo, 0x0148, [IntPtr]$i, $sb)
            $names += $sb.ToString()
        }
        , $names
    }
    function Get-CurSel { [MouseRig]::SendMessage($combo, 0x0147, [IntPtr]::Zero, [IntPtr]::Zero).ToInt32() }
    function Click-Center {
        param([IntPtr] $Hwnd, [int] $FromRight = -1)
        $r = New-Object MouseRig+RECT
        [void][MouseRig]::GetWindowRect($Hwnd, [ref]$r)
        $x = if ($FromRight -ge 0) { $r.R - $FromRight } else { [int](($r.L + $r.R) / 2) }
        Move-PointerGlide $x ([int](($r.T + $r.B) / 2))
        [void][MouseRig]::Click()
    }
    $result.presetsAtStart = Get-Presets

    function Invoke-Retype {
        param([string] $NewName, [IntPtr] $Button, [switch] $Drop)
        $step = [ordered]@{}
        $names = Get-Presets
        $ai = [array]::IndexOf($names, 'alpha')
        $step.alphaAtStart = ($ai -ge 0)
        if ($ai -lt 0) { $step.presetsAfter = $names; return $step }
        [void][MouseRig]::SendMessage($combo, 0x014E, [IntPtr]$ai, [IntPtr]::Zero)   # CB_SETCURSEL
        Start-Sleep -Milliseconds 300
        $step.selectedText = Get-WindowTextOf $edit
        # A real click near the right end of the edit puts the caret after the text; End makes sure.
        Click-Center $edit 6
        Start-Sleep -Milliseconds 300
        $step.focusIsEdit = ([MouseRig]::FocusOf($edit) -eq $edit)
        if ($Drop) {
            [void][MouseRig]::KeyPress(0x73)   # VK_F4 drops the list, the focus staying in the edit
            Start-Sleep -Milliseconds 400
        }
        $step.dropped = ([MouseRig]::SendMessage($combo, 0x0157, [IntPtr]::Zero, [IntPtr]::Zero) -ne [IntPtr]::Zero)   # CB_GETDROPPEDSTATE
        [void][MouseRig]::KeyPress(0x23)   # VK_END
        foreach ($i in 1..($step.selectedText.Length + 2)) { [void][MouseRig]::KeyPress(0x08); Start-Sleep -Milliseconds 40 }   # VK_BACK
        foreach ($ch in $NewName.ToUpperInvariant().ToCharArray()) { [void][MouseRig]::KeyPress([uint16][char]$ch); Start-Sleep -Milliseconds 60 }
        Start-Sleep -Milliseconds 500      # the buttons' enabled state follows on the page's idle update
        $step.typed = Get-WindowTextOf $edit
        $step.curSelAfterTyping = Get-CurSel
        $step.droppedAfterTyping = ([MouseRig]::SendMessage($combo, 0x0157, [IntPtr]::Zero, [IntPtr]::Zero) -ne [IntPtr]::Zero)
        if ($step.droppedAfterTyping) {
            # A click outside a dropped list closes it; whether it also reaches the button is recorded
            # rather than assumed, and the button is clicked again only if the first did nothing.
            $before = (Get-Presets) -join ','
            Click-Center $Button
            Start-Sleep -Milliseconds 600
            $step.droppedAfterFirstClick = ([MouseRig]::SendMessage($combo, 0x0157, [IntPtr]::Zero, [IntPtr]::Zero) -ne [IntPtr]::Zero)
            $step.textAfterClose = Get-WindowTextOf $edit
            $step.curSelAfterClose = Get-CurSel
            $step.firstClickActed = ((Get-Presets) -join ',') -ne $before
        }
        $step.buttonEnabled = [MouseRig]::IsWindowEnabled($Button)
        if (-not $step.droppedAfterTyping -or -not $step.firstClickActed) {
            Click-Center $Button
            Start-Sleep -Milliseconds 600
        }
        $step.presetsAfter = Get-Presets
        $step.textAfter = Get-WindowTextOf $edit
        $step.dialogOpen = ([MouseRig]::FindTop([uint32]$proc.Id, '', $j.DialogTitle) -ne [IntPtr]::Zero)
        $step
    }

    $result.save = Invoke-Retype 'charlie' $saveBtn
    $result.delnew = Invoke-Retype 'zulu' $deleteBtn
    $result.deldrop = Invoke-Retype 'b' $deleteBtn -Drop
    $result.delexist = Invoke-Retype 'delta' $deleteBtn

    $dr = New-Object MouseRig+RECT
    [void][MouseRig]::GetWindowRect($root, [ref]$dr)
    Save-ScreenRegion (Join-Path $outDir 'shader-presets.png') $dr.L $dr.T $dr.R ([Math]::Min($dr.B, [MouseRig]::GetSystemMetrics(1)))

    # Cancel, so nothing the page holds is saved.
    [void][MouseRig]::PostMessage($root, 0x0111, [IntPtr]2, [IntPtr]::Zero)   # WM_COMMAND, IDCANCEL
} catch {
    $result.error = $_.Exception.Message + ' @ ' + $_.InvocationInfo.PositionMessage
} finally {
    if ($proc) {
        try {
            Start-Sleep -Milliseconds 800
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
    $result.finished = (Get-Date).ToString('o')
    $result | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $outDir 'result.json')
}
