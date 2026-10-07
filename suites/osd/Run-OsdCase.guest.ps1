<#
.SYNOPSIS
    Target side of the osd suite: plays a clip fullscreen, shows a message with the docked panels up and again
    with them gone, captures the player window each time, and measures the message box.

.DESCRIPTION
    Runs as the console user from an interactive scheduled task. Everything is driven by posting WM_COMMAND to
    the player's own window, so no input focus is needed. The job file names the player, the clip, the
    renderer and the command ids; result.json records, for each shot, the box measured in the capture and the
    client rect of the video view, which is what says whether the panels were really docked at the time.
#>
param([Parameter(Mandatory)][string] $JobFile)

$ErrorActionPreference = 'Stop'
$job = Get-Content $JobFile -Raw | ConvertFrom-Json
$result = [ordered]@{ error = $null; renderer = $null; screen = $null; shots = @() }

try {
    Add-Type -AssemblyName System.Drawing
    Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class OsdCase {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint f);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc p, IntPtr l);
    [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }

    // the video view is the largest visible direct child of the main frame
    public static IntPtr View(IntPtr main) {
        IntPtr best = IntPtr.Zero; long bestArea = -1;
        EnumChildWindows(main, (h, l) => {
            if (GetParent(h) == main && IsWindowVisible(h)) {
                RECT r; GetClientRect(h, out r);
                long a = (long)r.R * r.B;
                if (a > bestArea) { bestArea = a; best = h; }
            }
            return true;
        }, IntPtr.Zero);
        return best;
    }

    // The message box, found by its fill colour: the width is the longest run of that colour on any row of the
    // top-left region (the padding rows carry no text), the height runs from the first to the last row carrying
    // a run of at least 80% of that width starting at the same x. Returns null when there is no box.
    public static int[] Box(byte[] px, int stride, int W, int H, int fill) {
        int fr = (fill >> 16) & 0xff, fg = (fill >> 8) & 0xff, fb = fill & 0xff;
        int[] runs = new int[H]; int[] lefts = new int[H];
        for (int y = 0; y < H; y++) {
            int cur = 0, best = 0, bestLeft = 0;
            for (int x = 0; x < W; x++) {
                int o = y * stride + x * 4;
                bool near = Math.Abs(px[o] - fb) + Math.Abs(px[o + 1] - fg) + Math.Abs(px[o + 2] - fr) <= 9;
                cur = near ? cur + 1 : 0;
                if (cur > best) { best = cur; bestLeft = x - cur + 1; }
            }
            runs[y] = best; lefts[y] = bestLeft;
        }
        int max = 0, at = 0;
        for (int y = 0; y < H; y++) if (runs[y] > max) { max = runs[y]; at = y; }
        if (max < 20) return null;
        int top = at, bottom = at;
        for (int y = 0; y < H; y++) {
            if (runs[y] >= max * 8 / 10 && Math.Abs(lefts[y] - lefts[at]) <= 2) {
                if (y < top) top = y;
                if (y > bottom) bottom = y;
            }
        }
        return new int[] { lefts[at], top, max, bottom - top + 1 };
    }
}
"@
    [void][OsdCase]::SetProcessDpiAwarenessContext([IntPtr]-4)
    $WM_COMMAND = 0x111; $WM_CLOSE = 0x10

    $p = Start-Process $job.Exe -ArgumentList '/new', '/play', "`"$($job.Clip)`"" -PassThru
    try {
        $main = [IntPtr]::Zero
        for ($i = 0; $i -lt 120 -and $main -eq [IntPtr]::Zero; $i++) { Start-Sleep -Milliseconds 250; $p.Refresh(); $main = $p.MainWindowHandle }
        if ($main -eq [IntPtr]::Zero) { throw 'the player never showed a window' }
        # A posted WM_COMMAND is dropped while its command is disabled, so let the file finish loading first.
        Start-Sleep -Seconds 6
        $p.Refresh()
        $result.renderer = @($p.Modules | Where-Object { $_.ModuleName -match 'VideoRenderer|evr\.dll|madvr' } | ForEach-Object { $_.FileName })

        function Send-Command([int] $Id, [int] $WaitMs) {
            [void][OsdCase]::PostMessage($main, $WM_COMMAND, [IntPtr]$Id, [IntPtr]::Zero)
            Start-Sleep -Milliseconds $WaitMs
        }
        function Save-Shot([string] $Name) {
            $r = New-Object OsdCase+RECT; [void][OsdCase]::GetWindowRect($main, [ref]$r)
            $view = [OsdCase]::View($main)
            $vr = New-Object OsdCase+RECT; [void][OsdCase]::GetClientRect($view, [ref]$vr)
            $bmp = New-Object System.Drawing.Bitmap ($r.R - $r.L), ($r.B - $r.T)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $hdc = $g.GetHdc(); [void][OsdCase]::PrintWindow($main, $hdc, 2); $g.ReleaseHdc($hdc); $g.Dispose()
            $png = "$Name.png"
            $bmp.Save((Join-Path $job.OutDir $png))
            # the message is drawn top left; keep clear of a docked playlist, whose background is the same colour
            $W = [Math]::Min(900, [int]($bmp.Width * 0.4)); $H = [Math]::Min(500, [int]($bmp.Height * 0.4))
            $d = $bmp.LockBits((New-Object System.Drawing.Rectangle 0, 0, $W, $H), 'ReadOnly', 'Format32bppArgb')
            $buf = New-Object byte[] ($d.Stride * $H)
            [Runtime.InteropServices.Marshal]::Copy($d.Scan0, $buf, 0, $buf.Length)
            $bmp.UnlockBits($d)
            $box = [OsdCase]::Box($buf, $d.Stride, $W, $H, [int]$job.Fill)
            $script:result.screen = @{ w = $bmp.Width; h = $bmp.Height }
            $bmp.Dispose()
            $script:result.shots += [ordered]@{
                name = $Name; png = $png
                view = @{ w = $vr.R; h = $vr.B }
                box  = if ($box) { @{ x = $box[0]; y = $box[1]; w = $box[2]; h = $box[3] } } else { $null }
            }
        }

        # Panels up: the playlist docked before going fullscreen, and the fullscreen toolbars still showing
        # because the ini holds them for five seconds.
        Send-Command $job.IdPlaylist 800
        Send-Command $job.IdFullscreen 1500
        Send-Command $job.IdPlayPause 800
        Save-Shot 'panels'

        # Panels gone: the playlist closed, the toolbars hidden by their own delay. Two presses so that the
        # message is the same word as in the first shot.
        Send-Command $job.IdPlaylist 800
        Start-Sleep -Seconds 6
        Send-Command $job.IdPlayPause 800
        Send-Command $job.IdPlayPause 800
        Save-Shot 'no-panels'
    } finally {
        if (-not $p.HasExited) { [void][OsdCase]::PostMessage($p.MainWindowHandle, $WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero); [void]$p.WaitForExit(15000) }
        if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    }
} catch {
    $result.error = "$_"
}

$result | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $job.OutDir 'result.json')
