# Runs on the target, in the console session. One case: requests a well-behaved client never sends.
# The host asserts; one JSON object goes to <OutDir>\result.json.
#
# The player is started with no file and the web server on. Each request goes over its own raw socket
# and everything that comes back within ReadTimeoutMs is kept, up to the end of the response header:
#
#   control      GET /status.html with an ordinary "X-Test: 1" header line
#   no-colon     the same request with a header line that has no colon. Before patch789 ParseHeader
#                took the colon as found, and with none left in the buffer it read from a null pointer
#   redir-crlf   GET /status.html?redir=... where the decoded redir holds "\r\nX-Injected: yes". It goes
#                into the Location line of the 302, and before patch789 the line break went with it, so
#                the injected line arrived as a header of its own (response splitting)
#
# Recorded per request: the header block that came back, or an empty string when nothing did; and
# whether the player was still running at the end and with what exit code.
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
public static class WebMalformed {
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

# Sends one raw request and returns the response header block, or '' when nothing came back in time.
function Send-Raw {
    param([string] $Request)
    $client = [System.Net.Sockets.TcpClient]::new('127.0.0.1', [int]$j.Port)
    try {
        $client.NoDelay = $true
        $stream = $client.GetStream(); $stream.ReadTimeout = [int]$j.ReadTimeoutMs
        $bytes = [Text.Encoding]::ASCII.GetBytes($Request)
        $stream.Write($bytes, 0, $bytes.Length); $stream.Flush()
        $got = [System.IO.MemoryStream]::new()
        $buf = New-Object byte[] 4096
        try {
            while ($true) {
                $n = $stream.Read($buf, 0, $buf.Length)
                if ($n -le 0) { break }
                $got.Write($buf, 0, $n)
                $text = [Text.Encoding]::ASCII.GetString($got.ToArray())
                if ($text.Contains("`r`n`r`n")) { break }
            }
        } catch { }
        $text = [Text.Encoding]::ASCII.GetString($got.ToArray())
        $end = $text.IndexOf("`r`n`r`n")
        if ($end -ge 0) { $text.Substring(0, $end) } else { $text }
    } finally { $client.Close() }
}

try {
    $script:proc = Start-Process -FilePath $j.Exe -ArgumentList '/new' -PassThru
    $pid0 = [uint32]$script:proc.Id
    $hwnd = [IntPtr]::Zero
    $deadline = (Get-Date).AddSeconds(20)
    while ($hwnd -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200; $hwnd = [WebMalformed]::FindMain($pid0) }
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

    $answers = [ordered]@{}
    $answers['control'] = Send-Raw "GET /status.html HTTP/1.0`r`nX-Test: 1`r`n`r`n"
    $answers['no-colon'] = Send-Raw "GET /status.html HTTP/1.0`r`nX-Test: 1`r`nNoColonOnThisLine`r`n`r`n"
    $answers['redir-crlf'] = Send-Raw "GET /status.html?redir=%2F%0D%0AX-Injected%3A%20yes HTTP/1.0`r`n`r`n"
    $result.answers = $answers

    # a crash on the web server's thread takes the player down, give it a moment to go
    Start-Sleep -Milliseconds 1000
    $script:proc.Refresh()
    $result.survived = -not $script:proc.HasExited
    if ($script:proc.HasExited) {
        $result.exitCode = $script:proc.ExitCode
    } else {
        [void][WebMalformed]::PostMessage($hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE
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
