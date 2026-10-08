# Runs on the target, in the console session (the player needs a desktop). Hosts the player's
# /slave API (src/mpc-hc/MpcApi.h): creates a message-only window that records every WM_COPYDATA
# the player sends, starts the player with /slave <that hwnd> plus the clip, waits for CMD_CONNECT
# (its payload is the player's window handle), sends the case's commands to the player as
# WM_COPYDATA at their times -- as src/MPCTestAPI's Senddata does, dwData the CMD_ code and lpData
# the null-terminated UTF-16 payload -- records every reply in order with its time, and closes the
# player with CMD_CLOSEAPP.
# The message pump runs on this thread: every wait is a short Application.DoEvents loop, because
# the player's notifications (CMD_CONNECT included) are blocking SendMessage calls to the host
# window, which only complete while this thread dispatches messages.
# Writes one JSON object to -Out; the host does the asserting.
param(
    [Parameter(Mandatory)] [string] $Exe,
    [string] $Clip = '',               # full path on the guest; empty opens nothing
    [string] $Switches = '/play',
    [Parameter(Mandatory)] [string] $Out,
    [int] $TimeoutSec = 40,
    [double] $CloseAtSec = 0,          # 0 = CMD_CLOSEAPP two seconds after the last command
    [string] $Commands = ''            # comma-separated base64 entries, each the UTF-8 of
                                       # <seconds>:<CMD name or number>:<payload>; the payload may
                                       # be empty and may hold spaces or quotes, which is why the
                                       # entries ride base64 (the task line is built by hand)
)

$ErrorActionPreference = 'Continue'
$result = [ordered]@{ started = (Get-Date).ToString('o') }
$caseStart = Get-Date

# The MPCAPI_COMMAND enum of MpcApi.h: commands the host sends (0xA000....) and notifications the
# player sends back (0x5000....). Values from the header, never guessed.
# The L suffix is load-bearing: in PS 5.1 a bare 0xA0000000 parses as a negative Int32, which
# would sign-extend to 0xFFFFFFFFA0000000 in the 64-bit COPYDATASTRUCT.dwData and never match.
$apiCommands = [ordered]@{
    CMD_OPENFILE = 0xA0000000L; CMD_STOP = 0xA0000001L; CMD_CLOSEFILE = 0xA0000002L
    CMD_PLAYPAUSE = 0xA0000003L; CMD_PLAY = 0xA0000004L; CMD_PAUSE = 0xA0000005L
    CMD_ADDTOPLAYLIST = 0xA0001000L; CMD_CLEARPLAYLIST = 0xA0001001L; CMD_STARTPLAYLIST = 0xA0001002L
    CMD_REMOVEFROMPLAYLIST = 0xA0001003L
    CMD_SETPOSITION = 0xA0002000L; CMD_SETAUDIODELAY = 0xA0002001L; CMD_SETSUBTITLEDELAY = 0xA0002002L
    CMD_SETINDEXPLAYLIST = 0xA0002003L; CMD_SETAUDIOTRACK = 0xA0002004L; CMD_SETSUBTITLETRACK = 0xA0002005L
    CMD_GETSUBTITLETRACKS = 0xA0003000L; CMD_GETAUDIOTRACKS = 0xA0003001L; CMD_GETNOWPLAYING = 0xA0003002L
    CMD_GETPLAYLIST = 0xA0003003L; CMD_GETCURRENTPOSITION = 0xA0003004L; CMD_JUMPOFNSECONDS = 0xA0003005L
    CMD_GETVERSION = 0xA0003006L; CMD_GETCURRENTAUDIOTRACK = 0xA0003007L; CMD_GETCURRENTSUBTITLETRACK = 0xA0003008L
    CMD_GETVOLUME = 0xA0003009L; CMD_GETMUTE = 0xA000300AL
    CMD_SETVOLUME = 0xA0003010L; CMD_SETMUTE = 0xA0003011L
    CMD_TOGGLEFULLSCREEN = 0xA0004000L; CMD_JUMPFORWARDMED = 0xA0004001L; CMD_JUMPBACKWARDMED = 0xA0004002L
    CMD_INCREASEVOLUME = 0xA0004003L; CMD_DECREASEVOLUME = 0xA0004004L; CMD_SHADER_TOGGLE = 0xA0004005L
    CMD_CLOSEAPP = 0xA0004006L; CMD_SETSPEED = 0xA0004008L; CMD_SETPANSCAN = 0xA0004009L
    CMD_OSDSHOWMESSAGE = 0xA0005000L; CMD_STATUSSHOWMESSAGE = 0xA0005001L
    CMD_CONNECT = 0x50000000L; CMD_STATE = 0x50000001L; CMD_PLAYMODE = 0x50000002L
    CMD_NOWPLAYING = 0x50000003L; CMD_LISTSUBTITLETRACKS = 0x50000004L; CMD_LISTAUDIOTRACKS = 0x50000005L
    CMD_PLAYLIST = 0x50000006L; CMD_CURRENTPOSITION = 0x50000007L; CMD_NOTIFYSEEK = 0x50000008L
    CMD_NOTIFYENDOFSTREAM = 0x50000009L; CMD_VERSION = 0x5000000AL; CMD_DISCONNECT = 0x5000000BL
    CMD_CURRENTAUDIOTRACK = 0x5000000CL; CMD_CURRENTSUBTITLETRACK = 0x5000000DL
    CMD_CURRENTVOLUME = 0x5000000EL; CMD_CURRENTMUTE = 0x5000000FL
}
# Code -> name, for labelling the recorded replies.
$apiNames = @{}
foreach ($name in $apiCommands.Keys) { $apiNames[[long] $apiCommands[$name]] = $name }

