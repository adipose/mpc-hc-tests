# Runs on the target, in the console session. The player under a Windows contrast theme; the host does the
# asserting. One JSON object goes to <OutDir>\result.json, with a capture of each surface beside it.
#
# #4375. The playlist, the Edit List editor and Organize Favorites draw their own rows. With the theme off
# their text and selection were fixed colours while their background came from COLOR_WINDOW, which a black
# contrast theme makes black: black text on black. #4256 turned the theme off under a contrast theme, so
# everyone took that path. The player now forces the modern dark theme while a contrast theme is on, whatever
# the settings say, and the user's own theme comes back when contrast goes off (the Live variants).
#
# Each variant is its own player launch from a fresh portable ini (the job gives the ini text and the scheme;
# an empty scheme is the control, contrast off). The rows of the three lists are recorded for the host to
# judge, and the rest of what the theme draws is captured to look at: the main window, the two kinds of menu
# and the Options pages. Those shots are evidence for a person, not assertions.
#
# The contrast theme belongs to the console session, so it is set here and not from the host, and it is
# turned off again in the finally. Nobody else is on the guest: never run this on the host's desktop.
param([Parameter(Mandatory)] [string] $Job)

$ErrorActionPreference = 'Stop'
$j = Get-Content -Raw $Job | ConvertFrom-Json
$outDir = $j.OutDir
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory $outDir | Out-Null }
$result = [ordered]@{ started = (Get-Date).ToString('o'); error = $null; variants = [ordered]@{} }
$result.osBuild = [Environment]::OSVersion.Version.Build
$script:proc = $null

