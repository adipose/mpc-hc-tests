# Runs on the target, in the console session. Drives the player's main window, its docked panels and the
# playlist's inline edit with real mouse and keyboard input (SendInput), and records window state and
# screen captures; the host does the asserting. One JSON object goes to <OutDir>\result.json, with the
# captures beside it. One case per launch, named by the job file's Case.
#
# The cases come from issue #4279. Each records a series of states (Save-State): the edit, the list and the
# panels as seen from outside the player, the volume slider's position, focus and capture, and where the
# pointer was. What each case does:
#
#   edit-leave      the inline edit opened on row 0, the pointer moved off the panel onto the video, and
#                   left there past the auto-hide delay. Unfixed, auto-hide hid the panel and with it the
#                   edit (f9eb6ea4f6). Then Escape, and the panel must hide after all: auto-hide works.
#   edit-drag       the same, but a text selection is started in the edit with the button held, dragged
#                   out onto the video, held past the delay and released there. Fullscreen with
#                   -Fullscreen, where the panels auto-hide by the fullscreen rules instead.
#   edit-wheel      wheel notches over the open edit, then over the list below it. Unfixed, the first one
#                   ended the edit and every one changed the volume (2be9a5f164). Then the same notches over
#                   the video, which must change the volume in every build.
#   resize          the window's top-left corner dragged inwards far past the window's minimum size, with
#                   a fixed aspect ratio (LimitWindowProportions). Unfixed, once the minimum was reached the
#                   bottom edge crept downwards with every WM_SIZING (d03c9fa491).
#   playing-rename  the inline edit opened on row 0 while row 0 plays; the clip ends and row 1 starts
#                   playing with the edit still open. Unfixed, row 1 was drawn without its name until the
#                   edit closed (af6cd65bbd).
#   web-index       the web interface's setplaylistindex moves playback from row 0 to row 1. Unfixed, row 0
#                   kept its playing mark until something else repainted it (57555a7781). A forced redraw
#                   of the list afterwards is the reference.
#
# With -Panels the job names docked bars to record too (a zone case: the playlist and the Edit List editor
# docked side by side, where hiding one moves the other, e0a9c7b3f7).
param([Parameter(Mandatory)] [string] $Job)

$ErrorActionPreference = 'Stop'
$j = Get-Content -Raw $Job | ConvertFrom-Json
$outDir = $j.OutDir
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory $outDir | Out-Null }
$result = [ordered]@{ case = $j.Case; started = (Get-Date).ToString('o'); error = $null; notes = @(); states = @() }
$proc = $null
$main = [IntPtr]::Zero
$list = [IntPtr]::Zero
$sw = [Diagnostics.Stopwatch]::StartNew()
$stateN = 0

function T { [int]$sw.ElapsedMilliseconds }
function Note([string] $s) { $result.notes += ('{0,6} {1}' -f (T), $s) }
function RectOf([IntPtr] $h) { $r = New-Object MouseRig+RECT; [void][MouseRig]::GetWindowRect($h, [ref]$r); @{ L = $r.L; T = $r.T; R = $r.R; B = $r.B } }
function Rh($r) { @{ L = $r.L; T = $r.T; R = $r.R; B = $r.B } }

function Get-List {
    if ($script:list -eq [IntPtr]::Zero -or -not [MouseRig]::IsWindow($script:list)) { $script:list = [MouseRig]::FindDescendant($script:main, [int]$j.Ids.PlaylistList) }
    $script:list
}
# The open inline edit, or zero: LVM_GETEDITCONTROL answers for the label edit the list itself started.
function Get-Edit { $l = Get-List; if ($l -eq [IntPtr]::Zero) { return [IntPtr]::Zero }; [MouseRig]::SendMessage($l, 0x1018, [IntPtr]0, [IntPtr]0) }
# The volume slider is the player's only trackbar; TBM_GETPOS.
function Get-Volume { $tb = [MouseRig]::FindChildByClass($script:main, 'msctls_trackbar32'); if ($tb -eq [IntPtr]::Zero) { return -1 }; [MouseRig]::SendMessage($tb, 0x0400, [IntPtr]0, [IntPtr]0).ToInt32() }