Add-Type -AssemblyName System.Windows.Forms
if (-not ('MpcTest.ApiHostWindow' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace MpcTest {
    public class ApiMessage {
        public double At;
        public long Code;
        public string Payload;
    }

    // The host window of the /slave API: a message-only window whose WndProc records every
    // WM_COPYDATA the player sends (COPYDATASTRUCT.dwData is the CMD_ code, lpData the UTF-16
    // payload). Message-only, so there is nothing to show; WM_COPYDATA is always sent, never
    // posted, and sent messages reach a message-only window the same as any other.
    public class ApiHostWindow : NativeWindow {
        public const int WM_COPYDATA = 0x004A;
        public readonly List<ApiMessage> Received = new List<ApiMessage>();
        private readonly Func<double> clock;

        public ApiHostWindow(Func<double> clock) {
            this.clock = clock;
            CreateParams cp = new CreateParams();
            cp.Caption = "MpcTestApiHost";
            cp.Parent = (IntPtr)(-3);   // HWND_MESSAGE
            CreateHandle(cp);
        }

        protected override void WndProc(ref Message m) {
            if (m.Msg == WM_COPYDATA) {
                // COPYDATASTRUCT: ULONG_PTR dwData, DWORD cbData, PVOID lpData. lpData sits at
                // 2 * IntPtr.Size on x86 and x64 alike (8-byte alignment on x64).
                // Mask to 32 bits: the player's switch is on the unsigned int enum values, so a
                // received code must read as the positive 32-bit value even if it sign-extended.
                long code = Marshal.ReadIntPtr(m.LParam).ToInt64() & 0xFFFFFFFFL;
                IntPtr data = Marshal.ReadIntPtr(m.LParam, IntPtr.Size * 2);
                Received.Add(new ApiMessage {
                    At = clock(),
                    Code = code,
                    Payload = data != IntPtr.Zero ? Marshal.PtrToStringUni(data) : null
                });
            }
            base.WndProc(ref m);
        }
    }

    public static class ApiCopyData {
        [DllImport("user32.dll")]
        public static extern IntPtr SendMessageW(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

        // One command to the player, as MPCTestAPI's Senddata does: dwData the CMD_ code, lpData
        // the null-terminated UTF-16 payload, wParam the host's own window handle (the player
        // gates its setters on that being the registered host window). The buffers must outlive
        // delivery, so they are freed only after the synchronous SendMessage returns. A reply to
        // a query (CMD_CURRENTVOLUME and friends) is itself a blocking SendMessage back to the
        // host window; a thread blocked in SendMessage still dispatches incoming sent messages,
        // so ApiHostWindow.WndProc records such a reply before SendMessageW below returns.
        public static long Send(IntPtr to, IntPtr from, long code, string payload) {
            if (payload == null) { payload = ""; }
            IntPtr text = Marshal.StringToCoTaskMemUni(payload);
            IntPtr cds = Marshal.AllocCoTaskMem(IntPtr.Size * 3);
            try {
                // Mask to 32 bits so a negative code can never sign-extend into the high half of
                // the 64-bit ULONG_PTR dwData; the player's switch is on the unsigned enum values.
                Marshal.WriteIntPtr(cds, 0, (IntPtr)(code & 0xFFFFFFFFL));
                Marshal.WriteInt32(cds, IntPtr.Size, (payload.Length + 1) * 2);
                Marshal.WriteIntPtr(cds, IntPtr.Size * 2, text);
                return SendMessageW(to, ApiHostWindow.WM_COPYDATA, from, cds).ToInt64();
            } finally {
                Marshal.FreeCoTaskMem(text);
                Marshal.FreeCoTaskMem(cds);
            }
        }
    }
}
'@ -ReferencedAssemblies 'System.Windows.Forms'
}

$clock = [Func[double]] { ((Get-Date) - $caseStart).TotalSeconds }
$hostWindow = New-Object MpcTest.ApiHostWindow -ArgumentList ([Func[double]] $clock)
$hostHwnd = $hostWindow.Handle
$result.hostHwnd = $hostHwnd.ToInt64()

# The player checks IsWindow on the /slave argument while parsing its command line, so the window
# must already exist -- it does, being created above.
$slaveArgument = '/slave {0}' -f $hostHwnd.ToInt64()
$argumentLine = if ($Clip) { ('"{0}" {1} {2}' -f $Clip, $slaveArgument, $Switches).Trim() } else { "$slaveArgument $Switches".Trim() }
$p = Start-Process -FilePath $Exe -ArgumentList $argumentLine -PassThru
# Open the handle now: a process that exited before anything opened its handle reports $null for ExitCode.
$null = $p.Handle
$result.pid = $p.Id

# Every wait pumps: the player's notifications are blocking SendMessage calls to the host window,
# delivered only while this thread dispatches messages. A plain Start-Sleep would stall the player.
function Wait-ApiPump {
    param([double] $UntilSec)
    while (((Get-Date) - $caseStart).TotalSeconds -lt $UntilSec -and -not $p.HasExited) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 5
    }
}

# CMD_CONNECT: the payload is the player's main window handle, decimal -- where commands go.
$playerHwnd = [IntPtr]::Zero
$connect = $null
$connectDeadline = ((Get-Date) - $caseStart).TotalSeconds + 20
while (-not $connect -and ((Get-Date) - $caseStart).TotalSeconds -lt $connectDeadline -and -not $p.HasExited) {
    [System.Windows.Forms.Application]::DoEvents()
    $connect = @($hostWindow.Received | Where-Object { $_.Code -eq [long] $apiCommands['CMD_CONNECT'] }) | Select-Object -First 1
    if (-not $connect) { Start-Sleep -Milliseconds 10 }
}
if ($connect) {
    $playerHwnd = [IntPtr] [long] $connect.Payload
    $result.connect = [ordered]@{ at = [math]::Round($connect.At, 3); playerHwnd = $playerHwnd.ToInt64() }
} else {
    $result.connect = $null
}

# The case's commands, in time order. Each is <seconds>:<CMD name or number>:<payload>; the split
# stops at the third field so a payload may hold colons (a path does).
$steps = @()
foreach ($encoded in ($Commands -split ',')) {
    if (-not $encoded) { continue }
    $entry = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded))
    $parts = $entry -split ':', 3
    $code = $null
    if ($apiCommands.Contains($parts[1])) { $code = [long] $apiCommands[$parts[1]] }
    elseif ($parts[1] -match '^0[xX][0-9a-fA-F]+$') { $code = [Convert]::ToInt64($parts[1].Substring(2), 16) }
    elseif ($parts[1] -match '^\d+$') { $code = [long] $parts[1] }
    $steps += [pscustomobject]@{
        at = [double]::Parse($parts[0], [Globalization.CultureInfo]::InvariantCulture)
        name = $parts[1]
        code = $code
        payload = if ($parts.Count -gt 2) { $parts[2] } else { '' }
    }
}
$steps = @($steps | Sort-Object at)