try {
    . (Join-Path $PSScriptRoot 'MouseInput.guest.ps1')

    Add-Type @'
using System;
using System.Runtime.InteropServices;
public class HcRig {
  [StructLayout(LayoutKind.Sequential)] public struct HIGHCONTRASTW { public uint cbSize; public uint dwFlags; public IntPtr scheme; }
  [DllImport("user32.dll", SetLastError=true)] static extern bool SystemParametersInfoW(uint action, uint param, ref HIGHCONTRASTW hc, uint winIni);
  [DllImport("user32.dll")] public static extern uint GetSysColor(int index);
  public static bool IsOn() {
    HIGHCONTRASTW hc = new HIGHCONTRASTW(); hc.cbSize = (uint)Marshal.SizeOf(hc);
    return SystemParametersInfoW(0x0042, hc.cbSize, ref hc, 0) && (hc.dwFlags & 1) != 0;        // SPI_GETHIGHCONTRAST, HCF_HIGHCONTRASTON
  }
  public static bool Set(bool on, string scheme) {
    HIGHCONTRASTW hc = new HIGHCONTRASTW(); hc.cbSize = (uint)Marshal.SizeOf(hc);
    SystemParametersInfoW(0x0042, hc.cbSize, ref hc, 0);
    hc.dwFlags = on ? (hc.dwFlags | 1) : (hc.dwFlags & ~1u);
    hc.scheme = on ? Marshal.StringToHGlobalUni(scheme) : IntPtr.Zero;
    return SystemParametersInfoW(0x0043, hc.cbSize, ref hc, 3);                                 // SPI_SETHIGHCONTRAST, SPIF_UPDATEINIFILE|SPIF_SENDCHANGE
  }
}
'@

    function Get-SysColours {
        $o = [ordered]@{}
        foreach ($p in @(@('window', 5), @('windowText', 8), @('highlight', 13), @('highlightText', 14))) {
            $c = [HcRig]::GetSysColor($p[1])
            $o[$p[0]] = @(($c -band 255), (($c -shr 8) -band 255), (($c -shr 16) -band 255))
        }
        $o
    }

    # Windows takes seconds to finish a switch, and answers before it has. The colours moving is the proof.
    function Set-Contrast {
        param([string] $Scheme)
        $want = [bool]$Scheme
        $before = (Get-SysColours).window -join ','
        $current = if ($script:scheme) { $script:scheme } else { '' }
        if ($current -eq $Scheme -and [HcRig]::IsOn() -eq $want) { return }
        [void][HcRig]::Set($want, $Scheme)
        $deadline = (Get-Date).AddSeconds(30)
        while ((Get-Date) -lt $deadline -and ((Get-SysColours).window -join ',') -eq $before) { Start-Sleep -Milliseconds 500 }
        Start-Sleep -Seconds 3
        $script:scheme = $Scheme
    }

    # A list's rows and client area in screen coordinates, for the host to cut out of a capture.
    function Read-List {
        param([IntPtr] $List, [int] $Rows)
        $o = [ordered]@{ found = ($List -ne [IntPtr]::Zero); rows = @() }
        if (-not $o.found) { return $o }
        $o.count = [MouseRig]::SendMessage($List, 0x1004, [IntPtr]::Zero, [IntPtr]::Zero).ToInt32()      # LVM_GETITEMCOUNT
        for ($i = 0; $i -lt [Math]::Min($Rows, $o.count); $i++) {
            $r = [MouseRig]::ListItemRect($List, $i, 0)
            $o.rows += @{ L = $r.L; T = $r.T; R = $r.R; B = $r.B }
        }
        if ($o.count -gt 0) { $o.lastRowBottom = ([MouseRig]::ListItemRect($List, $o.count - 1, 0)).B }
        $cr = New-Object MouseRig+RECT
        [void][MouseRig]::GetClientRect($List, [ref]$cr)
        $p = New-Object MouseRig+POINT
        [void][MouseRig]::ClientToScreen($List, [ref]$p)
        $o.client = @{ L = $p.X; T = $p.Y; R = $p.X + $cr.R; B = $p.Y + $cr.B }
        $o
    }

    function Send-Command {
        param([IntPtr] $Hwnd, [int] $Id)
        [void][MouseRig]::PostMessage($Hwnd, 0x0111, [IntPtr]$Id, [IntPtr]::Zero)                         # WM_COMMAND
    }

    function Save-Screen {
        param([string] $Name)
        Save-ScreenRegion (Join-Path $outDir $Name) 0 0 ([MouseRig]::GetSystemMetrics(0)) ([MouseRig]::GetSystemMetrics(1))
    }

    # Waits for a list to exist: a posted command does nothing until the player is loaded, so it is sent again.
    function Wait-List {
        param([IntPtr] $Root, [int] $Id, [int] $Command = 0)
        for ($i = 0; $i -lt 20; $i++) {
            $h = [MouseRig]::FindChild($Root, $Id)
            if ($h -ne [IntPtr]::Zero) { return $h }
            if ($Command -and ($i % 4) -eq 0) { Send-Command $Root $Command }
            Start-Sleep -Milliseconds 500
        }
        [IntPtr]::Zero
    }

    foreach ($v in $j.Variants) {
        $r = [ordered]@{ error = $null }
        $script:proc = $null
        try {
            # A Live variant starts with contrast off and turns it on under the running player.
            Set-Contrast $(if ($v.Live) { '' } else { $v.Scheme })
            $r.contrastOn = [HcRig]::IsOn()
            $r.sysColours = Get-SysColours

            Get-ChildItem (Split-Path $j.Exe -Parent) -Filter '*.ini' | ForEach-Object { [IO.File]::Delete($_.FullName) }
            Remove-Item (Join-Path (Split-Path $j.Exe -Parent) 'default.mpcpl') -Force -ErrorAction SilentlyContinue
            # The editor saves its clips beside the clip on close and loads them on the next open.
            Get-ChildItem 'C:\mpc-test\mouse\media\pw' -File | Where-Object { $_.Extension -ne '.mkv' } | ForEach-Object { [IO.File]::Delete($_.FullName) }
            [IO.File]::WriteAllText((Join-Path (Split-Path $j.Exe -Parent) 'mpc-hc64.ini'), $v.IniText, [Text.Encoding]::Unicode)

            $t = Start-TargetWindow -Exe $j.Exe -ArgumentLine $j.ArgumentLine -TopClass 'MediaPlayerClassicW'
            $script:proc = $t.Process
            $root = $t.Root
            [void][MouseRig]::SetWindowPos($root, [IntPtr]::Zero, 20, 20, 1000, 700, 0x0004 -bor 0x0010)      # NOZORDER|NOACTIVATE

            $title = ''
            $deadline = (Get-Date).AddSeconds(20)
            while ($title -notlike '*bravo*' -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300; $title = Get-WindowTextOf $root }
            $r.title = $title

            $pl = Wait-List $root $j.Ids.PlaylistList $j.Ids.ViewPlaylist
            $edl = Wait-List $root $j.Ids.EditList $j.Ids.ViewEdl
            Start-Sleep -Milliseconds 800

            # Two clips: the first gets an in and an out and is drawn in the list's normal text, the second has
            # no out and is drawn red whatever the theme, so only row 0 tells anything.
            Send-Command $root $j.Ids.EdlNewClip
            Start-Sleep -Milliseconds 700
            Send-Command $root $j.Ids.EdlNewClip
            Start-Sleep -Milliseconds 700

            # bravo plays on row 0; a real click selects charlie on row 1, row 2 stays plain.
            $row = [MouseRig]::ListItemRect($pl, 1, 0)
            Move-PointerGlide ($row.L + 60) ([int](($row.T + $row.B) / 2))
            [void][MouseRig]::Click()
            Start-Sleep -Milliseconds 300
            Move-PointerGlide 500 ([MouseRig]::GetSystemMetrics(1) - 10)
            Start-Sleep -Milliseconds 1300     # past the double-click time, or a later click starts a rename

            if ($v.Live) {
                Set-Contrast $v.Scheme
                $r.contrastOn = [HcRig]::IsOn()
                $r.sysColours = Get-SysColours
                Start-Sleep -Seconds 2
            }

            $r.playlist = Read-List $pl 3
            $r.editList = Read-List $edl 2
            Save-Screen 'x.png'
            Move-Item (Join-Path $outDir 'x.png') (Join-Path $outDir "$($v.Name)-main.png") -Force
            $r.mainPng = "$($v.Name)-main.png"

            # Organize Favorites: the entries come from the ini.
            Send-Command $root $j.Ids.FavoritesOrganize
            $dlg = [IntPtr]::Zero
            for ($i = 0; $i -lt 16 -and $dlg -eq [IntPtr]::Zero; $i++) { Start-Sleep -Milliseconds 300; $dlg = [MouseRig]::FindTop([uint32]$script:proc.Id, '#32770', 'Organize Favorites') }
            if ($dlg -eq [IntPtr]::Zero) { throw 'Organize Favorites never appeared' }
            [void][MouseRig]::SetWindowPos($dlg, [IntPtr]::Zero, 60, 60, 600, 420, 0x0004)
            Start-Sleep -Milliseconds 600
            $fav = [MouseRig]::FindChild($dlg, $j.Ids.FavoritesList)
            $row = [MouseRig]::ListItemRect($fav, 1, 0)
            Move-PointerGlide ($row.L + 40) ([int](($row.T + $row.B) / 2))
            [void][MouseRig]::Click()
            Move-PointerGlide 500 ([MouseRig]::GetSystemMetrics(1) - 10)
            Start-Sleep -Milliseconds 600
            $r.favorites = Read-List $fav 3
            $r.favoritesPng = "$($v.Name)-favorites.png"
            Save-ScreenRegion (Join-Path $outDir $r.favoritesPng) 0 0 ([MouseRig]::GetSystemMetrics(0)) ([MouseRig]::GetSystemMetrics(1))
            [void][MouseRig]::PostMessage($dlg, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)                      # WM_CLOSE
            Start-Sleep -Milliseconds 600

            # The rest is to look at.
            $w = New-Object MouseRig+RECT
            [void][MouseRig]::GetWindowRect($root, [ref]$w)
            Move-PointerGlide ($w.L + 24) ($w.T + 42)        # File, on the menu bar
            [void][MouseRig]::Click()
            Start-Sleep -Milliseconds 700
            Save-Screen "x.png"; Move-Item (Join-Path $outDir 'x.png') (Join-Path $outDir "$($v.Name)-menubar.png") -Force
            [void][MouseRig]::KeyPress(0x1B); Start-Sleep -Milliseconds 150; [void][MouseRig]::KeyPress(0x1B)
            Start-Sleep -Milliseconds 300

            Move-PointerGlide ($w.L + 90) ($w.B - 54)        # a transport button, for its hot state
            Start-Sleep -Milliseconds 700
            Save-Screen "x.png"; Move-Item (Join-Path $outDir 'x.png') (Join-Path $outDir "$($v.Name)-hot.png") -Force

            Move-PointerGlide ($w.L + 250) ($w.T + 250)      # on the video
            [void][MouseRig]::ClickRight()
            Start-Sleep -Milliseconds 700
            Save-Screen "x.png"; Move-Item (Join-Path $outDir 'x.png') (Join-Path $outDir "$($v.Name)-context.png") -Force
            [void][MouseRig]::KeyPress(0x1B)
            Start-Sleep -Milliseconds 300

            Send-Command $root $j.Ids.Options
            $opt = [IntPtr]::Zero
            for ($i = 0; $i -lt 20 -and $opt -eq [IntPtr]::Zero; $i++) { Start-Sleep -Milliseconds 300; $opt = [MouseRig]::FindTop([uint32]$script:proc.Id, '#32770', 'Options') }
            if ($opt -eq [IntPtr]::Zero) { throw 'Options never appeared' }
            Start-Sleep -Milliseconds 800
            Save-Screen "x.png"; Move-Item (Join-Path $outDir 'x.png') (Join-Path $outDir "$($v.Name)-options0.png") -Force
            for ($p = 1; $p -le [int]$j.OptionsPages; $p++) {
                [void][MouseRig]::KeyPress(0x28)             # down, in the page tree
                Start-Sleep -Milliseconds 600
                Save-Screen "x.png"; Move-Item (Join-Path $outDir 'x.png') (Join-Path $outDir "$($v.Name)-options$p.png") -Force
            }
            [void][MouseRig]::PostMessage($opt, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
            Start-Sleep -Milliseconds 600

            if ($v.Live) {
                Set-Contrast ''
                $r.contrastOnAfterRestore = [HcRig]::IsOn()
                Start-Sleep -Seconds 2
                $r.playlistRestored = Read-List $pl 3
                $r.restoredPng = "$($v.Name)-restored.png"
                Save-Screen 'x.png'; Move-Item (Join-Path $outDir 'x.png') (Join-Path $outDir $r.restoredPng) -Force
            }

            # No file: most toolbar buttons disabled.
            Send-Command $root $j.Ids.CloseMedia
            Start-Sleep -Milliseconds 1500
            Save-Screen "x.png"; Move-Item (Join-Path $outDir 'x.png') (Join-Path $outDir "$($v.Name)-nofile.png") -Force
        } catch {
            $r.error = $_.Exception.Message + ' @ ' + $_.InvocationInfo.PositionMessage
        } finally {
            if ($script:proc) {
                $main = [MouseRig]::FindTop([uint32]$script:proc.Id, 'MediaPlayerClassicW', '')
                if ($main -ne [IntPtr]::Zero) { [void][MouseRig]::PostMessage($main, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) }
                if (-not $script:proc.WaitForExit(10000)) { Stop-Process -Id $script:proc.Id -Force -ErrorAction SilentlyContinue; $r.killedOnClose = $true }
            }
            $result.variants[$v.Name] = $r
        }
    }
} catch {
    $result.error = $_.Exception.Message + ' @ ' + $_.InvocationInfo.PositionMessage
} finally {
    try { [void][HcRig]::Set($false, ''); Start-Sleep -Seconds 3; $result.contrastOnAtEnd = [HcRig]::IsOn() } catch { $result.contrastOnAtEnd = 'unknown' }
    $result.finished = (Get-Date).ToString('o')
    $result | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $outDir 'result.json')
}
