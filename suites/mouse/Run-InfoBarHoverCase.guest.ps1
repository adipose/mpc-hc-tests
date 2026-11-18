# Runs on the target, in the console session. Plays a chaptered clip with windowed auto-hide and the
# information bar on, parks the pointer on the video so the controls hide, lets playback cross a chapter
# mark, pauses, then moves the pointer to the bottom of the window with real input (SendInput) so auto-hide
# shows the controls again, and records the information bar's lines; the host does the asserting (#4385).
# One JSON object goes to <OutDir>\result.json, with a capture of the window beside it.
#
# The bar's labels have no ids: SetLine creates a caption static and a value static per line, in that
# order, so its children in z-order pair up. The paused position comes from the status bar's time label,
# which is kept up to date while the bar is hidden.
param([Parameter(Mandatory)] [string] $Job)

$ErrorActionPreference = 'Stop'
$j = Get-Content -Raw $Job | ConvertFrom-Json
$outDir = $j.OutDir
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory $outDir | Out-Null }
$result = [ordered]@{ started = (Get-Date).ToString('o'); error = $null }
$proc = $null

function Get-BarLines([IntPtr] $Bar) {
    $texts = [System.Collections.Generic.List[string]]::new()
    $cb = [MouseRig+EnumProc] {
        param($hWnd, $lParam)
        if ([MouseRig]::GetParent($hWnd) -eq $Bar) { $texts.Add((Get-WindowTextOf $hWnd)) }
        return $true
    }
    [void][MouseRig]::EnumChildWindows($Bar, $cb, [IntPtr]::Zero)
    $lines = @()
    for ($i = 0; $i + 1 -lt $texts.Count; $i += 2) { $lines += [ordered]@{ label = $texts[$i]; info = $texts[$i + 1] } }
    , $lines
}

try {
    . (Join-Path $PSScriptRoot 'MouseInput.guest.ps1')

    $target = Start-TargetWindow -Exe $j.Exe -ArgumentLine $j.ArgumentLine -TopClass 'MediaPlayerClassicW'
    $proc = $target.Process
    $main = $target.Root
    $wr = $target.Rect
    $result.foreground = $target.Foreground

    # The statistics bar is a CPlayerInfoBar too, with the same dialog id, so the information bar is the one
    # of the two holding a Chapter line (set at open for chaptered media, whichever build).
    $bar = [IntPtr]::Zero; $time = [IntPtr]::Zero
    $deadline = (Get-Date).AddSeconds(15)
    while (($bar -eq [IntPtr]::Zero -or $time -eq [IntPtr]::Zero) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 300
        $bars = [System.Collections.Generic.List[IntPtr]]::new()
        $cb = [MouseRig+EnumProc] { param($hWnd, $lParam); if ([MouseRig]::GetDlgCtrlID($hWnd) -eq [int]$j.InfoBarId) { $bars.Add($hWnd) }; return $true }
        [void][MouseRig]::EnumChildWindows($main, $cb, [IntPtr]::Zero)
        foreach ($b in $bars) { if (@(Get-BarLines $b) | Where-Object { $_.label -eq 'Chapter' }) { $bar = $b } }
        $time = [MouseRig]::FindDescendant($main, [int]$j.TimeId)
    }
    if ($bar -eq [IntPtr]::Zero) { throw 'the information bar (the bar with a Chapter line) was not found' }
    if ($time -eq [IntPtr]::Zero) { throw 'the status bar time label was not found' }

    # Park on the video, away from every edge, so auto-hide hides the controls.
    Move-PointerGlide ([int](($wr.L + $wr.R) / 2)) ([int]($wr.T + ($wr.B - $wr.T) / 3))
    $result.atOpen = [ordered]@{ time = (Get-WindowTextOf $time); lines = (Get-BarLines $bar) }

    # Wait, playing with the bar hidden, until the clip is past the second chapter mark.
    $pastMark = [double]$j.PauseAfterSec
    $deadline = (Get-Date).AddSeconds(30)
    $pos = -1
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 200
        $t = Get-WindowTextOf $time
        if ($t -match '^(?:(\d+):)?(\d+):(\d+)') { $pos = 3600 * [int]('0' + $Matches[1]) + 60 * [int]$Matches[2] + [int]$Matches[3] }
        if ($pos -ge $pastMark) { break }
    }
    $result.hiddenWhilePlaying = -not [MouseRig]::IsWindowVisible($bar)
    [void][MouseRig]::PostMessage($main, 0x0111, [IntPtr][int]$j.PauseId, [IntPtr]0)
    Start-Sleep -Milliseconds 1500
    $result.paused = [ordered]@{ time = (Get-WindowTextOf $time); barVisible = [MouseRig]::IsWindowVisible($bar) }

    # Bring the controls back the way a user does: the pointer to the bottom of the window.
    [void][MouseRig]::GetWindowRect($main, [ref]$wr)
    Move-PointerGlide ([int](($wr.L + $wr.R) / 2)) ($wr.B - 20) -Steps 12 -StepMs 25
    $deadline = (Get-Date).AddSeconds(4)
    while (-not [MouseRig]::IsWindowVisible($bar) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
    Start-Sleep -Milliseconds 800
    $p = Get-PointerPosition
    $result.shown = [ordered]@{
        barVisible = [MouseRig]::IsWindowVisible($bar); time = (Get-WindowTextOf $time); lines = (Get-BarLines $bar)
        pointerX = $p.X; pointerY = $p.Y
    }
    [void](Save-WindowShot (Join-Path $outDir 'shown.png') $main)
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
