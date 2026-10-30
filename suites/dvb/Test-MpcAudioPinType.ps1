<#
.SYNOPSIS
    After a running-graph audio switch to an ADTS track, the demultiplexer's
    "adts" pin must be connected as ADTS.

.DESCRIPTION
    CFGManagerBDA::SwitchStream retypes the demultiplexer's output pin before
    it reconnects the audio path. That retype only runs while the graph is
    running, so this stamps the settings that keep it running:

      StopFilterGraph=1     the default, 2 (always), stops the graph first and
                            skips the retype altogether
      RebuildFilterGraph=1  keeps a pin for every audio type in the graph
      EnableAudioSwitcher=0 with the switcher, the Audio menu selects among the
                            switcher's inputs and never reaches
                            CFGManagerBDA::Enable

    It serves the matrix stream multi-audio-multi-sub (MPEG audio default, plus
    AC-3 and AAC-ADTS) on a frequency of its own, scans it, tunes it and selects
    the ADTS track through the Audio menu's command.

    What is asserted is the pin's own connection media type, read from the Pin
    Info page MPC-HC shows for the filter (Play > Filters), so the player under
    test needs no instrumentation. Nothing is listed by name there across
    processes, so the driver opens each filter's page until one lists the pin.

    The stream comes from the emulator's New-MatrixStreams.ps1:

      .\New-MatrixStreams.ps1 -EntryId multi-audio-multi-sub -OutDir <dir>

.PARAMETER PlayerBinary
    Host path of the mpc-hc64.exe to measure.

.PARAMETER StreamPath
    Host path of multi-audio-multi-sub.ts.

.PARAMETER Frequency
    kHz. Must be free in the guest's DVB-T stream map; the mapping is added for
    the run and removed afterwards.

.EXAMPLE
    .\Test-MpcAudioPinType.ps1 -VMName win10-parity-2 `
        -PlayerBinary C:\dev\mpc-hc\bin\mpc-hc_x64\mpc-hc64.exe `
        -StreamPath C:\temp\matrix\multi-audio-multi-sub.ts
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $PlayerBinary,
    [Parameter(Mandatory)][string] $StreamPath,
    [string] $VMName = '',
    [int]    $Frequency = 514000,
    [string] $OutDir = (Join-Path $PSScriptRoot 'results')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$adtsSubtype = '00001600-0000-0010-8000-00AA00389B71'
$latmSubtype = '000001FF-0000-0010-8000-00AA00389B71'

foreach ($p in $PlayerBinary, $StreamPath) {
    if (-not (Test-Path -LiteralPath $p)) { throw "not found: $p" }
}
New-Item -ItemType Directory -Force $OutDir | Out-Null

. (Join-Path $PSScriptRoot '..\..\emulator\tools\RigClaim.ps1')
$claim = Enter-RigClaim -VMName $VMName
$guest = $claim.Guest
$session = Connect-TestGuest -Guest $guest
$consoleUser = (Get-TestBedConfig -Guest $guest).GuestConsoleUser

# Runs in the console session: window messages do not cross sessions.
$driver = @'
param([string] $OutFile)
$ErrorActionPreference = 'Stop'
Add-Type @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class Pin {
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr h, EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr h);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="SendMessageW")] public static extern IntPtr SendString(IntPtr h, uint m, IntPtr w, string l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="SendMessageW")] public static extern IntPtr SendBuffer(IntPtr h, uint m, IntPtr w, StringBuilder l);

  public static string ClassOf(IntPtr h) { var s = new StringBuilder(64); GetClassName(h, s, 64); return s.ToString(); }

  public static List<IntPtr> Dialogs(uint pid) {
    var r = new List<IntPtr>();
    EnumWindows((h, p) => {
      uint o; GetWindowThreadProcessId(h, out o);
      if (o == pid && IsWindowVisible(h) && ClassOf(h) == "#32770") r.Add(h);
      return true;
    }, IntPtr.Zero);
    return r;
  }

  public static List<IntPtr> Children(IntPtr parent, string cls) {
    var r = new List<IntPtr>();
    EnumChildWindows(parent, (h, p) => { if (ClassOf(h) == cls) r.Add(h); return true; }, IntPtr.Zero);
    return r;
  }

  public static string Text(IntPtr h) {
    int n = (int)SendMessage(h, 0x000E, IntPtr.Zero, IntPtr.Zero);   // WM_GETTEXTLENGTH
    var s = new StringBuilder(n + 1);
    SendBuffer(h, 0x000D, new IntPtr(n + 1), s);                     // WM_GETTEXT
    return s.ToString();
  }
}
"@

