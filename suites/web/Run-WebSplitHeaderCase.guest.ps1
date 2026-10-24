# Runs on the target, in the console session. One case: a request whose blank line ending the header
# ("\r\n\r\n") arrives split across two TCP reads. The host asserts; one JSON object goes to
# <OutDir>\result.json.
#
# The player is started with no file and the web server on. For each split, one connection writes
# "GET /status.html HTTP/1.0\r\n\r\n" with the last HoldBack bytes held back, waits GapMs so the server
# reads the first part on its own, writes the rest, and reads with a timeout. HoldBack 1 to 3 puts part
# of the terminator in each read; 0 and 4 are the controls, the terminator whole in one read. Before the
# fix (ledger 30) the next search for the terminator started at the end of the first read, past the
# bytes that held its start, so a split one never got an answer.
#
# Recorded per split: the status line that came back, or an empty string when nothing came back within
# ReadTimeoutMs; and whether the player was still running at the end and with what exit code.
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
public static class WebSplit {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);

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
}
'@

try {
    $script:proc = Start-Process -FilePath $j.Exe -ArgumentList '/new' -PassThru
    $pid0 = [uint32]$script:proc.Id
    $hwnd = [IntPtr]::Zero
    $deadline = (Get-Date).AddSeconds(20)
    while ($hwnd -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200; $hwnd = [WebSplit]::FindMain($pid0) }
    if ($hwnd -eq [IntPtr]::Zero) { throw 'the player window did not appear' }
    $ready = $false
    $deadline = (Get-Date).AddSeconds(20)
    while (-not $ready -and (Get-Date) -lt $deadline) {
        try {
            $r = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$($j.Port)/status.html"); $r.Timeout = 2000
            $resp = $r.GetResponse(); $ready = ([int]$resp.StatusCode -eq 200); $resp.Close()
        } catch { Start-Sleep -Milliseconds 300 }
    }
    if (-not $ready) { throw "the web server on port $($j.Port) never answered 200" }

    $request = "GET /status.html HTTP/1.0`r`n`r`n"
    $answers = [ordered]@{}
    foreach ($holdBack in 0..4) {
        $cut = $request.Length - $holdBack
        $client = [System.Net.Sockets.TcpClient]::new('127.0.0.1', [int]$j.Port)
        try {
            $client.NoDelay = $true
            $stream = $client.GetStream(); $stream.ReadTimeout = [int]$j.ReadTimeoutMs
            $first = [Text.Encoding]::ASCII.GetBytes($request.Substring(0, $cut))
            $stream.Write($first, 0, $first.Length); $stream.Flush()
            if ($holdBack) {
                Start-Sleep -Milliseconds ([int]$j.GapMs)
                $rest = [Text.Encoding]::ASCII.GetBytes($request.Substring($cut))
                $stream.Write($rest, 0, $rest.Length); $stream.Flush()
            }
            $buf = New-Object byte[] 4096
            $line = ''
            try { $n = $stream.Read($buf, 0, $buf.Length); $line = ([Text.Encoding]::ASCII.GetString($buf, 0, $n) -split "`r`n")[0] } catch { }
            $answers["$holdBack"] = $line
        } finally { $client.Close() }
    }
    $result.answers = $answers

    $script:proc.Refresh()
    $result.survived = -not $script:proc.HasExited
    if ($script:proc.HasExited) {
        $result.exitCode = $script:proc.ExitCode
    } else {
        [void][WebSplit]::PostMessage($hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE
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