# Everything the host needs to judge one moment, and unless -NoPng a capture of the main window.
function Save-State([string] $Tag, [switch] $NoPng, [int[]] $Items = @()) {
    $script:stateN++
    $l = Get-List; $e = Get-Edit
    $p = Get-PointerPosition
    $rec = [ordered]@{
        n = $script:stateN; tag = $Tag; t = (T); title = (Get-WindowTextOf $script:main)
        main = (RectOf $script:main); pointer = @{ X = $p.X; Y = $p.Y }; under = [MouseRig]::ClassAt($p.X, $p.Y)
        listVisible = ($l -ne [IntPtr]::Zero -and [MouseRig]::IsWindowVisible($l)); list = $(if ($l -ne [IntPtr]::Zero) { RectOf $l } else { $null })
        edit = [int64]$e; editVisible = ($e -ne [IntPtr]::Zero -and [MouseRig]::IsWindowVisible($e)); editRect = $(if ($e -ne [IntPtr]::Zero) { RectOf $e } else { $null })
        editText = $(if ($e -ne [IntPtr]::Zero) { Get-WindowTextOf $e } else { '' })
        focusClass = [MouseRig]::ClassOf([MouseRig]::FocusOf($script:main)); captureClass = [MouseRig]::ClassOf([MouseRig]::CaptureOf($script:main))
        foreground = ([MouseRig]::GetForegroundWindow() -eq $script:main)
        volume = (Get-Volume)
        selected = $(if ($l -ne [IntPtr]::Zero) { [MouseRig]::SendMessage($l, 0x100C, [IntPtr](-1), [IntPtr]2).ToInt32() } else { -1 })   # LVM_GETNEXTITEM, LVNI_SELECTED
        items = @(); panels = [ordered]@{}
    }
    if ($l -ne [IntPtr]::Zero) {
        foreach ($i in $Items) { $rec.items += @{ i = $i; bounds = (Rh ([MouseRig]::ListItemRect($l, $i, 0))); label = (Rh ([MouseRig]::ListItemRect($l, $i, 2))) } }
    }
    foreach ($k in @($j.Panels)) {
        if (-not $k) { continue }
        $h = [MouseRig]::FindDescendant($script:main, [int]$k.Id)
        $rec.panels[$k.Name] = @{ found = ($h -ne [IntPtr]::Zero); visible = ($h -ne [IntPtr]::Zero -and [MouseRig]::IsWindowVisible($h)); rect = $(if ($h -ne [IntPtr]::Zero) { RectOf $h } else { $null }) }
    }
    if (-not $NoPng) {
        $png = '{0:D2}-{1}.png' -f $script:stateN, $Tag
        $rec.shot = Save-WindowShot (Join-Path $outDir $png) $script:main
        $rec.png = $png
    }
    $result.states += $rec
    $rec
}

# Started with the files on the command line; ready once the title names the first one.
function Start-Player {
    $argLine = '/new ' + (($j.Files | ForEach-Object { '"' + $_ + '"' }) -join ' ')
    $script:proc = Start-Process -FilePath $j.Exe -ArgumentList $argLine -PassThru
    # A guest renders with WARP on four vCPUs and a playing player takes all of them otherwise.
    try { $script:proc.PriorityClass = 'BelowNormal' } catch {}
    $procId = [uint32]$script:proc.Id
    for ($i = 0; $i -lt 120 -and $script:main -eq [IntPtr]::Zero; $i++) { Start-Sleep -Milliseconds 250; $script:main = [MouseRig]::FindTop($procId, 'MediaPlayerClassicW', '') }
    if ($script:main -eq [IntPtr]::Zero) { throw 'no player window appeared' }
    $want = [IO.Path]::GetFileNameWithoutExtension($j.Files[0])
    $ok = $false
    for ($i = 0; $i -lt 100; $i++) { if ((Get-WindowTextOf $script:main) -like "*$want*") { $ok = $true; break }; Start-Sleep -Milliseconds 250 }
    Note "title '$(Get-WindowTextOf $script:main)' loaded=$ok"
    if (-not $ok) { throw "the first file never loaded (title '$(Get-WindowTextOf $script:main)')" }
    Start-Sleep -Milliseconds 1500
}

