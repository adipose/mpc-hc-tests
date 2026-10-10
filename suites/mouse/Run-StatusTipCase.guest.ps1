# Runs on the target, in the console session. Plays a clip with Audio Info off in the status bar, so the bar
# shows the audio channel icon at its right end, captures the bar, then hovers the icon with real mouse
# input (SendInput) and records the tooltip that comes up; the host does the asserting.
# One JSON object goes to <OutDir>\result.json, with the captures beside it.
#
# The icon is painted by CPlayerStatusBar::OnPaint, not a control, so its tooltip is a rectangle tool on the
# bar (TTF_IDISHWND clear) that comctl only shows for a pointer really over that rectangle: posted moves
# do not bring it up. The tip text is what Audio Info would have added to the status text.
param([Parameter(Mandatory)] [string] $Job)

$ErrorActionPreference = 'Stop'
$j = Get-Content -Raw $Job | ConvertFrom-Json
$outDir = $j.OutDir
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory $outDir | Out-Null }
$result = [ordered]@{ started = (Get-Date).ToString('o'); error = $null }
$proc = $null

try {
    . (Join-Path $PSScriptRoot 'MouseInput.guest.ps1')

    $target = Start-TargetWindow -Exe $j.Exe -ArgumentLine $j.ArgumentLine -TopClass 'MediaPlayerClassicW'
    $proc = $target.Process
    $main = $target.Root
    $result.foreground = $target.Foreground

    # The bar is the time label's parent. Wait for the clip to be playing, which is when the icon is set.
    $time = [IntPtr]::Zero
    $deadline = (Get-Date).AddSeconds(15)
    while ($time -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 300
        $time = [MouseRig]::FindDescendant($main, [int]$j.TimeId)
    }
    if ($time -eq [IntPtr]::Zero) { throw 'the status bar time label was not found' }
    Start-Sleep -Milliseconds 2500
    $bar = [MouseRig]::GetParent($time)
    $br = New-Object MouseRig+RECT
    [void][MouseRig]::GetWindowRect($bar, [ref]$br)
    $result.bar = [ordered]@{ L = $br.L; T = $br.T; R = $br.R; B = $br.B }

    # Park the pointer over the video first, so the bar capture has no tooltip in it.
    Move-PointerGlide ([int](($br.L + $br.R) / 2)) ($br.T - 60)
    Start-Sleep -Milliseconds 600
    Save-ScreenRegion (Join-Path $outDir 'bar.png') $br.L $br.T $br.R $br.B

    # Hover the icon: the speaker sits at the bar's right end with the channel count after it.
    $hx = $br.R - [int]$j.HoverFromRight
    $hy = [int](($br.T + $br.B) / 2)
    Move-PointerGlide $hx $hy
    $tip = [IntPtr]::Zero
    $deadline = (Get-Date).AddSeconds(3)
    while ($tip -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 100
        $script:found = [IntPtr]::Zero
        $cb = [MouseRig+EnumProc] {
            param($hWnd, $lParam)
            $tipPid = [uint32]0
            [void][MouseRig]::GetWindowThreadProcessId($hWnd, [ref]$tipPid)
            if ($tipPid -eq [uint32]$proc.Id -and [MouseRig]::IsWindowVisible($hWnd) -and [MouseRig]::ClassOf($hWnd) -eq 'tooltips_class32') {
                $script:found = $hWnd
                return $false
            }
            return $true
        }
        [void][MouseRig]::EnumWindows($cb, [IntPtr]::Zero)
        $tip = $script:found
    }
    $p = Get-PointerPosition
    $result.hover = [ordered]@{ X = $hx; Y = $hy; pointerX = $p.X; pointerY = $p.Y }
    $result.tip = [ordered]@{ seen = ($tip -ne [IntPtr]::Zero); text = $null }
    $l = $br.L; $t = $br.T; $r = $br.R; $b = $br.B
    if ($tip -ne [IntPtr]::Zero) {
        Start-Sleep -Milliseconds 300
        $result.tip.text = Get-WindowTextOf $tip
        $tr = New-Object MouseRig+RECT
        [void][MouseRig]::GetWindowRect($tip, [ref]$tr)
        $result.tip.rect = [ordered]@{ L = $tr.L; T = $tr.T; R = $tr.R; B = $tr.B }
        $l = [Math]::Min($l, $tr.L); $t = [Math]::Min($t, $tr.T); $r = [Math]::Max($r, $tr.R); $b = [Math]::Max($b, $tr.B)
    }
    # The bar and the tooltip together, with a margin of video above for context.
    $l = [Math]::Max(0, [Math]::Min($l, $br.R - 420)); $t = [Math]::Max(0, $t - 8)
    Save-ScreenRegion (Join-Path $outDir 'hover.png') $l $t $r ([Math]::Min($b, [MouseRig]::GetSystemMetrics(1)))
} catch {
    $result.error = $_.Exception.Message + ' @ ' + $_.InvocationInfo.PositionMessage
} finally {
    if ($proc) {
        try {
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
