# Runs on the target, in the console session (the player needs a desktop). Starts the player with the given
# arguments, optionally captures the virtual monitor part-way through, waits for the player to exit by itself, and
# kills it if it does not. Writes one JSON object to -Out; the host does the asserting.
param(
    [Parameter(Mandatory)] [string] $Exe,
    [Parameter(Mandatory)] [string] $ArgumentLine,
    [Parameter(Mandatory)] [string] $Out,
    [int] $TimeoutSec = 40,
    [double] $CloseAtSec = 0,            # 0 = the player exits by itself (/close); else a close to its window at this time
    [ValidateSet('WM_CLOSE', 'SC_CLOSE')] [string] $CloseKind = 'WM_CLOSE',   # SC_CLOSE is the title-bar X
    [switch] $CloseWhenWindowAppears,    # close the moment a main window exists, while the file is still being opened
    [int] $CloseRepeat = 1,              # send the close this many times, 50 ms apart (a user clicking X twice on a hang)
    [int] $RedirectStorm = 0,            # launch this many further instances mid-playback; with one instance allowed each redirects into the first
    [string[]] $RedirectFiles = @(),     # the files they carry, in rotation (a comma-joined string is accepted too)
    [double] $StormAtSec = 2,
    [int] $StormIntervalMs = 150,
    [double] $CaptureAtSec = 0,          # 0 = no frame capture
    [int] $CaptureConnector = 0,
    [string] $CapturePath = '',
    [string] $RendererFile = ''          # json of renderer settings to apply for this case, and put back after
)

$ErrorActionPreference = 'Continue'
$result = [ordered]@{ started = (Get-Date).ToString('o') }

if ($CloseKind -eq 'SC_CLOSE') {
    # The title-bar X posts WM_SYSCOMMAND/SC_CLOSE to the window, not WM_CLOSE; the player has handled it on its
    # own path since e21c9fcfff, so both ways of closing belong under test.
    Add-Type -Namespace MpcTest -Name User32 -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern bool PostMessageW(System.IntPtr hWnd, uint msg, System.IntPtr wParam, System.IntPtr lParam);
'@
}

function Send-Close {
    param($Process, [string] $Kind)
    if ($Kind -eq 'SC_CLOSE') {
        $Process.Refresh()
        if ($Process.HasExited -or $Process.MainWindowHandle -eq [IntPtr]::Zero) { return $false }
        return [MpcTest.User32]::PostMessageW($Process.MainWindowHandle, 0x0112, [IntPtr]0xF060, [IntPtr]::Zero)
    }
    return (-not $Process.HasExited) -and $Process.CloseMainWindow()
}

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

if ($RedirectStorm -gt 0) {
    # With AllowMultipleInstances=0 each further instance hands its file to the running player over WM_COPYDATA
    # and exits, and the running player closes what it has and opens the new file: the redirect path, at speed.
    $stormFiles = @($RedirectFiles | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
    $elapsed = ((Get-Date) - [datetime]$result.started).TotalSeconds
    if ($StormAtSec -gt $elapsed) { Start-Sleep -Milliseconds ([int](($StormAtSec - $elapsed) * 1000)) }
    $instances = @()
    for ($i = 0; $i -lt $RedirectStorm; $i++) {
        if ($i -gt 0) { Start-Sleep -Milliseconds $StormIntervalMs }
        $inst = Start-Process -FilePath $Exe -ArgumentList ('"{0}"' -f $stormFiles[$i % $stormFiles.Count]) -PassThru
        # Open the handle now: a process that exited before anything opened its handle reports $null for ExitCode.
        $null = $inst.Handle
        $instances += @{ proc = $inst; launchedAt = Get-Date }
    }
    Start-Sleep -Seconds 2
    $processName = [IO.Path]::GetFileNameWithoutExtension($Exe)
    $result.processesAfterStorm = @(Get-Process $processName -ErrorAction SilentlyContinue).Count
    $result.firstAliveAfterStorm = -not $p.HasExited
    $result.redirects = @($instances | ForEach-Object {
        # Each instance gets 10 s from its own launch, not from here, so 30 hung ones cannot stack past the host timeout.
        $remainingMs = [math]::Max(0, [int](10000 - ((Get-Date) - $_.launchedAt).TotalMilliseconds))
        $exited = if ($_.proc.HasExited) { $true } else { $_.proc.WaitForExit($remainingMs) }
        @{ exited = $exited; exitCode = if ($exited) { $_.proc.ExitCode } else { $null } }
    })
}

$closeWatch = $null
$closeNow = $false
if ($CloseWhenWindowAppears) {
    # Close while the file is still being opened: poll for a main window and send the moment there is one.
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        $p.Refresh()
        if ($p.HasExited) { break }
        if ($p.MainWindowHandle -ne [IntPtr]::Zero) {
            $result.windowAt = ((Get-Date) - [datetime]$result.started).TotalSeconds
            break
        }
        Start-Sleep -Milliseconds 20
    }
    $closeNow = $true
} elseif ($CloseAtSec -gt 0) {
    $elapsed = ((Get-Date) - [datetime]$result.started).TotalSeconds
    if ($CloseAtSec -gt $elapsed) { Start-Sleep -Milliseconds ([int](($CloseAtSec - $elapsed) * 1000)) }
    $closeNow = $true
}

if ($closeNow) {
    # As the user closing the window: the player's own shutdown runs, which is what writes the last position.
    # A repeat is a second click on X while the first one seems to have hung the player.
    $closeWatch = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt $CloseRepeat; $i++) {
        if ($i -gt 0) { Start-Sleep -Milliseconds 50 }
        $sent = Send-Close $p $CloseKind
        if ($i -eq 0) { $result.closeSent = [bool]$sent }
    }
    $result.closedAt = (Get-Date).ToString('o')
}

$result.closeToExitSec = $null
$result.timedOut = -not $p.WaitForExit($TimeoutSec * 1000)
if (-not $result.timedOut -and $closeWatch) {
    # How long the player's own shutdown took once the close was in its queue; a freeze on that path is a finding.
    $result.closeToExitSec = [math]::Round($closeWatch.Elapsed.TotalSeconds, 3)
}
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