function Set-MainPlacement([int] $X, [int] $Y, [int] $W, [int] $H) {
    [void][MouseRig]::SetWindowPos($script:main, [IntPtr]::Zero, $X, $Y, $W, $H, 0x0004 -bor 0x0010)   # SWP_NOZORDER|SWP_NOACTIVATE
    Start-Sleep -Milliseconds 600
}

# A real click on the caption makes the player the foreground window the way a user would.
function Enter-Main {
    $mr = RectOf $script:main
    Move-PointerGlide ($mr.L + 200) ($mr.T + 14)
    Start-Sleep -Milliseconds 200
    [void][MouseRig]::Click()
    Start-Sleep -Milliseconds 500
    Note "foreground=$([MouseRig]::GetForegroundWindow() -eq $script:main)"
}

function Send-PlayerCommand([int] $Id) { [void][MouseRig]::PostMessage($script:main, 0x0111, [IntPtr]$Id, [IntPtr]0) }   # WM_COMMAND

# The main window's client area, in screen coordinates.
function Get-ClientScreenRect {
    $c = New-Object MouseRig+RECT; [void][MouseRig]::GetClientRect($script:main, [ref]$c)
    $a = New-Object MouseRig+POINT; [void][MouseRig]::ClientToScreen($script:main, [ref]$a)
    @{ L = $a.X; T = $a.Y; R = $a.X + $c.R; B = $a.Y + $c.B }
}

# A point on the video, away from every docked panel: the middle of the client area left of the playlist.
function Get-VideoPoint {
    $c = Get-ClientScreenRect
    $right = $c.R
    $l = Get-List
    if ($l -ne [IntPtr]::Zero -and [MouseRig]::IsWindowVisible($l)) {
        $left = $c.R
        foreach ($k in @($j.Panels)) {
            if (-not $k) { continue }
            $h = [MouseRig]::FindDescendant($script:main, [int]$k.Id)
            if ($h -ne [IntPtr]::Zero -and [MouseRig]::IsWindowVisible($h)) { $left = [Math]::Min($left, (RectOf $h).L) }
        }
        $lr = RectOf $l
        $left = [Math]::Min($left, $lr.L)
        if ($left -gt $c.L + 100) { $right = $left - 20 }
    }
    @{ X = [int](($c.L + $right) / 2) - 30; Y = [int](($c.T + $c.B) / 2) - 40 }
}
function Move-ToVideo { $v = Get-VideoPoint; Move-PointerGlide $v.X $v.Y 12 25 }

# The playlist shown. With auto-hide on, the pointer goes into the right-hand zone first, which is how a
# user brings an auto-hidden panel back.
function Show-Playlist {
    if ($j.AutoHide) {
        $c = Get-ClientScreenRect
        Move-PointerGlide ($c.R - 60) ([int](($c.T + $c.B) / 2)) 8 20
        Start-Sleep -Milliseconds 900
    }
    $l = Get-List
    if ($l -eq [IntPtr]::Zero -or -not [MouseRig]::IsWindowVisible($l)) {
        Note 'playlist not visible: posting ID_VIEW_PLAYLIST'
        Send-PlayerCommand ([int]$j.Ids.ViewPlaylist)
        Start-Sleep -Milliseconds 1200
        if ($j.AutoHide) { $c = Get-ClientScreenRect; Move-PointerGlide ($c.R - 70) ([int](($c.T + $c.B) / 2) + 10) 8 20; Start-Sleep -Milliseconds 900 }
    }
    $l = Get-List
    if ($l -eq [IntPtr]::Zero -or -not [MouseRig]::IsWindowVisible($l)) { throw 'the playlist could not be shown' }
}