$WM_CLOSE = 0x0010; $WM_COMMAND = 0x0111
$ID_FILTERS_SUBITEM_START = 2000; $ID_AUDIO_SUBITEM_START = 2200
$CB_SETCURSEL = 0x014E; $CB_FINDSTRINGEXACT = 0x0158; $CBN_SELCHANGE = 1
$PSM_SETCURSEL = 0x0465; $TCM_GETITEMCOUNT = 0x1304

$out = [ordered]@{ started = (Get-Date).ToString('o') }
$player = Get-Process mpc-hc64 | Select-Object -First 1
$main = $player.MainWindowHandle
$procId = [uint32]$player.Id

function Get-Status {
    (Invoke-WebRequest -Uri 'http://127.0.0.1:13579/status.json' -UseBasicParsing -TimeoutSec 10).Content | ConvertFrom-Json
}

function Wait-NewDialog {
    $deadline = (Get-Date).AddSeconds(4)
    do {
        Start-Sleep -Milliseconds 150
        $d = @([Pin]::Dialogs($procId) | Where-Object { [Pin]::Children($_, 'SysTabControl32').Count -gt 0 })
        if ($d.Count) { return $d[0] }
    } while ((Get-Date) -lt $deadline)
    [IntPtr]::Zero
}

function Close-Dialog([IntPtr] $Dialog) {
    [void][Pin]::PostMessage($Dialog, $WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
    $deadline = (Get-Date).AddSeconds(5)
    while ((Get-Date) -lt $deadline -and ([Pin]::Dialogs($procId) -contains $Dialog)) { Start-Sleep -Milliseconds 100 }
}

# Returns the Pin Info text for $PinName, or $null if no filter lists it.
function Read-PinInfo([string] $PinName) {
    $label = "[OUT] $PinName"
    for ($i = 0; $i -lt 32; $i++) {
        [void][Pin]::PostMessage($main, $WM_COMMAND, [IntPtr]($ID_FILTERS_SUBITEM_START + $i), [IntPtr]::Zero)
        $dlg = Wait-NewDialog
        if ($dlg -eq [IntPtr]::Zero) { return $null }   # past the end of the filter list
        try {
            # Pin Info is always the sheet's last page, and it builds its
            # controls when it is first activated.
            $tab = [Pin]::Children($dlg, 'SysTabControl32')[0]
            $pages = [int][Pin]::SendMessage($tab, $TCM_GETITEMCOUNT, [IntPtr]::Zero, [IntPtr]::Zero)
            [void][Pin]::SendMessage($dlg, $PSM_SETCURSEL, [IntPtr]($pages - 1), [IntPtr]::Zero)
            Start-Sleep -Milliseconds 400
            foreach ($combo in [Pin]::Children($dlg, 'ComboBox')) {
                $row = [int][Pin]::SendString($combo, $CB_FINDSTRINGEXACT, [IntPtr](-1), $label)
                if ($row -lt 0) { continue }
                [void][Pin]::SendMessage($combo, $CB_SETCURSEL, [IntPtr]$row, [IntPtr]::Zero)
                $wparam = ([int][Pin]::GetDlgCtrlID($combo)) -bor ($CBN_SELCHANGE -shl 16)
                [void][Pin]::SendMessage([Pin]::GetParent($combo), $WM_COMMAND, [IntPtr]$wparam, $combo)
                Start-Sleep -Milliseconds 300
                $edit = [Pin]::Children($dlg, 'Edit') | Sort-Object { [Pin]::Text($_).Length } | Select-Object -Last 1
                return [Pin]::Text($edit)
            }
        } finally { Close-Dialog $dlg }
    }
    $null
}

try {
    $status = Get-Status
    $out.audioBefore = $status.audio
    # By position, as the matrix declares them (MPEG, AC-3, ADTS): the menu
    # gives this track an empty name.
    $tracks = @($status.audio.tracks)
    if ($tracks.Count -ne 3) { throw "expected 3 audio tracks: $($status.audio | ConvertTo-Json -Compress)" }
    $track = $tracks[2]
    $out.track = $track

    $out.pinInfoBefore = Read-PinInfo 'adts'

    [void][Pin]::PostMessage($main, $WM_COMMAND, [IntPtr][int]$track.id, [IntPtr]::Zero)
    Start-Sleep -Seconds 4

    $out.audioAfter = (Get-Status).audio
    $out.pinInfoAfter = Read-PinInfo 'adts'
} catch {
    $out.error = "$($_.Exception.Message) at $($_.InvocationInfo.ScriptLineNumber)"
}
$out.finished = (Get-Date).ToString('o')
$out | ConvertTo-Json -Depth 6 | Set-Content $OutFile
'@

function Set-ConsoleSettings {
    # The console user's hive, not this session's: see the guest conventions
    # doc. Prior values come back so the case leaves the shared profile as it
    # found it.
    param($Session, [string] $User, [hashtable] $Dvb, [hashtable] $Settings)
    Invoke-Command -Session $Session -ArgumentList $User, $Dvb, $Settings -ScriptBlock {
        param($user, $dvb, $settings)
        $sid = (New-Object System.Security.Principal.NTAccount($user)).Translate(
                   [System.Security.Principal.SecurityIdentifier]).Value
        $root = "Registry::HKEY_USERS\$sid\Software\MPC-HC\MPC-HC"
        $prior = @{ Dvb = @{}; Settings = @{} }
        foreach ($pair in @(@('DVBConfiguration2', $dvb, 'Dvb'), @('Settings', $settings, 'Settings'))) {
            $k = "$root\$($pair[0])"
            if (-not (Test-Path $k)) { New-Item -Path $k | Out-Null }
            foreach ($name in $pair[1].Keys) {
                $v = (Get-ItemProperty $k -Name $name -ErrorAction SilentlyContinue)
                $prior[$pair[2]][$name] = if ($v) { $v.$name } else { $null }
                if ($null -eq $pair[1][$name]) {
                    Remove-ItemProperty $k -Name $name -ErrorAction SilentlyContinue
                } else {
                    Set-ItemProperty $k -Name $name -Value $pair[1][$name] -Type DWord
                }
            }
        }
        $prior
    }
}

$passed = $false
$prior = $null
$mapped = $false
try {
    Assert-RigIdentity -Session $session -Expected $guest | Out-Null

    # --- the DVB-T tuner and the stream -----------------------------------------

    $tuner = Invoke-Command -Session $session -ScriptBlock {
        $cat = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceClasses\{71985f48-1ca1-11d3-9cc8-00c04f7971e0}'
        foreach ($ifaceName in (Get-ChildItem -LiteralPath $cat -Name | Where-Object { $_ -match '#ROOT#MEDIA#' })) {
            foreach ($refName in (Get-ChildItem -LiteralPath "$cat\$ifaceName" -Name | Where-Object { $_ -match '^#\{' })) {
                $friendly = (Get-ItemProperty -LiteralPath "$cat\$ifaceName\$refName\Device Parameters" -Name FriendlyName -ErrorAction SilentlyContinue).FriendlyName
                if ($friendly -and ($friendly -replace '[- ]', '') -match 'DVBT') {
                    return ('@device:pnp:\\?\' + ($ifaceName -replace '^##\?#', '') + '\' + $refName.TrimStart('#')).ToLowerInvariant()
                }
            }
        }
    }
    if (-not $tuner) { throw "no DVB-T tuner on $guest" }
    $instanceKey = "ROOT_MEDIA_$(if ($tuner -match 'media#(\d{4})') { $Matches[1] })"

    Invoke-Command -Session $session { New-Item -ItemType Directory -Force C:\ts\matrix | Out-Null }
    Copy-Item -LiteralPath $StreamPath -Destination 'C:\ts\matrix\multi-audio-multi-sub.ts' -ToSession $session -Force
    Invoke-Command -Session $session -ArgumentList $instanceKey, $Frequency -ScriptBlock {
        param($instance, $freq)
        $k = "HKLM:\SYSTEM\PSWTuner\$instance\Device Parameters\$freq"
        if (Test-Path $k) { throw "frequency $freq is already mapped on this guest" }
        New-Item -Path $k | Out-Null
        Set-ItemProperty $k -Name StreamLocation -Value '\??\C:\ts\matrix\multi-audio-multi-sub.ts' -Type String
        Set-ItemProperty $k -Name FriendlyName   -Value 'multi-audio-multi-sub' -Type String
        Set-ItemProperty $k -Name SignalLocked   -Value 1   -Type DWord
        Set-ItemProperty $k -Name SignalPresent  -Value 1   -Type DWord
        Set-ItemProperty $k -Name SignalQuality  -Value 100 -Type DWord
        Set-ItemProperty $k -Name SignalStrength -Value 63  -Type DWord
    }
    $mapped = $true

    # --- scan, then tune with the settings that keep the graph running ---------

    $common = @{ tuner = $tuner; freqStart = $Frequency; freqEnd = $Frequency; bandwidth = 8000; symbolRate = 0; ignoreEncrypted = 0 }
    $scanJob = $common + @{ label = 'audiopin-scan'; clearChannels = $true; timeoutSec = 60 }
    $scan = & (Join-Path $PSScriptRoot 'Invoke-MpcScan.ps1') -Job $scanJob -VMName $guest -HostBinary $PlayerBinary -WaitSec 180 | ConvertFrom-Json
    if ($scan.PSObject.Properties['error']) { throw "scan failed: $($scan.error)" }
    if (-not @($scan.savedChannels).Count) { throw 'scan saved no channels' }

    $prior = Set-ConsoleSettings -Session $session -User $consoleUser `
        -Dvb @{ StopFilterGraph = 1; RebuildFilterGraph = 1 } -Settings @{ EnableAudioSwitcher = 0 }

    $holdJob = $common + @{ label = 'audiopin-hold'; clearChannels = $false; tuneAndHold = $true; timeoutSec = 60 }
    $hold = & (Join-Path $PSScriptRoot 'Invoke-MpcScan.ps1') -Job $holdJob -VMName $guest -HostBinary $PlayerBinary -WaitSec 120 | ConvertFrom-Json
    Write-Verbose "tuned: $($hold.title)"

    # --- switch the track and read the pin --------------------------------------

    $raw = Invoke-Command -Session $session -ArgumentList $driver, $consoleUser -ScriptBlock {
        param($driver, $user)
        $outFile = 'C:\vtuner\out\audiopin.json'
        Remove-Item $outFile -ErrorAction SilentlyContinue
        Set-Content 'C:\vtuner\audiopin-driver.ps1' -Value $driver -Encoding UTF8
        & schtasks.exe /create /tn VTunerAudioPin /f /sc once /st 00:00 /ru $user /it `
            /tr "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\vtuner\audiopin-driver.ps1 -OutFile $outFile" 2>&1 | Out-Null
        & schtasks.exe /run /tn VTunerAudioPin 2>&1 | Out-Null
        $deadline = (Get-Date).AddSeconds(150)
        while ((Get-Date) -lt $deadline -and -not (Test-Path $outFile)) { Start-Sleep -Seconds 1 }
        Start-Sleep -Seconds 1
        & schtasks.exe /delete /tn VTunerAudioPin /f 2>&1 | Out-Null
        if (Test-Path $outFile) { [IO.File]::ReadAllText($outFile) } else { throw 'the driver wrote no result' }
    }
    Set-Content (Join-Path $OutDir 'audiopin.json') -Value $raw
    $result = $raw | ConvertFrom-Json
    if ($result.PSObject.Properties['error']) { throw "driver: $($result.error)" }
    if (-not $result.pinInfoAfter) { throw 'no filter listed an [OUT] adts pin' }

    function Get-ConnectionSection([string] $Text) {
        $m = [regex]::Match($Text, '(?s)- Connection media type:(.*?)(- Enumerated media type|\z)')
        if (-not $m.Success) { throw "the pin reports no connection: $Text" }
        $m.Groups[1].Value
    }
    $before = Get-ConnectionSection $result.pinInfoBefore
    $after  = Get-ConnectionSection $result.pinInfoAfter

    # A positive control: built with mt_adts, the pin must read ADTS before
    # the switch, or this reader cannot tell the two apart.
    if ($before -notmatch $adtsSubtype) { throw "control failed, pin before the switch: $before" }

    $state = if ($after -match $adtsSubtype) { 'ADTS' } elseif ($after -match $latmSubtype) { 'LATM' } else { "unknown: $after" }
    Write-Host "selected '$($result.track.name)'; active $($result.audioAfter.active) of $(@($result.audioAfter.tracks).Count)"
    Write-Host "adts pin before the switch: ADTS; after: $state"
    $passed = $state -eq 'ADTS'
    Write-Host ('audio pin type: {0}' -f $(if ($passed) { 'PASS' } else { 'FAIL' })) -ForegroundColor $(if ($passed) { 'Green' } else { 'Red' })
} finally {
    if ($session -and $session.State -eq 'Opened') {
        Invoke-Command -Session $session -ScriptBlock {
            Get-Process mpc-hc64 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        }
        if ($prior) {
            Set-ConsoleSettings -Session $session -User $consoleUser -Dvb $prior.Dvb -Settings $prior.Settings | Out-Null
        }
        if ($mapped) {
            Invoke-Command -Session $session -ArgumentList $instanceKey, $Frequency -ScriptBlock {
                param($instance, $freq)
                Remove-Item "HKLM:\SYSTEM\PSWTuner\$instance\Device Parameters\$freq" -Recurse
            }
        }
        Remove-PSSession $session
    }
    Exit-RigClaim -Claim $claim
}

if (-not $passed) { exit 1 }
