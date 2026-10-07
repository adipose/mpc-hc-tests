# Runs on the target, in the console session (the player needs a desktop). Starts the player with the given
# arguments, optionally captures the virtual monitor part-way through, optionally posts WM_COMMAND messages to
# the player's window at given times, optionally probes the player's playlist list control and main toolbar at
# given times, waits for the player to exit by itself, and kills it if it does not.
# Writes one JSON object to -Out; the host does the asserting.
param(
    [Parameter(Mandatory)] [string] $Exe,
    [string] $ArgumentLine = '',
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
    [string] $SecondArgumentLine = '',   # base64 of a UTF-8 command line: at SecondAtSec launch one more instance
                                         # of the exe with it (quoting would not survive the hand-built task line);
                                         # several, comma-separated, are launched SecondIntervalMs apart
    [double] $SecondAtSec = 2,
    [int] $SecondIntervalMs = 300,
    [string] $PostCommands = '',         # comma-separated <seconds>:<command id>: a WM_COMMAND posted to the
                                         # player's main window at that time after start, as a menu accelerator
                                         # the user pressed (digits, dots and colons only, so it survives the
                                         # hand-built task line unencoded)
    [string] $ProbeAt = '',              # comma-separated seconds after start: at each, read the player's
                                         # playlist list control from outside (count, selection, scroll
                                         # position, scrollbars) and the main toolbar's buttons (command ids
                                         # in order) and record them under "probes" in the JSON
                                         # (digits, dots and commas only, like PostCommands)
    [double] $CaptureAtSec = 0,          # 0 = no frame capture
    [int] $CaptureConnector = 0,
    [string] $CapturePath = '',
    [string] $RendererFile = ''          # json of renderer settings to apply for this case, and put back after
)

$ErrorActionPreference = 'Continue'
$result = [ordered]@{ started = (Get-Date).ToString('o') }

