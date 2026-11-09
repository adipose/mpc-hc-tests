# Runs on the target, in the console session. Live television never ends, so unlike a file case the player is
# given a fixed time on air and then closed. Optionally captures the virtual monitor while it is tuned.
# Writes one JSON object to -Out; the host does the asserting.
param(
    [Parameter(Mandatory)] [string] $Exe,
    [Parameter(Mandatory)] [string] $ArgumentLine,
    [Parameter(Mandatory)] [string] $Out,
    [int] $OnAirSec = 12,
    [int] $ExitTimeoutSec = 600,        # for runs that end by themselves (a headless scan)
    [switch] $WaitForExit,
    [double] $CaptureAtSec = 0,
    [int] $CaptureConnector = 0,
    [string] $CapturePath = '',
    # Drive the running player: post this WM_COMMAND id to its main window at PostCommandAtSec, reading the
    # window title just before and again at the end of the time on air.
    [double] $PostCommandAtSec = 0,
    [int] $PostCommandId = 0
)

function Get-PlayerTitle {
    param($Process)
    $Process.Refresh()
    [pscustomobject]@{ Hwnd = [int64]$Process.MainWindowHandle; Title = $Process.MainWindowTitle }
}

$ErrorActionPreference = 'Continue'
$result = [ordered]@{ started = (Get-Date).ToString('o'); args = $ArgumentLine }

$p = Start-Process -FilePath $Exe -ArgumentList $ArgumentLine -PassThru
$result.pid = $p.Id

if ($WaitForExit) {
    $result.timedOut = -not $p.WaitForExit($ExitTimeoutSec * 1000)
    if ($result.timedOut) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } else { $result.exitCode = $p.ExitCode }
}
else {
    if ($CaptureAtSec -gt 0 -and $CaptureAtSec -lt $OnAirSec) {
        Start-Sleep -Milliseconds ([int]($CaptureAtSec * 1000))
        $result.aliveAtCapture = -not $p.HasExited
        $result.capture = (& 'C:\vdisplay\vdisplayctl.exe' capture $CaptureConnector $CapturePath | Out-String).Trim()
        Start-Sleep -Milliseconds ([int](($OnAirSec - $CaptureAtSec) * 1000))
    } elseif ($PostCommandId -and $PostCommandAtSec -gt 0 -and $PostCommandAtSec -lt $OnAirSec) {
        Add-Type -Namespace MpcTest -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
'@
        Start-Sleep -Milliseconds ([int]($PostCommandAtSec * 1000))
        $before = Get-PlayerTitle $p
        $result.titleBefore = $before.Title
        # 0x0111 = WM_COMMAND. A command whose ON_UPDATE_COMMAND_UI reports it disabled is dropped silently, so the
        # caller judges the effect, not this return value.
        $result.posted = [MpcTest.Win]::PostMessage([IntPtr]$before.Hwnd, 0x0111, [IntPtr]$PostCommandId, [IntPtr]::Zero)
        Start-Sleep -Milliseconds ([int](($OnAirSec - $PostCommandAtSec) * 1000))
        $result.titleAfter = (Get-PlayerTitle $p).Title
    } else {
        Start-Sleep -Seconds $OnAirSec
    }
    # Still running is the healthy outcome here; having gone away by itself is a crash or a refusal to tune.
    $result.aliveAtEnd = -not $p.HasExited
    if ($p.HasExited) { $result.exitCode = $p.ExitCode }
    else {
        # Ask politely first, so the player shuts its graph down and the audio device sees a clean stop.
        [void]$p.CloseMainWindow()
        $result.closedGracefully = $p.WaitForExit(15000)
        if (-not $result.closedGracefully) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
        else { $result.exitCode = $p.ExitCode }
    }
}

Start-Sleep -Seconds 3      # the audio driver writes its capture from a work item after the stream closes
$result.finished = (Get-Date).ToString('o')
$result | ConvertTo-Json -Depth 4 | Set-Content $Out
