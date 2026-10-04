# Runs on the target, in the console session. Drives drop-down-list combo boxes with real mouse input and
# records what happened; the host does the asserting. One JSON object goes to <OutDir>\result.json, with the
# screen captures beside it.
#
# For each combo and each delay: rest the pointer on the combo, click it open, wait the delay, move onto a
# list row, record ("hover"); move back onto the combo, record ("back"); click to close without picking,
# record ("closed"). With Pick set, each combo then gets one more round where the row is clicked.
param([Parameter(Mandatory)] [string] $Job)

$ErrorActionPreference = 'Stop'
$j = Get-Content -Raw $Job | ConvertFrom-Json
$outDir = $j.OutDir
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory $outDir | Out-Null }
$result = [ordered]@{ started = (Get-Date).ToString('o'); error = $null; combos = @(); records = @() }
$proc = $null

try {
    . (Join-Path $PSScriptRoot 'MouseInput.guest.ps1')
    $target = Start-TargetWindow -Exe $j.Exe -ArgumentLine $j.ArgumentLine -TopClass $j.TopClass -PostCommand ([int]$j.PostCommand) -DialogTitle $j.DialogTitle
    $proc = $target.Process
    $root = $target.Root
    $wr = $target.Rect
    $result.foreground = $target.Foreground
    $result.screen = @{ W = [MouseRig]::GetSystemMetrics(0); H = [MouseRig]::GetSystemMetrics(1) }
    # Every capture is this one region, so the host can cut any control out of any capture by its rectangle.
    $shot = @{ L = $wr.L; T = $wr.T; R = $wr.R; B = [Math]::Min($wr.B + 200, [MouseRig]::GetSystemMetrics(1)) }
    $result.shot = $shot

    $combos = New-Object System.Collections.ArrayList
    $records = New-Object System.Collections.ArrayList
    $n = 0
    foreach ($id in $j.ComboIds) {
        $combo = [MouseRig]::FindChild($root, [int]$id)
        if ($combo -eq [IntPtr]::Zero) { [void]$combos.Add(@{ id = [int]$id; found = $false }); continue }
        $info = New-Object MouseRig+COMBOBOXINFO
        $info.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($info)
        [void][MouseRig]::GetComboBoxInfo($combo, [ref]$info)
        $list = $info.hwndList
        $cr = New-Object MouseRig+RECT
        [void][MouseRig]::GetWindowRect($combo, [ref]$cr)
        $ih = [MouseRig]::SendMessage($combo, 0x0154, [IntPtr]0, [IntPtr]0).ToInt32()       # CB_GETITEMHEIGHT
        $count = [MouseRig]::SendMessage($combo, 0x0146, [IntPtr]0, [IntPtr]0).ToInt32()    # CB_GETCOUNT
        $orig = [MouseRig]::SendMessage($combo, 0x0147, [IntPtr]0, [IntPtr]0).ToInt32()     # CB_GETCURSEL
        [void]$combos.Add(@{
            id = [int]$id; found = $true; items = $count; itemHeight = $ih; selected = $orig; text = (Get-WindowTextOf $combo)
            rect = @{ L = $cr.L; T = $cr.T; R = $cr.R; B = $cr.B }
            # The drop-down button, in screen coordinates: the face's text lies to the left of it.
            button = @{ L = $cr.L + $info.rcButton.L; T = $cr.T + $info.rcButton.T; R = $cr.L + $info.rcButton.R; B = $cr.T + $info.rcButton.B }
        })
        $faceX = [int](($cr.L + $cr.R) / 2); $faceY = [int](($cr.T + $cr.B) / 2)

        # A short list opens from its first item; a long one scrolls the selected item to the top. Either way
        # the rows to hover are the ones that are not the selected item.
        $rows = @(1, 2, 3 | Where-Object { $_ -lt $count })
        if ($count -le 8) { $rows = @(0..([Math]::Min($count, 4) - 1) | Where-Object { $_ -ne $orig }) }
        if (-not $rows) { continue }

        function Add-Record {
            param([string] $Run, [string] $State)
            $capH = [MouseRig]::CaptureOf($combo)
            $cap = 'other'
            if ($capH -eq [IntPtr]::Zero) { $cap = 'none' } elseif ($capH -eq $list) { $cap = 'list' } elseif ($capH -eq $combo) { $cap = 'combo' }
            $p = Get-PointerPosition
            $png = '{0}-{1}-{2}.png' -f $id, $Run, $State
            Save-ScreenRegion (Join-Path $outDir $png) $shot.L $shot.T $shot.R $shot.B
            [void]$records.Add(@{
                combo = [int]$id; run = $Run; state = $State; png = $png
                sel = [MouseRig]::SendMessage($combo, 0x0147, [IntPtr]0, [IntPtr]0).ToInt32()
                text = (Get-WindowTextOf $combo)
                listOpen = [MouseRig]::IsWindowVisible($list); capture = $cap
                topIndex = [MouseRig]::SendMessage($list, 0x018E, [IntPtr]0, [IntPtr]0).ToInt32()   # LB_GETTOPINDEX
                pointerX = $p.X; pointerY = $p.Y
            })
        }
        function Reset-Combo {
            if ([MouseRig]::IsWindowVisible($list)) { [void][MouseRig]::SendMessage($combo, 0x014F, [IntPtr]0, [IntPtr]0) }   # CB_SHOWDROPDOWN off
            if ([MouseRig]::SendMessage($combo, 0x0147, [IntPtr]0, [IntPtr]0).ToInt32() -ne $orig) {
                [void][MouseRig]::SendMessage($combo, 0x014E, [IntPtr]$orig, [IntPtr]0)                                        # CB_SETCURSEL
            }
            # Rest the pointer off the combo so the next round starts clean.
            Move-PointerGlide ($wr.L + 120) ($wr.T + 12)
            Start-Sleep -Milliseconds 500
        }

        foreach ($delay in $j.DelaysMs) {
            $n++
            $run = "d$delay"
            # A list ignores a move to the point it last saw, so hover somewhere new every round.
            $row = $rows[$n % $rows.Count]
            $hx = $cr.L + 24 + 11 * ($n % 5)
            $hy = $cr.B + 2 + $row * $ih + [int]($ih / 2)

            Move-PointerGlide $faceX $faceY
            Start-Sleep -Milliseconds 300
            Add-Record $run 'start'
            if ([int]$delay -eq 0) {
                [void][MouseRig]::ClickThenMove($hx, $hy)
            } else {
                [void][MouseRig]::Click()
                Start-Sleep -Milliseconds ([int]$delay)
                Move-PointerGlide $hx $hy 4 8
            }
            Start-Sleep -Milliseconds 500
            Add-Record $run 'hover'
            Move-PointerGlide $faceX $faceY
            Start-Sleep -Milliseconds 400
            Add-Record $run 'back'
            [void][MouseRig]::Click()
            Start-Sleep -Milliseconds 700
            Add-Record $run 'closed'
            Reset-Combo
        }

        if ($j.Pick) {
            $n++
            $row = $rows[$n % $rows.Count]
            $hx = $cr.L + 24 + 11 * ($n % 5)
            $hy = $cr.B + 2 + $row * $ih + [int]($ih / 2)
            Move-PointerGlide $faceX $faceY
            Start-Sleep -Milliseconds 300
            [void][MouseRig]::Click()
            Start-Sleep -Milliseconds 700
            Move-PointerGlide $hx $hy 4 8
            Start-Sleep -Milliseconds 400
            Add-Record 'pick' 'hover'
            [void][MouseRig]::Click()
            Start-Sleep -Milliseconds 700
            Add-Record 'pick' 'closed'
            Reset-Combo
        }
    }
    $result.combos = $combos
    $result.records = $records
} catch {
    $result.error = $_.Exception.Message + ' @ ' + $_.InvocationInfo.PositionMessage
} finally {
    if ($proc) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    $result.finished = (Get-Date).ToString('o')
    $result | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $outDir 'result.json')
}
