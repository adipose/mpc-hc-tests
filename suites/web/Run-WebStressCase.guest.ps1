# Runs on the target, in the console session. One case: the web server's status.json and
# playlist.json polled in tight loops while files open and close under them. The host asserts; one
# JSON object goes to <OutDir>\result.json.
#
# The player is started with a plain clip, then every OpenEveryMs a command line goes to its window
# over WM_COPYDATA in the form a second instance would send (CMPlayerCApp::SendCommandLine: dwData
# 0x6ABE51, a DWORD count, then each argument as a NUL terminated UTF-16 string), alternating the
# plain clip repeated PlaylistItems times (a long playlist, no subtitle tracks) with the subtitle
# clip alone (a one entry playlist, two embedded tracks). Each open rebuilds the playlist and the
# subtitle stream list on the UI thread while Clients pollers read them through the web server.
#
# Recorded: how many answers came back by kind (200 with a body that parses, 503, other statuses,
# refused connections, 200 with a body that does not parse), the range of playlist sizes and
# subtitle track counts the pollers saw (proof that the opens happened under them), how many
# command lines were sent, and whether the player was still running at the end and with what exit
# code. Before the fix (ledger 29) the JSON was built on the web server's thread straight from the
# lists the UI thread was rewriting; after it the builders run on the UI thread.
param([Parameter(Mandatory)] [string] $Job)

$ErrorActionPreference = 'Stop'
$j = Get-Content -Raw $Job | ConvertFrom-Json
$outDir = $j.OutDir
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory $outDir | Out-Null }
$result = [ordered]@{ started = (Get-Date).ToString('o'); error = $null }
$script:proc = $null

Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class WebStress {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessageTimeout(IntPtr h, uint m, IntPtr w, ref COPYDATASTRUCT l, uint flags, uint timeout, out IntPtr result);
    [StructLayout(LayoutKind.Sequential)] public struct COPYDATASTRUCT { public IntPtr dwData; public int cbData; public IntPtr lpData; }

    public static IntPtr FindMain(uint pid) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p != pid) return true;
            var sb = new StringBuilder(256); GetClassName(h, sb, 256);
            if (sb.ToString() == "MediaPlayerClassicW") { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static bool SendCommandLine(IntPtr hwnd, string[] args, uint timeoutMs) {
        int len = 4;
        foreach (var a in args) len += (a.Length + 1) * 2;
        var buf = Marshal.AllocHGlobal(len);
        try {
            Marshal.WriteInt32(buf, args.Length);
            int off = 4;
            foreach (var a in args) {
                var bytes = Encoding.Unicode.GetBytes(a + "\0");
                Marshal.Copy(bytes, 0, buf + off, bytes.Length);
                off += bytes.Length;
            }
            var cds = new COPYDATASTRUCT { dwData = (IntPtr)0x6ABE51, cbData = len, lpData = buf };
            IntPtr result;
            return SendMessageTimeout(hwnd, 0x004A, IntPtr.Zero, ref cds, 0x0000, timeoutMs, out result) != IntPtr.Zero;
        } finally { Marshal.FreeHGlobal(buf); }
    }
}
'@

# One poller: a tight loop over both documents, counting answers by kind and checking that a 200
# body parses, with the range of playlist sizes and subtitle track counts it saw.
$pollerScript = {
    param([int] $Port, [int] $Seconds, [string] $LogPath)
    # itemSizes and subCounts: how many 200 answers reported each playlist size and each subtitle
    # track count. A size the player never had is a walk over nodes being freed and reused.
    $c = @{ ok = 0; s503 = 0; other = 0; refused = 0; malformed = 0; itemSizes = @{}; subCounts = @{} }
    $paths = '/status.json', '/playlist.json'
    $i = 0
    $end = (Get-Date).AddSeconds($Seconds)
    $log = [System.Collections.Generic.List[string]]::new()
    while ((Get-Date) -lt $end) {
        $path = $paths[$i % 2]; $i++
        try {
            $req = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$Port$path")
            $req.Timeout = 10000; $req.KeepAlive = $false
            $resp = $req.GetResponse()
            $status = [int]$resp.StatusCode
            $sr = [IO.StreamReader]::new($resp.GetResponseStream()); $body = $sr.ReadToEnd(); $sr.Close(); $resp.Close()
            if ($status -eq 200) {
                try {
                    $d = $body | ConvertFrom-Json; $c.ok++
                    if ($path -eq '/playlist.json') { $n = [string]@($d.items).Count; $c.itemSizes[$n] = 1 + $(if ($c.itemSizes.ContainsKey($n)) { $c.itemSizes[$n] } else { 0 }) }
                    else { $n = [string]@($d.subtitle.tracks).Count; $c.subCounts[$n] = 1 + $(if ($c.subCounts.ContainsKey($n)) { $c.subCounts[$n] } else { 0 }) }
                } catch { $c.malformed++; if ($log.Count -lt 50) { $log.Add("malformed $path : $body") } }
            } else { $c.other++ }
        } catch [System.Net.WebException] {
            $we = $_.Exception
            if ($we.Response) {
                $st = [int]$we.Response.StatusCode
                if ($st -eq 503) { $c.s503++ } else { $c.other++; if ($log.Count -lt 50) { $log.Add("status $st $path") } }
                $we.Response.Close()
            } else { $c.refused++; if ($log.Count -lt 50) { $log.Add("refused $path : $($we.Status)") } }
        } catch { $c.other++; if ($log.Count -lt 50) { $log.Add("error $path : $_") } }
    }
    [IO.File]::WriteAllLines($LogPath, $log)
    $c
}