# The inline edit opened the way a user opens it: a click on the row's name, and a second, slow one.
function Open-InlineEdit([int] $Item = 0) {
    Show-Playlist
    $l = Get-List
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $r = [MouseRig]::ListItemRect($l, $Item, 2)          # LVIR_LABEL
        if ($r.R -le $r.L) { $r = [MouseRig]::ListItemRect($l, $Item, 0) }
        # 30 px in clears the owner-drawn row number; each attempt aims a little further right, because a
        # list ignores a move to the point it last saw.
        $x = $r.L + 30 + 7 * $attempt; $y = [int](($r.T + $r.B) / 2)
        Note "item $Item label rect $($r.L),$($r.T),$($r.R),$($r.B); clicking $x,$y (attempt $attempt)"
        Move-PointerGlide $x $y 6 20
        Start-Sleep -Milliseconds 300
        [void][MouseRig]::Click()
        Start-Sleep -Milliseconds 1100
        [void][MouseRig]::Click()
        for ($k = 0; $k -lt 10; $k++) { Start-Sleep -Milliseconds 200; if ((Get-Edit) -ne [IntPtr]::Zero) { break } }
        if ((Get-Edit) -ne [IntPtr]::Zero) { Start-Sleep -Milliseconds 400; return }
        Start-Sleep -Milliseconds 800
    }
    throw 'the inline edit never opened'
}

$delay = [int]$j.Delay

