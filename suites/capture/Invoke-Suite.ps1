<#
.SYNOPSIS
    The capture suite: analog capture (File > Open Device) driven through the
    capture bar, with the result read back from the file it recorded.

.DESCRIPTION
    Opens the first DirectShow video capture device and an audio capture device
    on the machine the suite runs on, then drives the capture bar the way a user
    does: Record, wait, Stop; or change the video dimension repeatedly. The
    assertions read the AVI header the recording produced and the player's
    responsiveness, not pixels.

    Cases:

      record-with-previews   Record Video + Record Audio with both previews on,
                             AVI, 6 s. The AVI must carry exactly one video and
                             one audio stream and its video must run most of
                             the 6 s. Guards clsid2/mpc-hc#4285: the audio
                             preview pin used to be rendered after the mux was
                             in the graph, got attached to the mux's spare
                             input, and the mux then waited on that phantom
                             stream forever (0.48 s file, two audio streams).

      resolution-changes     Select the next video dimension four times while
                             previewing. Each change rebuilds the graph; the
                             player must answer every one and close cleanly.
                             The rebuild path of clsid2/mpc-hc#4280.

    No rig: NeedsRig = $false. The suite needs a video capture source where it
    runs. Today that is the host (e2eSoft VCam); the test guests have no camera
    until a virtual capture driver joins vaudio and vdisplay, at which point
    this runs there unchanged. The audio source is the first audio capture
    device, or the one whose friendly name contains CaptureAudioDevice from
    testbed.config.psd1.
