# Runs on the target, in the console session. One case: the player closed while web clients are
# requesting pages whose handlers read the frame straight from the web server's thread. The host
# asserts; one JSON object goes to <OutDir>\result.json.
#
# Each round starts the player on a clip with the web server on, waits for /variables.html to answer,
# starts Clients pollers that request it in tight loops, lets them run for WarmMs, posts WM_CLOSE and
# waits for the process to exit. Before the fix the server was stopped only by CMainFrame's destructor,
# after the playlist bar (declared later in the class, so destroyed first) had gone, and a request still
# in OnVariables took its destroyed lock (drdump 147489303, issue #4257). OnClose now stops the server
# while the frame is whole.
#
# Recorded per round: the exit code, whether the player closed within 20 s, how long the close took,
# and how many answers the pollers got before it.
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
public static class WebClose {
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

# One poller: request the page until told to stop, counting the answers that came back.
$poller = {
    param($url, $state, $n)
    $ok = 0
    while (-not $state.Stop) {
        try {
            $r = [System.Net.HttpWebRequest]::Create($url)
            $r.Timeout = 3000; $r.KeepAlive = $false
            $resp = $r.GetResponse()
            $sr = New-Object IO.StreamReader($resp.GetResponseStream())
            [void]$sr.ReadToEnd(); $sr.Close(); $resp.Close()
            $ok++
        } catch { }
    }
    $state["ok$n"] = $ok
}

try {
    $url = "http://127.0.0.1:$($j.Port)/variables.html"
    $rounds = @()
    foreach ($round in 1..([int]$j.Rounds)) {
        $script:proc = Start-Process -FilePath $j.Exe -ArgumentList '/new', "`"$($j.Clip)`"" -PassThru
        $pid0 = [uint32]$script:proc.Id
        $hwnd = [IntPtr]::Zero
        $deadline = (Get-Date).AddSeconds(20)
        while ($hwnd -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100; $hwnd = [WebClose]::FindMain($pid0) }
        if ($hwnd -eq [IntPtr]::Zero) { throw "round ${round}: the player window did not appear" }
        $ready = $false
        $deadline = (Get-Date).AddSeconds(20)
        while (-not $ready -and (Get-Date) -lt $deadline) {
            try {
                $r = [System.Net.HttpWebRequest]::Create($url); $r.Timeout = 2000
                $resp = $r.GetResponse(); $ready = ([int]$resp.StatusCode -eq 200); $resp.Close()
            } catch { Start-Sleep -Milliseconds 200 }
        }
        if (-not $ready) { throw "round ${round}: the web server on port $($j.Port) never answered 200" }

        $state = [hashtable]::Synchronized(@{ Stop = $false })
        $pool = [runspacefactory]::CreateRunspacePool(1, [int]$j.Clients)
        $pool.Open()
        $handles = foreach ($n in 1..([int]$j.Clients)) {
            $ps = [powershell]::Create(); $ps.RunspacePool = $pool
            [void]$ps.AddScript($poller).AddArgument($url).AddArgument($state).AddArgument($n)
            [pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke() }
        }
        Start-Sleep -Milliseconds ([int]$j.WarmMs)

        $sw = [Diagnostics.Stopwatch]::StartNew()
        [void][WebClose]::PostMessage($hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE
        $closed = $script:proc.WaitForExit(20000)
        $sw.Stop()
        $state.Stop = $true
        foreach ($h in $handles) { [void]$h.PS.EndInvoke($h.Handle); $h.PS.Dispose() }
        $pool.Close()

        $ok = 0
        foreach ($n in 1..([int]$j.Clients)) { $ok += [int]$state["ok$n"] }
        $entry = [ordered]@{ round = $round; closed = $closed; closeMs = [int]$sw.ElapsedMilliseconds; answers = $ok; exitCode = $null }
        if ($closed) { $entry.exitCode = $script:proc.ExitCode }
        else { Stop-Process -Id $script:proc.Id -Force -ErrorAction SilentlyContinue; $script:proc.WaitForExit(5000) | Out-Null }
        $rounds += [pscustomobject]$entry
        # a crashed player's leftover crash reporter must not hold the port into the next round
        Start-Sleep -Milliseconds 300
    }
    $result.rounds = $rounds
}
catch {
    $result.error = "$_"
}
finally {
    if ($script:proc -and -not $script:proc.HasExited) { Stop-Process -Id $script:proc.Id -Force -ErrorAction SilentlyContinue }
    $result.finished = (Get-Date).ToString('o')
    [IO.File]::WriteAllText((Join-Path $outDir 'result.json'), ($result | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
}