try {
    $script:proc = Start-Process -FilePath $j.Exe -ArgumentList '/new', "`"$($j.ClipPlain)`"" -PassThru
    $pid0 = [uint32]$script:proc.Id
    $hwnd = [IntPtr]::Zero
    $deadline = (Get-Date).AddSeconds(20)
    while ($hwnd -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200; $hwnd = [WebStress]::FindMain($pid0) }
    if ($hwnd -eq [IntPtr]::Zero) { throw 'the player window did not appear' }
    $ready = $false
    $deadline = (Get-Date).AddSeconds(20)
    while (-not $ready -and (Get-Date) -lt $deadline) {
        try {
            $r = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$($j.Port)/status.json"); $r.Timeout = 2000
            $resp = $r.GetResponse(); $ready = ([int]$resp.StatusCode -eq 200); $resp.Close()
        } catch { Start-Sleep -Milliseconds 300 }
    }
    if (-not $ready) { throw "the web server on port $($j.Port) never answered 200" }

    $pool = [runspacefactory]::CreateRunspacePool(1, [int]$j.Clients); $pool.Open()
    $jobs = foreach ($c in 1..$j.Clients) {
        $ps = [powershell]::Create(); $ps.RunspacePool = $pool
        $null = $ps.AddScript($pollerScript).AddArgument([int]$j.Port).AddArgument([int]$j.Seconds).AddArgument((Join-Path $outDir "poller-$c.log"))
        @{ ps = $ps; handle = $ps.BeginInvoke() }
    }

    $longList = @('/open') + @(1..$j.PlaylistItems | ForEach-Object { $j.ClipPlain })
    $shortList = @('/open', $j.ClipSubs)
    $opens = 0; $sendFailures = 0
    $end = (Get-Date).AddSeconds([int]$j.Seconds)
    while ((Get-Date) -lt $end) {
        $args = if ($opens % 2 -eq 0) { $longList } else { $shortList }
        if (-not [WebStress]::SendCommandLine($hwnd, [string[]]$args, 5000)) { $sendFailures++ }
        $opens++
        Start-Sleep -Milliseconds ([int]$j.OpenEveryMs)
        if ($script:proc.HasExited) { break }
    }
    $result.opens = $opens
    $result.sendFailures = $sendFailures

    $totals = @{ ok = 0; s503 = 0; other = 0; refused = 0; malformed = 0 }
    $itemSizes = @{}; $subCounts = @{}
    foreach ($jb in $jobs) {
        $r = $jb.ps.EndInvoke($jb.handle)[0]; $jb.ps.Dispose()
        foreach ($k in 'ok', 's503', 'other', 'refused', 'malformed') { $totals[$k] += $r[$k] }
        foreach ($k in $r.itemSizes.Keys) { $itemSizes[$k] = $r.itemSizes[$k] + $(if ($itemSizes.ContainsKey($k)) { $itemSizes[$k] } else { 0 }) }
        foreach ($k in $r.subCounts.Keys) { $subCounts[$k] = $r.subCounts[$k] + $(if ($subCounts.ContainsKey($k)) { $subCounts[$k] } else { 0 }) }
    }
    $pool.Close()
    foreach ($k in $totals.Keys) { $result[$k] = $totals[$k] }
    $result.playlistSizes = $itemSizes
    $result.subtitleCounts = $subCounts

    $script:proc.Refresh()
    $result.survived = -not $script:proc.HasExited
    if ($script:proc.HasExited) {
        $result.exitCode = $script:proc.ExitCode
    } else {
        [void][WebStress]::PostMessage($hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE
        $result.closed = $script:proc.WaitForExit(20000)
        if ($result.closed) { $result.exitCode = $script:proc.ExitCode }
    }
}
catch {
    $result.error = "$_"
}
finally {
    if ($script:proc -and -not $script:proc.HasExited) { Stop-Process -Id $script:proc.Id -Force -ErrorAction SilentlyContinue }
    $result.finished = (Get-Date).ToString('o')
    [IO.File]::WriteAllText((Join-Path $outDir 'result.json'), ($result | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
}