#>
[CmdletBinding()]
param(
    [switch] $Probe,
    [string] $VMName = '',
    [string] $OutDir = (Join-Path $PSScriptRoot 'results'),
    [string] $PlayerBinary,
    [string[]] $Case
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$description = 'Analog capture through the capture bar: record with previews, resolution changes; needs a capture device where it runs, no rig'
$testsRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$repoRoot = Split-Path $testsRoot -Parent

if (-not $PlayerBinary) {
    $cand = Join-Path $repoRoot 'bin\mpc-hc_x64\mpc-hc64.exe'
    if (Test-Path $cand) { $PlayerBinary = $cand }
}

# --- DirectShow device enumeration ------------------------------------------------

if (-not ('MpcCapture.DevEnum' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
namespace MpcCapture {
[ComImport, Guid("29840822-5B84-11D0-BD3B-00A0C911CE86"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface ICreateDevEnum { [PreserveSig] int CreateClassEnumerator([In] ref Guid clsid, out IEnumMoniker ppEnum, int flags); }
[ComImport, Guid("55272A00-42CB-11CE-8135-00AA004BB851"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IPropertyBag {
    [PreserveSig] int Read([MarshalAs(UnmanagedType.LPWStr)] string name, ref object v, IntPtr log);
    [PreserveSig] int Write([MarshalAs(UnmanagedType.LPWStr)] string name, ref object v);
}
public class Device { public string FriendlyName; public string DisplayName; }
public static class DevEnum {
    [DllImport("ole32.dll")] static extern int CreateBindCtx(int r, out IBindCtx ctx);
    public static List<Device> List(string category) {
        var result = new List<Device>();
        Guid g = new Guid(category);
        var de = (ICreateDevEnum)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("62BE5D10-60EB-11D0-BD3B-00A0C911CE86")));
        IEnumMoniker e;
        if (de.CreateClassEnumerator(ref g, out e, 0) != 0 || e == null) return result;
        var m = new IMoniker[1];
        while (e.Next(1, m, IntPtr.Zero) == 0) {
            IBindCtx ctx; CreateBindCtx(0, out ctx);
            string dn; m[0].GetDisplayName(ctx, null, out dn);
            object bag; Guid ipb = typeof(IPropertyBag).GUID;
            m[0].BindToStorage(ctx, null, ref ipb, out bag);
            object v = null; ((IPropertyBag)bag).Read("FriendlyName", ref v, IntPtr.Zero);
            result.Add(new Device { FriendlyName = Convert.ToString(v), DisplayName = dn });
        }
        return result;
    }
}
}
'@
}
$videoDevices = [MpcCapture.DevEnum]::List('860BB310-5D01-11d0-BD3B-00A0C911CE86')
$audioDevices = [MpcCapture.DevEnum]::List('33D9A762-90C8-11d0-BD43-00A0C911CE86')

function Find-Config {
    $dir = $testsRoot
    while ($dir) {
        $cand = Join-Path $dir 'testbed.config.psd1'
        if (Test-Path $cand) { return Import-PowerShellDataFile $cand }
        $dir = Split-Path $dir -Parent
    }
    @{}
}
$cfg = Find-Config
$audioPref = if ($cfg.ContainsKey('CaptureAudioDevice')) { $cfg.CaptureAudioDevice } else { '' }
$video = $videoDevices | Select-Object -First 1
$audio = $null
if ($audioPref) { $audio = $audioDevices | Where-Object { $_.FriendlyName -like "*$audioPref*" } | Select-Object -First 1 }
if (-not $audio) { $audio = $audioDevices | Select-Object -First 1 }

if ($Probe) {
    $ready = $true; $reason = ''
    if (-not $PlayerBinary -or -not (Test-Path $PlayerBinary)) { $ready = $false; $reason = 'no player binary (bin\mpc-hc_x64\mpc-hc64.exe or -PlayerBinary)' }
    elseif (-not $video) { $ready = $false; $reason = 'no DirectShow video capture device on this machine' }
    elseif (-not $audio) { $ready = $false; $reason = 'no DirectShow audio capture device on this machine' }
    return [pscustomobject]@{ Suite = 'capture'; Description = $description; Ready = $ready; Reason = $reason; NeedsRig = $false }
}

if (-not $PlayerBinary -or -not (Test-Path $PlayerBinary)) { throw 'no player binary' }
if (-not $video -or -not $audio) { throw 'no capture devices' }

New-Item -ItemType Directory -Force $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path
$passed = 0; $failed = 0; $skipped = 0
$notes = [System.Collections.Generic.List[string]]::new()
function Note { param([string] $Colour, [string] $Text) $notes.Add($Text); Write-Host "  $Text" -ForegroundColor $Colour }
function Report {
    param([string] $Name, [string[]] $Problems)
    if ($Problems.Count) { $script:failed++; Note Red "FAIL $Name`: $($Problems -join '; ')" }
    else { $script:passed++; Note Green "PASS $Name" }
}
Note Gray "video: $($video.FriendlyName); audio: $($audio.FriendlyName); player: $PlayerBinary"

# --- window plumbing ----------------------------------------------------------------

if (-not ('MpcCapture.W' -as [type])) {
    Add-Type -TypeDefinition @'
using System; using System.Text; using System.Collections.Generic; using System.Runtime.InteropServices;
namespace MpcCapture {
public static class W {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr h, EnumProc p, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern IntPtr SendMessageTimeout(IntPtr h, uint m, IntPtr w, IntPtr l, uint f, uint t, out IntPtr r);
  public static List<IntPtr> TopWindows(uint pid) { var r = new List<IntPtr>(); EnumWindows((h,l)=>{ uint p; GetWindowThreadProcessId(h, out p); if (p==pid) r.Add(h); return true; }, IntPtr.Zero); return r; }
  public static List<IntPtr> Children(IntPtr h) { var r = new List<IntPtr>(); EnumChildWindows(h, (c,l)=>{ r.Add(c); return true; }, IntPtr.Zero); return r; }
  public static string Cls(IntPtr h) { var s = new StringBuilder(256); GetClassName(h, s, 256); return s.ToString(); }
  public static string Txt(IntPtr h) { var s = new StringBuilder(1024); GetWindowText(h, s, 1024); return s.ToString(); }
  public static bool Answers(IntPtr h, uint ms) { IntPtr r; return SendMessageTimeout(h, 0, IntPtr.Zero, IntPtr.Zero, 2, ms, out r) != IntPtr.Zero; }
}
}
'@
}
$W = [MpcCapture.W]

# Capture bar dialog (IDD_CAPTURE_DLG) control ids from src\mpc-hc\resource.h.
$IDC_COMBO5  = 11004   # video dimension
$IDC_BUTTON2 = 11121   # Record / Stop
$WM_CLOSE = 0x10; $WM_COMMAND = 0x111; $BN_CLICKED = 0; $CBN_SELCHANGE = 1
$CB_GETCOUNT = 0x146; $CB_GETCURSEL = 0x147; $CB_SETCURSEL = 0x14E

function Control($dlg, $id) { foreach ($c in $W::Children($dlg)) { if ($W::GetDlgCtrlID($c) -eq $id) { return $c } } }

function Start-CapturePlayer {
    # A private copy of the exe with a portable ini beside it: the settings
    # (device, output flags, file name) are the test's, not the machine's.
    param([string] $Name, [string] $AviPath)
    $dir = Join-Path $OutDir "$Name\player"
    New-Item -ItemType Directory -Force $dir | Out-Null
    Copy-Item $PlayerBinary (Join-Path $dir 'mpc-hc64.exe') -Force
    @"
[Settings]
UpdaterAutoCheck=0
DefaultCapture=0
DebugLogMask=3
[Capture]
VidDispName=$($video.DisplayName)
AudDispName=$($audio.DisplayName)
VidOutput=1
AudOutput=1
VidPreview=1
AudPreview=1
FileFormat=0
SepAudio=0
FileName=$AviPath
"@ | Set-Content (Join-Path $dir 'mpc-hc64.ini') -Encoding ascii
    $p = Start-Process (Join-Path $dir 'mpc-hc64.exe') -ArgumentList '/new', '/device' -PassThru
    $main = $null
    for ($i = 0; $i -lt 60 -and -not $main; $i++) {
        Start-Sleep -Milliseconds 500
        if ($p.HasExited) { throw "player exited during open, code $($p.ExitCode)" }
        foreach ($h in $W::TopWindows([uint32]$p.Id)) { if ($W::Txt($h) -match '^Live') { $main = $h } }
    }
    if (-not $main) { Stop-Process -Id $p.Id -Force; throw 'no Live window within 30 s' }
    Start-Sleep -Seconds 3
    $rec = $null
    foreach ($c in $W::Children($main)) { if ($W::GetDlgCtrlID($c) -eq $IDC_BUTTON2 -and $W::Cls($c) -eq 'Button') { $rec = $c } }
    if (-not $rec) { Stop-Process -Id $p.Id -Force; throw 'capture bar not found' }
    [pscustomobject]@{ Process = $p; Main = $main; Dialog = $W::GetParent($rec); Record = $rec; Dir = $dir }
}

function Stop-CapturePlayer {
    # Returns $true when the player closed on WM_CLOSE, $false when it had to be killed.
    param($Player)
    $W::PostMessage($Player.Main, $WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
    if ($Player.Process.WaitForExit(20000)) { return $true }
    Stop-Process -Id $Player.Process.Id -Force
    $false
}

function Click($dlg, $id, $ctl) {
    $r = [IntPtr]::Zero
    $W::SendMessageTimeout($dlg, $WM_COMMAND, [IntPtr]($id -bor ($BN_CLICKED -shl 16)), $ctl, 2, 15000, [ref]$r) -ne [IntPtr]::Zero
}

function Read-AviStreams {
    # The stream headers of an AVI: one per 'strh' chunk in the hdrl list.
    param([string] $Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $limit = [Math]::Min($bytes.Length, 1MB)
    $streams = @()
    for ($i = 0; $i -lt $limit - 44; $i++) {
        if ($bytes[$i] -eq 0x73 -and $bytes[$i+1] -eq 0x74 -and $bytes[$i+2] -eq 0x72 -and $bytes[$i+3] -eq 0x68) {   # 'strh'
            $d = $i + 8
            $type = [Text.Encoding]::ASCII.GetString($bytes, $d, 4)
            if ($type -ne 'vids' -and $type -ne 'auds' -and $type -ne 'txts' -and $type -ne 'mids') { continue }
            $scale = [BitConverter]::ToUInt32($bytes, $d + 20)
            $rate = [BitConverter]::ToUInt32($bytes, $d + 24)
            $length = [BitConverter]::ToUInt32($bytes, $d + 32)
            $seconds = if ($rate) { [double]$length * $scale / $rate } else { 0 }
            $streams += [pscustomobject]@{ type = $type; scale = $scale; rate = $rate; length = $length; seconds = [Math]::Round($seconds, 2) }
        }
    }
    $streams
}

$cases = @('record-with-previews', 'resolution-changes')
if ($Case) { $cases = $cases | Where-Object { $n = $_; $Case | Where-Object { $n -like $_ } } }

# --- record-with-previews ------------------------------------------------------------

if ($cases -contains 'record-with-previews') {
    $name = 'record-with-previews'
    $problems = @()
    $avi = Join-Path $OutDir "$name\test.avi"
    New-Item -ItemType Directory -Force (Split-Path $avi) | Out-Null
    Remove-Item $avi -ErrorAction SilentlyContinue
    $player = Start-CapturePlayer $name $avi
    try {
        if (-not (Click $player.Dialog $IDC_BUTTON2 $player.Record)) { $problems += 'Record click did not return within 15 s' }
        Start-Sleep -Seconds 6
        if ($W::Txt($player.Record) -ne 'Stop') { $problems += "button reads '$($W::Txt($player.Record))' while recording, expected Stop" }
        if (-not $W::Answers($player.Main, 3000)) { $problems += 'main window not answering while recording' }
        if (-not (Click $player.Dialog $IDC_BUTTON2 $player.Record)) { $problems += 'Stop click did not return within 15 s' }
        Start-Sleep -Seconds 2
    } finally {
        if (-not (Stop-CapturePlayer $player)) { $problems += 'player did not close on WM_CLOSE within 20 s' }
    }
    if (-not (Test-Path $avi)) { $problems += 'no AVI written' }
    else {
        $streams = @(Read-AviStreams $avi)
        $streams | ConvertTo-Json | Set-Content (Join-Path $OutDir "$name\avi-streams.json")
        $vids = @($streams | Where-Object type -eq 'vids'); $auds = @($streams | Where-Object type -eq 'auds')
        Note Gray ("{0}: {1} bytes, {2} video + {3} audio stream(s), video {4} s" -f $name, (Get-Item $avi).Length, $vids.Count, $auds.Count, ($(if ($vids) { $vids[0].seconds } else { '-' })))
        if ($vids.Count -ne 1) { $problems += "$($vids.Count) video streams, expected 1" }
        if ($auds.Count -ne 1) { $problems += "$($auds.Count) audio streams, expected 1 (a preview pin attached to the mux adds one)" }
        if ($vids -and $vids[0].seconds -lt 4) { $problems += "video stream is $($vids[0].seconds) s of a 6 s recording (mux stalled)" }
    }
    Report $name $problems
}

# --- resolution-changes ----------------------------------------------------------------

if ($cases -contains 'resolution-changes') {
    $name = 'resolution-changes'
    $problems = @()
    New-Item -ItemType Directory -Force (Join-Path $OutDir $name) | Out-Null
    $player = Start-CapturePlayer $name (Join-Path $OutDir "$name\unused.avi")
    try {
        $dim = Control $player.Dialog $IDC_COMBO5
        $count = [int]$W::SendMessage($dim, $CB_GETCOUNT, [IntPtr]::Zero, [IntPtr]::Zero)
        $sel = [int]$W::SendMessage($dim, $CB_GETCURSEL, [IntPtr]::Zero, [IntPtr]::Zero)
        Note Gray "$name`: $count dimension(s) offered, starting at $sel"
        if ($count -lt 2) { $skipped++; Note Yellow "SKIP $name`: the device offers only $count dimension" }
        else {
            for ($n = 1; $n -le 4; $n++) {
                $sel = ($sel + 1) % $count
                $W::SendMessage($dim, $CB_SETCURSEL, [IntPtr]$sel, [IntPtr]::Zero) | Out-Null
                $r = [IntPtr]::Zero
                $ok = $W::SendMessageTimeout($player.Dialog, $WM_COMMAND, [IntPtr]($IDC_COMBO5 -bor ($CBN_SELCHANGE -shl 16)), $dim, 2, 20000, [ref]$r) -ne [IntPtr]::Zero
                Start-Sleep -Seconds 2
                if (-not $ok) { $problems += "change $n (item $sel) did not return within 20 s"; break }
                if (-not $W::Answers($player.Main, 3000)) { $problems += "main window not answering after change $n"; break }
            }
        }
    } finally {
        if (-not (Stop-CapturePlayer $player)) { $problems += 'player did not close on WM_CLOSE within 20 s' }
    }
    if ($count -ge 2) { Report $name $problems }
}

[pscustomobject]@{ Suite = 'capture'; Passed = $passed; Failed = $failed; Skipped = $skipped; Notes = $notes }