if ($CloseKind -eq 'SC_CLOSE' -or $PostCommands -or $ProbeAt) {
    # The title-bar X posts WM_SYSCOMMAND/SC_CLOSE to the window, not WM_CLOSE; the player has handled it on its
    # own path since e21c9fcfff, so both ways of closing belong under test. The posted commands are WM_COMMAND,
    # the same message a menu accelerator sends. The playlist probe sends the list control plain integer
    # list-view messages, which are safe cross-process (no pointers, no structs); the toolbar probe's
    # TB_GETBUTTON writes a TBBUTTON, which is what the memory APIs below are for.
    Add-Type -Namespace MpcTest -Name User32 -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern bool PostMessageW(System.IntPtr hWnd, uint msg, System.IntPtr wParam, System.IntPtr lParam);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern System.IntPtr SendMessageW(System.IntPtr hWnd, uint msg, System.IntPtr wParam, System.IntPtr lParam);
public delegate bool EnumWindowsProc(System.IntPtr hWnd, System.IntPtr lParam);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool EnumWindows(EnumWindowsProc callback, System.IntPtr lParam);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool EnumChildWindows(System.IntPtr hWndParent, EnumWindowsProc callback, System.IntPtr lParam);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern uint GetWindowThreadProcessId(System.IntPtr hWnd, out uint processId);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetClassNameW(System.IntPtr hWnd, System.Text.StringBuilder className, int maxCount);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetWindowTextW(System.IntPtr hWnd, System.Text.StringBuilder text, int maxCount);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool IsWindowVisible(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern System.IntPtr GetParent(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
public static extern System.IntPtr GetWindowLongPtrW(System.IntPtr hWnd, int index);
'@
}

if ($ProbeAt) {
    # The toolbar probe reads TBBUTTONs out of the player: TB_GETBUTTON's lParam is a pointer, so the
    # struct lives in the player's address space for the call and comes back over ReadProcessMemory,
    # the same approach as the mouse suite's Run-PlaylistInputCase.guest.ps1.
    Add-Type -Namespace MpcTest -Name Kernel32 -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern System.IntPtr OpenProcess(uint access, bool inherit, uint processId);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern System.IntPtr VirtualAllocEx(System.IntPtr process, System.IntPtr address, System.UIntPtr size, uint type, uint protect);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern bool VirtualFreeEx(System.IntPtr process, System.IntPtr address, System.UIntPtr size, uint type);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern bool ReadProcessMemory(System.IntPtr process, System.IntPtr address, byte[] buffer, System.UIntPtr size, out System.UIntPtr read);
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern bool CloseHandle(System.IntPtr handle);
'@
}

# The playlist's list control, found from outside the player. The player has several SysListView32 windows
# (the Subresync bar keeps one too), so a candidate is the playlist's only if its parent chain includes a
# window titled "Playlist": CPlayerPlaylistBar::Create passes ResStr(IDS_PLAYLIST_CAPTION) as the bar's
# window name, and the floating mini-frame carries the same caption. Docked or floating decides where the
# list sits, so the search starts from every top-level window of the player's process and walks down.
function Find-PlaylistListView {
    param([int] $ProcessId)
    $candidates = [System.Collections.Generic.List[IntPtr]]::new()
    $childCallback = [MpcTest.User32+EnumWindowsProc] {
        param($hWnd, $lParam)
        $className = [Text.StringBuilder]::new(64)
        [void] [MpcTest.User32]::GetClassNameW($hWnd, $className, $className.Capacity)
        if ($className.ToString() -eq 'SysListView32') { $candidates.Add($hWnd) }
        return $true
    }
    $topCallback = [MpcTest.User32+EnumWindowsProc] {
        param($hWnd, $lParam)
        $procId = [uint32] 0
        [void] [MpcTest.User32]::GetWindowThreadProcessId($hWnd, [ref] $procId)
        if ($procId -eq $ProcessId) { [void] [MpcTest.User32]::EnumChildWindows($hWnd, $childCallback, [IntPtr]::Zero) }
        return $true
    }
    [void] [MpcTest.User32]::EnumWindows($topCallback, [IntPtr]::Zero)
    foreach ($candidate in $candidates) {
        $walk = $candidate
        while ($walk -ne [IntPtr]::Zero) {
            $title = [Text.StringBuilder]::new(256)
            [void] [MpcTest.User32]::GetWindowTextW($walk, $title, $title.Capacity)
            if ($title.ToString() -eq 'Playlist') { return $candidate }
            $walk = [MpcTest.User32]::GetParent($walk)
        }
    }
    # No parent chain titled Playlist: a sole candidate can only be the playlist's list.
    if ($candidates.Count -eq 1) { return $candidates[0] }
    [IntPtr]::Zero
}

# The command id of one button of a toolbar in the player's process. TB_GETBUTTON (WM_USER + 23) writes
# a TBBUTTON at its lParam -- on x64 iBitmap int @0, idCommand int @4, fsState @8, fsStyle @9, six
# reserved bytes, dwData @16, iString @24, 32 bytes in all (CommCtrl.h) -- so the struct lives in the
# player's address space for the call and the id is read back from offset 4.
function Get-RemoteToolbarButtonId {
    param([IntPtr] $Toolbar, [int] $Index, [IntPtr] $ProcessHandle, [IntPtr] $RemoteBuffer)
    [void] [MpcTest.User32]::SendMessageW($Toolbar, 0x0417, [IntPtr] $Index, $RemoteBuffer)   # TB_GETBUTTON
    $out = New-Object byte[] 32
    $read = [UIntPtr]::Zero
    [void] [MpcTest.Kernel32]::ReadProcessMemory($ProcessHandle, $RemoteBuffer, $out, ([UIntPtr]::new([uint64]32)), [ref] $read)
    [BitConverter]::ToInt32($out, 4)
}

# The player toolbar, found from outside the player. CPlayerToolBar is a CToolBar, so its window class
# is ToolbarWindow32 and other windows of that class may exist in the process; a candidate is the
# player toolbar when its first button is ID_LEFTSEPARATOR (957) -- PlaceButtons adds it before
# anything else, whichever layout branch runs, and no other toolbar has it.
function Find-PlayerToolbar {
    param([int] $ProcessId, [IntPtr] $ProcessHandle, [IntPtr] $RemoteBuffer)
    $candidates = [System.Collections.Generic.List[IntPtr]]::new()
    $childCallback = [MpcTest.User32+EnumWindowsProc] {
        param($hWnd, $lParam)
        $className = [Text.StringBuilder]::new(64)
        [void] [MpcTest.User32]::GetClassNameW($hWnd, $className, $className.Capacity)
        if ($className.ToString() -eq 'ToolbarWindow32') { $candidates.Add($hWnd) }
        return $true
    }
    $topCallback = [MpcTest.User32+EnumWindowsProc] {
        param($hWnd, $lParam)
        $procId = [uint32] 0
        [void] [MpcTest.User32]::GetWindowThreadProcessId($hWnd, [ref] $procId)
        if ($procId -eq $ProcessId) { [void] [MpcTest.User32]::EnumChildWindows($hWnd, $childCallback, [IntPtr]::Zero) }
        return $true
    }
    [void] [MpcTest.User32]::EnumWindows($topCallback, [IntPtr]::Zero)
    foreach ($candidate in $candidates) {
        if ((Get-RemoteToolbarButtonId $candidate 0 $ProcessHandle $RemoteBuffer) -eq 957) { return $candidate }   # ID_LEFTSEPARATOR
    }
    # No candidate starts with the left separator: a sole ToolbarWindow32 can only be the player toolbar.
    if ($candidates.Count -eq 1) { return $candidates[0] }
    [IntPtr]::Zero
}

# One probe of the playlist's list control: LVM_GETITEMCOUNT, LVM_GETNEXTITEM (first selected, first
# focused), LVM_GETTOPINDEX, LVM_GETCOUNTPERPAGE, visibility and the scrollbar style bits. A list view
# sets WS_HSCROLL/WS_VSCROLL while the scrollbar is shown, so the style says whether one is there.
# Also one probe of the player toolbar: TB_BUTTONCOUNT (WM_USER + 24) and, per button, the idCommand
# of its TBBUTTON, recorded as toolbarIds in button order.
function Get-PlaylistProbe {
    param([double] $At, [int] $ProcessId)
    $h = Find-PlaylistListView $ProcessId
    $probe = [ordered]@{ at = $At; found = ($h -ne [IntPtr]::Zero) }
    if ($h -ne [IntPtr]::Zero) {
        $probe.count    = [MpcTest.User32]::SendMessageW($h, 0x1004, [IntPtr]::Zero, [IntPtr]::Zero).ToInt32()         # LVM_GETITEMCOUNT
        $probe.selected = [MpcTest.User32]::SendMessageW($h, 0x100C, [IntPtr]::new(-1), [IntPtr]::new(2)).ToInt32()  # LVM_GETNEXTITEM, LVNI_SELECTED
        $probe.focused  = [MpcTest.User32]::SendMessageW($h, 0x100C, [IntPtr]::new(-1), [IntPtr]::new(1)).ToInt32()  # LVM_GETNEXTITEM, LVNI_FOCUSED
        $probe.top      = [MpcTest.User32]::SendMessageW($h, 0x1027, [IntPtr]::Zero, [IntPtr]::Zero).ToInt32()       # LVM_GETTOPINDEX
        $probe.perPage  = [MpcTest.User32]::SendMessageW($h, 0x1028, [IntPtr]::Zero, [IntPtr]::Zero).ToInt32()       # LVM_GETCOUNTPERPAGE
        $probe.visible  = [MpcTest.User32]::IsWindowVisible($h)
        $style = [MpcTest.User32]::GetWindowLongPtrW($h, -16).ToInt64()                                              # GWL_STYLE
        $probe.hscroll  = [bool] ($style -band 0x00100000)                                                           # WS_HSCROLL
        $probe.vscroll  = [bool] ($style -band 0x00200000)                                                           # WS_VSCROLL
    }
    $probe.toolbarIds = $null
    $hProc = [MpcTest.Kernel32]::OpenProcess(0x0438, $false, [uint32] $ProcessId)   # VM_OPERATION|VM_READ|VM_WRITE|QUERY_INFORMATION
    if ($hProc -ne [IntPtr]::Zero) {
        try {
            $mem = [MpcTest.Kernel32]::VirtualAllocEx($hProc, [IntPtr]::Zero, ([UIntPtr]::new([uint64]32)), 0x1000, 0x04)   # MEM_COMMIT, PAGE_READWRITE
            if ($mem -ne [IntPtr]::Zero) {
                try {
                    $toolbar = Find-PlayerToolbar $ProcessId $hProc $mem
                    if ($toolbar -ne [IntPtr]::Zero) {
                        $buttons = [MpcTest.User32]::SendMessageW($toolbar, 0x0418, [IntPtr]::Zero, [IntPtr]::Zero).ToInt32()   # TB_BUTTONCOUNT
                        $probe.toolbarIds = @(for ($i = 0; $i -lt $buttons; $i++) { Get-RemoteToolbarButtonId $toolbar $i $hProc $mem })
                    }
                } finally {
                    [void] [MpcTest.Kernel32]::VirtualFreeEx($hProc, $mem, [UIntPtr]::Zero, 0x8000)   # MEM_RELEASE
                }
            }
        } finally {
            [void] [MpcTest.Kernel32]::CloseHandle($hProc)
        }
    }
    $probe
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

# An empty line is a launch with no file at all (a case about what the player restores by itself), and
# Start-Process refuses an empty -ArgumentList.
$p = if ($ArgumentLine) { Start-Process -FilePath $Exe -ArgumentList $ArgumentLine -PassThru } else { Start-Process -FilePath $Exe -PassThru }
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

if ($SecondArgumentLine) {
    # One more instance of the same exe with its own command line: with AllowMultipleInstances=0 it hands the
    # line to the running player over WM_COPYDATA and exits. What the player does with it (/add, a start
    # position, a multi-file open) is what the case is about; how the instance exits is part of the result.
    # Several lines arrive as one selection when they are closer together than the player's redirect threshold,
    # which is how Explorer hands over a multi-file open: one instance per file.
    $elapsed = ((Get-Date) - [datetime]$result.started).TotalSeconds
    if ($SecondAtSec -gt $elapsed) { Start-Sleep -Milliseconds ([int](($SecondAtSec - $elapsed) * 1000)) }
    $seconds = @()
    foreach ($encoded in ($SecondArgumentLine -split ',')) {
        if ($seconds.Count) { Start-Sleep -Milliseconds $SecondIntervalMs }
        $line = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded))
        $inst = Start-Process -FilePath $Exe -ArgumentList $line -PassThru
        # Open the handle now: a process that exited before anything opened its handle reports $null for ExitCode.
        $null = $inst.Handle
        $seconds += $inst
    }
    $result.secondExited = $true
    $result.secondExitCode = 0
    foreach ($inst in $seconds) {
        $exited = if ($inst.HasExited) { $true } else { $inst.WaitForExit(10000) }
        if (-not $exited) { $result.secondExited = $false; $result.secondExitCode = $null }
        elseif ($result.secondExitCode -eq 0 -and $inst.ExitCode -ne 0) { $result.secondExitCode = $inst.ExitCode }
    }
}

if ($PostCommands -or $ProbeAt) {
    # Posts and probes are one time-ordered sequence; at the same second the post goes first, so a probe can
    # observe what its command did. Delivered (for a post) means a main window existed and PostMessageW
    # accepted the message; MFC still drops a command whose ON_UPDATE_COMMAND_UI reports it disabled, which
    # is why cases post only once playback is underway.
    # Events are pscustomobjects, not ordered dictionaries: in Windows PowerShell 5.1 (which this task
    # runs under) Sort-Object does not sort dictionaries by key - it leaves them in insertion order.
    $events = @()
    if ($PostCommands) {
        foreach ($entry in ($PostCommands -split ',')) {
            $parts = $entry -split ':'
            $events += [pscustomobject]@{ at = [double]::Parse($parts[0], [Globalization.CultureInfo]::InvariantCulture); id = [int] $parts[1]; probe = $false }
        }
    }
    if ($ProbeAt) {
        foreach ($entry in ($ProbeAt -split ',')) {
            $events += [pscustomobject]@{ at = [double]::Parse($entry, [Globalization.CultureInfo]::InvariantCulture); id = 0; probe = $true }
        }
    }
    $posts = @()
    $probes = @()
    foreach ($step in ($events | Sort-Object at, probe)) {
        $elapsed = ((Get-Date) - [datetime]$result.started).TotalSeconds
        if ($step.at -gt $elapsed) { Start-Sleep -Milliseconds ([int](($step.at - $elapsed) * 1000)) }
        if ($step.probe) {
            $probes += Get-PlaylistProbe $step.at $p.Id
        } else {
            $p.Refresh()
            $delivered = (-not $p.HasExited) -and ($p.MainWindowHandle -ne [IntPtr]::Zero) -and
                         [MpcTest.User32]::PostMessageW($p.MainWindowHandle, 0x0111, [IntPtr] $step.id, [IntPtr]::Zero)
            $posts += [ordered]@{ at = $step.at; id = $step.id; delivered = [bool] $delivered }
        }
    }
    if ($PostCommands) { $result.posts = $posts }
    if ($ProbeAt) { $result.probes = $probes }
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