try {
    . (Join-Path $PSScriptRoot 'MouseInput.guest.ps1')
    $result.screen = @{ W = [MouseRig]::GetSystemMetrics(0); H = [MouseRig]::GetSystemMetrics(1) }
    # Where a real wheel is delivered depends on this (2, the Windows 10 default: the window under the
    # pointer, not the focus); recorded so a wheel result can be read against it.
    try { $result.mouseWheelRouting = (Get-ItemProperty 'HKCU:\Control Panel\Desktop' -Name MouseWheelRouting -ErrorAction Stop).MouseWheelRouting } catch { $result.mouseWheelRouting = $null }

    Start-Player
    Set-MainPlacement ([int]$j.Window.X) ([int]$j.Window.Y) ([int]$j.Window.W) ([int]$j.Window.H)
    Enter-Main
    if ($j.ShowPlaylist) { Show-Playlist }
    foreach ($c in @($j.PostCommands)) { if ($c) { Send-PlayerCommand ([int]$c); Start-Sleep -Milliseconds 1200 } }
    if ($j.Fullscreen) {
        Send-PlayerCommand ([int]$j.Ids.Fullscreen); Start-Sleep -Milliseconds 3000
        $mr = RectOf $main
        Note "fullscreen main rect $($mr.L),$($mr.T),$($mr.R),$($mr.B)"
    }

    switch ($j.Case) {
        'edit-leave' {
            Move-ToVideo; Start-Sleep -Milliseconds ($delay + 1500)
            [void](Save-State 'start')
            Open-InlineEdit 0
            [void](Save-State 'editOpen')
            Move-ToVideo
            [void](Save-State 'leftPanel' -NoPng)
            Start-Sleep -Milliseconds ($delay + 2500)
            [void](Save-State 'afterDelay')
            [void][MouseRig]::KeyPress(0x1B)   # Escape: cancel the rename
            Start-Sleep -Milliseconds 400
            [void](Save-State 'afterEsc' -NoPng)
            Start-Sleep -Milliseconds ($delay + 2500)
            [void](Save-State 'afterEscDelay')
        }
        'edit-drag' {
            Move-ToVideo; Start-Sleep -Milliseconds ($delay + 1500)
            Open-InlineEdit 0
            $s = Save-State 'editOpen'
            $er = $s.editRect
            $ey = [int](($er.T + $er.B) / 2)
            Move-PointerGlide ($er.L + 5) $ey 4 20
            Start-Sleep -Milliseconds 300
            [void][MouseRig]::ButtonDown()
            Start-Sleep -Milliseconds 150
            Move-PointerGlide ([int](($er.L + $er.R) / 2)) $ey 6 30
            [void](Save-State 'selecting' -NoPng)
            Move-ToVideo
            [void](Save-State 'heldOutside')
            Start-Sleep -Milliseconds ($delay + 2500)
            [void](Save-State 'heldOutsideDelay')
            [void][MouseRig]::ButtonUp()
            Start-Sleep -Milliseconds 300
            [void](Save-State 'released')
            Start-Sleep -Milliseconds ($delay + 2500)
            [void](Save-State 'afterReleaseDelay')
            [void][MouseRig]::KeyPress(0x1B)
            Start-Sleep -Milliseconds ($delay + 2500)
            [void](Save-State 'afterEscDelay' -NoPng)
        }
        'edit-wheel' {
            Move-ToVideo; Start-Sleep -Milliseconds 800
            Open-InlineEdit 0
            $s = Save-State 'editOpen'
            $er = $s.editRect
            Move-PointerGlide ([int](($er.L + $er.R) / 2) - 8) ([int](($er.T + $er.B) / 2)) 4 20
            Start-Sleep -Milliseconds 300
            [void](Save-State 'overEdit' -NoPng)
            for ($k = 0; $k -lt 3; $k++) { [void][MouseRig]::Wheel(-120); Start-Sleep -Milliseconds 400; [void](Save-State "wheelEdit$k" -NoPng) }
            Start-Sleep -Milliseconds 600
            $s = Save-State 'afterWheelEdit'
            if ($s.edit -ne 0) {
                # The empty part of the list below the rows.
                $lr = $s.list
                Move-PointerGlide ([int](($lr.L + $lr.R) / 2)) ([int]($lr.B - 30)) 6 20
                Start-Sleep -Milliseconds 300
                [void](Save-State 'overList' -NoPng)
                for ($k = 0; $k -lt 3; $k++) { [void][MouseRig]::Wheel(-120); Start-Sleep -Milliseconds 400; [void](Save-State "wheelList$k" -NoPng) }
                Start-Sleep -Milliseconds 400
                [void](Save-State 'afterWheelList')
            }
            [void][MouseRig]::KeyPress(0x1B); Start-Sleep -Milliseconds 500
            # The control: the same notches over the video change the volume in every build.
            Move-ToVideo; Start-Sleep -Milliseconds 300
            [void](Save-State 'beforeWheelVideo' -NoPng)
            for ($k = 0; $k -lt 2; $k++) { [void][MouseRig]::Wheel(-120); Start-Sleep -Milliseconds 400; [void](Save-State "wheelVideo$k" -NoPng) }
            Start-Sleep -Milliseconds 800
            [void](Save-State 'afterWheelVideo' -NoPng)
        }
        'resize' {
            Move-ToVideo; Start-Sleep -Milliseconds 2000
            $s = Save-State 'start'
            $mr = $s.main
            # The sizing corner, found by asking the window rather than by guessing its border width.
            $hx = 0; $hy = 0; $found = $false
            foreach ($o in 2, 4, 6, 1, 3, 5, 8) {
                $lp = [IntPtr](((($mr.T + $o) -band 0xFFFF) -shl 16) -bor (($mr.L + $o) -band 0xFFFF))
                $ht = [MouseRig]::SendMessage($main, 0x0084, [IntPtr]0, $lp).ToInt32()   # WM_NCHITTEST
                if ($ht -eq 13) { $hx = $mr.L + $o; $hy = $mr.T + $o; $found = $true; break }   # HTTOPLEFT
            }
            if (-not $found) { throw 'no HTTOPLEFT point found at the window corner' }
            Note "HTTOPLEFT at $hx,$hy"
            Move-PointerGlide $hx $hy 6 20
            Start-Sleep -Milliseconds 400
            [void][MouseRig]::ButtonDown()
            Start-Sleep -Milliseconds 300
            $rects = New-Object System.Collections.ArrayList
            $step = [int]$j.Step; $n = [int]$j.Steps
            for ($i = 1; $i -le $n; $i++) {
                [void][MouseRig]::MoveTo($hx + $step * $i, $hy + $step * $i)
                Start-Sleep -Milliseconds 35
                $r = RectOf $main
                $p = Get-PointerPosition
                [void]$rects.Add(@{ i = $i; px = $p.X; py = $p.Y; L = $r.L; T = $r.T; R = $r.R; B = $r.B })
            }
            [void](Save-State 'endHeld')
            [void][MouseRig]::ButtonUp()
            Start-Sleep -Milliseconds 600
            [void](Save-State 'released')
            $result.rects = $rects
        }
        'playing-rename' {
            Move-ToVideo; Start-Sleep -Milliseconds 300
            Open-InlineEdit 0
            [void](Save-State 'editOpen' -Items 0, 1)
            $want = [IO.Path]::GetFileNameWithoutExtension($j.Files[1])
            for ($i = 0; $i -lt 120; $i++) { if ((Get-WindowTextOf $main) -like "*$want*") { break }; Start-Sleep -Milliseconds 250 }
            Note "title now '$(Get-WindowTextOf $main)'"
            Start-Sleep -Milliseconds 2000
            [void](Save-State 'switchedWithEdit' -Items 0, 1)
            [void][MouseRig]::KeyPress(0x1B)
            Start-Sleep -Milliseconds 800
            [void](Save-State 'afterEsc' -Items 0, 1)
        }
        'web-index' {
            Move-ToVideo; Start-Sleep -Milliseconds 1000
            [void](Save-State 'before' -Items 0, 1)
            $u = "http://127.0.0.1:$($j.WebPort)/command.html?wm_command=-3&index=1"   # CMD_SETPLAYLISTINDEX
            try { $resp = Invoke-WebRequest -UseBasicParsing -Uri $u -TimeoutSec 10; Note "web $($resp.StatusCode)"; $result.webStatus = [int]$resp.StatusCode } catch { Note "web request failed: $($_.Exception.Message)" }
            $want = [IO.Path]::GetFileNameWithoutExtension($j.Files[1])
            for ($i = 0; $i -lt 60; $i++) { if ((Get-WindowTextOf $main) -like "*$want*") { break }; Start-Sleep -Milliseconds 250 }
            Note "title now '$(Get-WindowTextOf $main)'"
            Start-Sleep -Milliseconds 2500
            [void](Save-State 'afterWeb' -Items 0, 1)
            $l = Get-List
            [void][MouseRig]::RedrawWindow($l, [IntPtr]::Zero, [IntPtr]::Zero, 0x1 -bor 0x4 -bor 0x80 -bor 0x100)   # INVALIDATE|ERASE|ALLCHILDREN|UPDATENOW
            Start-Sleep -Milliseconds 800
            [void](Save-State 'afterRedraw' -Items 0, 1)
        }
        default { throw "unknown case $($j.Case)" }
    }
} catch {
    $result.error = $_.Exception.Message + ' @ ' + $_.InvocationInfo.PositionMessage
    try { if ($main -ne [IntPtr]::Zero) { [void](Save-State 'error') } } catch {}
} finally {
    if ($proc) {
        # Closed, not killed, so the player's own ini is written; forced only if it will not go.
        if ($main -ne [IntPtr]::Zero) { [void][MouseRig]::PostMessage($main, 0x0010, [IntPtr]0, [IntPtr]0) }   # WM_CLOSE
        if (-not $proc.WaitForExit(10000)) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue; $result.killedOnClose = $true }
    }
    $result.finished = (Get-Date).ToString('o')
    $result | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $outDir 'result.json')
}
