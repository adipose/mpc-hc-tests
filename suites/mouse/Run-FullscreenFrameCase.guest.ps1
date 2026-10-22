# Runs on the guest in the console session (interactive scheduled task). Records the screen with ffmpeg's
# gdigrab while the player is toggled in and out of fullscreen by real double-clicks on the video. The host
# looks in the recording for the Vista/7 basic frame (#4330); this script only records.
#
# The unfixed build: DWM switches its own frame off asynchronously when the caption style is removed for
# fullscreen, uxtheme's cached "DWM draws the frame" flag lags behind it, and on the way back to a window
# uxtheme paints the basic frame into the window. It sits under DWM's frame until the next fullscreen
# entry uncovers it for a frame or more, so every entry after the first shows it, at the window's old place.
param([Parameter(Mandatory)] [string] $Job)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'MouseInput.guest.ps1')
$j = Get-Content -Raw $Job | ConvertFrom-Json
$out = $j.OutDir
$result = [ordered]@{ error = $null; events = @(); screen = $null; window = $null; rounds = @() }
$sw = [Diagnostics.Stopwatch]::StartNew()
function Ev([string] $s) { $script:result.events += ('{0,6} {1}' -f [int]$sw.ElapsedMilliseconds, $s) }
function RectOf([IntPtr] $h) { $r = New-Object MouseRig+RECT; [void][MouseRig]::GetWindowRect($h, [ref]$r); @($r.L, $r.T, $r.R, $r.B) }
$ff = $null; $proc = $null
try {
    $result.screen = @([MouseRig]::GetSystemMetrics(0), [MouseRig]::GetSystemMetrics(1))
    $start = Start-TargetWindow -Exe $j.Exe -ArgumentLine "/new `"$($j.Clip)`"" -TopClass 'MediaPlayerClassicW'
    $proc = $start.Process; $main = $start.Root
    [void][MouseRig]::SetWindowPos($main, [IntPtr]::Zero, $j.Window.X, $j.Window.Y, $j.Window.W, $j.Window.H, 0x0004)
    Start-Sleep -Milliseconds 800
    $result.window = RectOf $main

    $rec = Join-Path $out 'rec.mkv'
    $seconds = [int](4 + $j.Rounds * ($j.DwellMs + 1800) / 1000 + 4)
    $ffArgs = "-hide_banner -loglevel error -f gdigrab -framerate $($j.Fps) -draw_mouse 1 -i desktop -t $seconds -c:v libx264 -preset ultrafast -qp 0 -pix_fmt yuv444p -y `"$rec`""
    $ff = Start-Process $j.Ffmpeg -ArgumentList $ffArgs -PassThru -WindowStyle Hidden -RedirectStandardError (Join-Path $out 'ffmpeg.err')
    Start-Sleep -Milliseconds 2000
    if ($ff.HasExited) { throw "the screen recorder stopped at once: $(Get-Content (Join-Path $out 'ffmpeg.err') -Raw)" }
    Ev 'recording'

    $cx = [int](($result.window[0] + $result.window[2]) / 2); $cy = [int](($result.window[1] + $result.window[3]) / 2)
    for ($round = 1; $round -le $j.Rounds; $round++) {
        Move-PointerGlide $cx $cy 6 15; Start-Sleep -Milliseconds 300
        Ev "to fullscreen $round"
        [void][MouseRig]::Click(); Start-Sleep -Milliseconds 60; [void][MouseRig]::Click()
        Start-Sleep -Milliseconds $j.DwellMs
        $full = RectOf $main
        Ev "to windowed $round"
        [void][MouseRig]::Click(); Start-Sleep -Milliseconds 60; [void][MouseRig]::Click()
        Start-Sleep -Milliseconds 1500
        $result.rounds += [pscustomobject]@{ round = $round; fullscreen = $full; windowed = (RectOf $main) }
    }
    Ev 'done'
    $ff.WaitForExit(($seconds + 10) * 1000) | Out-Null
} catch {
    $result.error = "$_ $($_.ScriptStackTrace)"
} finally {
    if ($ff -and -not $ff.HasExited) { $ff.Kill() }
    if ($proc -and -not $proc.HasExited) { [void][MouseRig]::PostMessage($proc.MainWindowHandle, 0x0010, [IntPtr]0, [IntPtr]0); $proc.WaitForExit(5000) | Out-Null; if (-not $proc.HasExited) { $proc.Kill() } }
    $result | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $out 'result.json')
}
