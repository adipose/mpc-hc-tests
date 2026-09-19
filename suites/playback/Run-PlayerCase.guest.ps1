# Runs on the target, in the console session (the player needs a desktop). Starts the player with the given
# arguments, optionally captures the virtual monitor part-way through, waits for the player to exit by itself, and
# kills it if it does not. Writes one JSON object to -Out; the host does the asserting.
param(
    [Parameter(Mandatory)] [string] $Exe,
    [Parameter(Mandatory)] [string] $ArgumentLine,
    [Parameter(Mandatory)] [string] $Out,
    [int] $TimeoutSec = 40,
    [double] $CloseAtSec = 0,            # 0 = the player exits by itself (/close); else WM_CLOSE to it at this time
    [double] $CaptureAtSec = 0,          # 0 = no frame capture
    [int] $CaptureConnector = 0,
    [string] $CapturePath = ''
)

$ErrorActionPreference = 'Continue'
$result = [ordered]@{ started = (Get-Date).ToString('o') }

$p = Start-Process -FilePath $Exe -ArgumentList $ArgumentLine -PassThru
$result.pid = $p.Id

if ($CaptureAtSec -gt 0) {
    Start-Sleep -Milliseconds ([int]($CaptureAtSec * 1000))
    $result.aliveAtCapture = -not $p.HasExited
    $result.capture = (& 'C:\vdisplay\vdisplayctl.exe' capture $CaptureConnector $CapturePath | Out-String).Trim()
    $result.captureExit = $LASTEXITCODE
}

if ($CloseAtSec -gt 0) {
    # As the user closing the window: the player's own shutdown runs, which is what writes the last position.
    $elapsed = ((Get-Date) - [datetime]$result.started).TotalSeconds
    if ($CloseAtSec -gt $elapsed) { Start-Sleep -Milliseconds ([int](($CloseAtSec - $elapsed) * 1000)) }
    $result.closeSent = -not $p.HasExited -and $p.CloseMainWindow()
    $result.closedAt = (Get-Date).ToString('o')
}

$result.timedOut = -not $p.WaitForExit($TimeoutSec * 1000)
if ($result.timedOut) {
    # A player that never exits is a finding in itself; do not leave it holding the audio device and the file.
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    $result.exitCode = $null
} else {
    $result.exitCode = $p.ExitCode
}

Start-Sleep -Seconds 3      # the audio driver writes its capture from a work item after the stream closes
$result.finished = (Get-Date).ToString('o')
$result | ConvertTo-Json -Depth 4 | Set-Content $Out
