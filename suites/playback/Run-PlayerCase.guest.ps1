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
    [string] $CapturePath = '',
    [string] $RendererFile = ''          # json of renderer settings to apply for this case, and put back after
)

$ErrorActionPreference = 'Continue'
$result = [ordered]@{ started = (Get-Date).ToString('o') }

# MPC Video Renderer keeps its settings in the registry rather than in the player's ini, and under
# the user that runs the player -- which is this process, not the host's session. Apply them here,
# and put back exactly what was there, whatever happens later in the script.
$rendererKey = 'HKCU:\Software\MPC-BE Filters\MPC Video Renderer'
$rendererSaved = @{}
$rendererNames = @()
$rendererExisted = Test-Path $rendererKey
if ($RendererFile -and (Test-Path $RendererFile)) {
    $wanted = Get-Content $RendererFile -Raw | ConvertFrom-Json
    if (-not $rendererExisted) { New-Item -Path $rendererKey -Force | Out-Null }
    foreach ($p in $wanted.PSObject.Properties) {
        $rendererNames += $p.Name
        $was = (Get-ItemProperty -Path $rendererKey -Name $p.Name -ErrorAction SilentlyContinue).($p.Name)
        if ($null -ne $was) { $rendererSaved[$p.Name] = $was }
        Set-ItemProperty -Path $rendererKey -Name $p.Name -Value ([int]$p.Value) -Type DWord
    }
    $result.renderer = ($wanted.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ' '
}

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

if ($rendererNames.Count) {
    foreach ($n in $rendererNames) {
        if ($rendererSaved.ContainsKey($n)) { Set-ItemProperty -Path $rendererKey -Name $n -Value ([int]$rendererSaved[$n]) -Type DWord }
        else { Remove-ItemProperty -Path $rendererKey -Name $n -ErrorAction SilentlyContinue }
    }
    if (-not $rendererExisted) { Remove-Item $rendererKey -Recurse -Force -ErrorAction SilentlyContinue }
}

$result.finished = (Get-Date).ToString('o')
$result | ConvertTo-Json -Depth 4 | Set-Content $Out