$sent = @()
foreach ($step in $steps) {
    Wait-ApiPump $step.at
    if ($p.HasExited) { break }
    $answered = $false
    if ($null -ne $step.code -and $playerHwnd -ne [IntPtr]::Zero) {
        $answered = [MpcTest.ApiCopyData]::Send($playerHwnd, $hostHwnd, $step.code, $step.payload) -ne 0
    }
    $sent += [ordered]@{
        at = $step.at
        cmd = $step.name
        code = if ($null -ne $step.code) { '0x{0:X8}' -f $step.code } else { $null }
        payload = $step.payload
        delivered = [bool] $answered
    }
}
$result.sent = $sent

# Close as a controlling application would: CMD_CLOSEAPP, which posts WM_CLOSE to the player's
# frame, so the player's own shutdown runs. With no close time given, two seconds after the last
# command. With no connected player there is nothing to send it to; the kill below ends the run.
$closeAt = $CloseAtSec
if ($closeAt -le 0) { $closeAt = $(if ($steps.Count) { $steps[-1].at } else { 2 }) + 2 }
Wait-ApiPump $closeAt
if (-not $p.HasExited -and $playerHwnd -ne [IntPtr]::Zero) {
    $result.closeSent = [MpcTest.ApiCopyData]::Send($playerHwnd, $hostHwnd, [long] $apiCommands['CMD_CLOSEAPP'], '') -ne 0
} else {
    $result.closeSent = $false
}

# The exit wait pumps too: the player's CMD_DISCONNECT on the way out is another blocking
# SendMessage to the host window.
$exitDeadline = ((Get-Date) - $caseStart).TotalSeconds + $TimeoutSec
while (-not $p.HasExited -and ((Get-Date) - $caseStart).TotalSeconds -lt $exitDeadline) {
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 50
}
$result.timedOut = -not $p.HasExited
if ($result.timedOut) {
    # A player that never exits is a finding in itself; do not leave it holding the audio device.
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    $result.exitCode = $null
} else {
    $result.exitCode = $p.ExitCode
}

$hostWindow.DestroyHandle()

Start-Sleep -Seconds 3      # the audio driver writes its capture from a work item after the stream closes

$result.replies = @($hostWindow.Received | ForEach-Object {
    [ordered]@{
        at = [math]::Round($_.At, 3)
        cmd = if ($apiNames.Contains([long] $_.Code)) { $apiNames[[long] $_.Code] } else { '0x{0:X8}' -f $_.Code }
        code = '0x{0:X8}' -f $_.Code
        payload = $_.Payload
    }
})
$result.finished = (Get-Date).ToString('o')
$result | ConvertTo-Json -Depth 4 | Set-Content $Out
