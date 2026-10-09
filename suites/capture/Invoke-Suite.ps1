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

      record-camera-audio    record-with-previews with no audio device
                             configured, so the player takes audio from the
                             video device's own audio pin (CMainFrame::
                             OpenCapture's m_pAudCap = m_pVidCap, a capture
                             card such as the #4280 reporter's HVR-2250).
                             Both streams must run most of the 6 s. Skipped
                             when the video device has no audio output pin.

      preview-with-mpcvr     Preview with MPC Video Renderer as the output
                             renderer, which capture must replace with
                             EVR-CP: the graph log must not try MPCVR (#4280,
                             be66b4b8b1; unfixed 2.8.2 connects it). Skipped
                             without MPCVR\ beside the player.

    No rig: NeedsRig = $false. The suite needs a video capture source where it
    runs. On the host that is whatever camera is installed (e2eSoft VCam); the
    audio source is the first audio capture device, or the one whose friendly
    name contains CaptureAudioDevice from testbed.config.psd1.

    -VMName runs the same cases on a test guest instead, against the
    avs-vcamera virtual camera (tests\vcamera; ..\playback\Install-OutputDevices.ps1
    provisions it). The player and this script are copied to the guest and the
    script runs there, in host mode, as the console user from an interactive
    scheduled task, because the capture bar is driven with window messages and
    those only reach windows on the caller's desktop. Results come back to
    -OutDir as they would from a host run.
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

$description = 'Analog capture through the capture bar: record with previews, resolution changes, audio from the camera; needs a capture device where it runs (-VMName: the guest''s virtual camera), no rig'
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
// Just enough of IBaseFilter, IPin and IEnumMediaTypes to ask whether a filter has an audio output pin.
// Methods are declared in vtable order up to the last one used.
[ComImport, Guid("56A86895-0AD4-11CE-B03A-0020AF0BA770"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IBaseFilter {
    [PreserveSig] int GetClassID(out Guid c); [PreserveSig] int Stop(); [PreserveSig] int Pause(); [PreserveSig] int Run(long t);
    [PreserveSig] int GetState(int ms, out int s); [PreserveSig] int SetSyncSource(IntPtr c); [PreserveSig] int GetSyncSource(out IntPtr c);
    [PreserveSig] int EnumPins(out IEnumPins e);
}
[ComImport, Guid("56A86892-0AD4-11CE-B03A-0020AF0BA770"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IEnumPins { [PreserveSig] int Next(int n, [Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 0)] IPin[] p, IntPtr fetched); }
[ComImport, Guid("56A86891-0AD4-11CE-B03A-0020AF0BA770"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IPin {
    [PreserveSig] int Connect(IntPtr p, IntPtr mt); [PreserveSig] int ReceiveConnection(IntPtr p, IntPtr mt); [PreserveSig] int Disconnect();
    [PreserveSig] int ConnectedTo(out IntPtr p); [PreserveSig] int ConnectionMediaType(IntPtr mt); [PreserveSig] int QueryPinInfo(IntPtr info);
    [PreserveSig] int QueryDirection(out int dir); [PreserveSig] int QueryId(out IntPtr id); [PreserveSig] int QueryAccept(IntPtr mt);
    [PreserveSig] int EnumMediaTypes(out IEnumMediaTypes e);
}
[ComImport, Guid("89C31040-846B-11CE-97D3-00AA0055595A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IEnumMediaTypes { [PreserveSig] int Next(int n, out IntPtr mt, IntPtr fetched); }
public class Device { public string FriendlyName; public string DisplayName; }
public static class DevEnum {
    [DllImport("ole32.dll")] static extern int CreateBindCtx(int r, out IBindCtx ctx);
    [DllImport("ole32.dll")] static extern int MkParseDisplayName(IBindCtx ctx, [MarshalAs(UnmanagedType.LPWStr)] string name, out int eaten, out IMoniker m);
    static readonly Guid MEDIATYPE_Audio = new Guid("73647561-0000-0010-8000-00AA00389B71");
    public static bool HasAudioOutput(string displayName) {
        IBindCtx ctx; CreateBindCtx(0, out ctx);
        int eaten; IMoniker m;
        if (MkParseDisplayName(ctx, displayName, out eaten, out m) != 0 || m == null) return false;
        object o; Guid ibf = typeof(IBaseFilter).GUID;
        m.BindToObject(ctx, null, ref ibf, out o);
        var f = (IBaseFilter)o;
        IEnumPins ep; f.EnumPins(out ep);
        var p = new IPin[1];
        bool found = false;
        while (!found && ep.Next(1, p, IntPtr.Zero) == 0) {
            int dir; p[0].QueryDirection(out dir);
            IEnumMediaTypes et;
            if (dir == 1 && p[0].EnumMediaTypes(out et) == 0) {   // PINDIR_OUTPUT
                IntPtr mt;
                while (!found && et.Next(1, out mt, IntPtr.Zero) == 0) {
                    found = ((Guid)Marshal.PtrToStructure(mt, typeof(Guid))) == MEDIATYPE_Audio;   // AM_MEDIA_TYPE.majortype
                    Marshal.FreeCoTaskMem(mt);   // the format block leaks; this runs once
                }
                Marshal.ReleaseComObject(et);
            }
            Marshal.ReleaseComObject(p[0]);
        }
        Marshal.ReleaseComObject(ep); Marshal.ReleaseComObject(f);
        return found;
    }
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

# --- on a test guest -------------------------------------------------------------
#
# Everything below this block runs where the devices are. With -VMName that is the guest: this script and the
# player go there, the script runs in its host mode as the console user, and its result comes back.

if ($VMName) {
    $transport = Join-Path $testsRoot 'emulator\tools\GuestTransport.ps1'
    if (-not (Test-Path $transport)) { throw 'emulator submodule not initialised (git submodule update --init emulator)' }
    . $transport
    $cfg = Get-TestBedConfig

    New-Item -ItemType Directory -Force $OutDir | Out-Null
    $OutDir = (Resolve-Path $OutDir).Path

    # The player as the guest needs it: the exe, its icon library, and D3DX9_43.dll, without which EVR-CP (the
    # renderer capture uses) stops on a "missing d3dx9_43.dll" box on a clean guest. The installer ships that
    # from distrib\x64, two levels above bin\mpc-hc_x64.
    $playerDir = Split-Path (Resolve-Path $PlayerBinary).Path -Parent
    $stage = Join-Path $OutDir 'player-stage'
    if (Test-Path $stage) { Get-ChildItem $stage -File -Recurse | ForEach-Object { [IO.File]::Delete($_.FullName) } }
    New-Item -ItemType Directory -Force $stage | Out-Null
    Copy-Item $PlayerBinary (Join-Path $stage 'mpc-hc64.exe')
    foreach ($dep in (Join-Path $playerDir 'mpciconlib.dll'), (Join-Path $playerDir 'D3DX9_43.dll'), (Join-Path $playerDir '..\..\distrib\x64\D3DX9_43.dll')) {
        $leaf = Split-Path $dep -Leaf
        if ((Test-Path $dep) -and -not (Test-Path (Join-Path $stage $leaf))) { Copy-Item $dep $stage }
    }
    # MPC Video Renderer, for preview-with-mpcvr: the player loads it from MPCVR\ beside the exe, which only
    # the installer and the release zips have.
    if (Test-Path (Join-Path $playerDir 'MPCVR\MpcVideoRenderer64.ax')) {
        New-Item -ItemType Directory -Force (Join-Path $stage 'MPCVR') | Out-Null
        Copy-Item (Join-Path $playerDir 'MPCVR\*.ax') (Join-Path $stage 'MPCVR')
    }

    $guestRoot = 'C:\mpc-test\capture'
    $session = Connect-TestGuest -Guest $VMName
    try {
        if ($cfg.RequireRigId) {
            $rigId = Invoke-Command -Session $session { if (Test-Path 'C:\vtuner\rig-id.txt') { (Get-Content 'C:\vtuner\rig-id.txt' -Raw).Trim() } }
            if ($rigId -ne $VMName) { throw "rig-id.txt says '$rigId', expected '$VMName': not sure which guest this is" }
        }
        $console = Invoke-Command -Session $session { (Get-CimInstance Win32_ComputerSystem).UserName }
        $consoleUser = if ($cfg.GuestConsoleUser) { $cfg.GuestConsoleUser } else { ("$console" -split '\\')[-1] }
        if (-not $consoleUser) { throw "Nobody is logged on at the console of $VMName; the capture bar needs a desktop." }

        Invoke-Command -Session $session -ArgumentList $guestRoot {
            param($root)
            Get-Process mpc-hc64 -ErrorAction SilentlyContinue | Stop-Process -Force
            if (Test-Path $root) { Remove-Item $root -Recurse -Force }
            foreach ($d in $root, "$root\suites\capture", "$root\player", "$root\out") { New-Item -ItemType Directory -Force $d | Out-Null }
        }
        Copy-Item -ToSession $session (Join-Path $stage '*') "$guestRoot\player\" -Recurse -Force
        Copy-Item -ToSession $session $PSCommandPath "$guestRoot\suites\capture\Invoke-Suite.ps1" -Force
        $version = Invoke-Command -Session $session -ArgumentList $guestRoot {
            param($root)
            # The task runs as the console user, who has to be able to write the results and the player's copies.
            & icacls $root /grant 'Users:(OI)(CI)M' /T | Out-Null
            (Get-Item "$root\player\mpc-hc64.exe").VersionInfo.ProductVersion
        }
        Write-Host "  player under test on ${VMName}: $version from $playerDir" -ForegroundColor Gray

        $caseArg = if ($Case) { " -Case $($Case -join ',')" } else { '' }
        $runner = @"
`$ErrorActionPreference = 'Stop'
try {
    `$r = & '$guestRoot\suites\capture\Invoke-Suite.ps1' -PlayerBinary '$guestRoot\player\mpc-hc64.exe' -OutDir '$guestRoot\out'$caseArg
    `$r | ConvertTo-Json -Depth 4 | Set-Content '$guestRoot\out\result.json' -Encoding UTF8
} catch {
    @{ error = "`$_" } | ConvertTo-Json | Set-Content '$guestRoot\out\result.json' -Encoding UTF8
}
"@
        $json = Invoke-Command -Session $session -ArgumentList $guestRoot, $runner, $consoleUser {
            param($root, $runner, $user)
            [IO.File]::WriteAllText("$root\run.ps1", $runner)
            $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $root\run.ps1"
            $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive
            Register-ScheduledTask -TaskName 'MpcCaptureSuite' -Action $action -Principal $principal -Force | Out-Null
            Start-ScheduledTask -TaskName 'MpcCaptureSuite'
            $deadline = (Get-Date).AddMinutes(8)
            while (-not (Test-Path "$root\out\result.json") -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
            Start-Sleep -Seconds 1
            Unregister-ScheduledTask -TaskName 'MpcCaptureSuite' -Confirm:$false
            Get-Process mpc-hc64 -ErrorAction SilentlyContinue | Stop-Process -Force
            if (Test-Path "$root\out\result.json") { Get-Content "$root\out\result.json" -Raw } else { $null }
        }
        Copy-Item -FromSession $session "$guestRoot\out\*" -Destination $OutDir -Recurse -Force
    } finally {
        Remove-PSSession $session -ErrorAction SilentlyContinue
    }
    if (-not $json) { throw "the suite produced no result on $VMName within 8 minutes" }
    $r = $json | ConvertFrom-Json
    if ($r.PSObject.Properties['error']) { throw "the suite failed on ${VMName}: $($r.error)" }
    foreach ($n in $r.Notes) { Write-Host "  $n" }
    return [pscustomobject]@{ Suite = 'capture'; Passed = $r.Passed; Failed = $r.Failed; Skipped = $r.Skipped; Notes = @($r.Notes) }
}

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
  // GetWindowText reads another process's controls from a cache, often empty; WM_GETTEXT is marshalled.
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, StringBuilder l);
  public static string Text(IntPtr h) { var s = new StringBuilder(1024); SendMessage(h, 0x000D, (IntPtr)1024, s); return s.ToString(); }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
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
    # An empty -AudioDisplayName configures no audio device: the player then takes audio from the video device.
    # -Settings adds [Settings] keys (the renderer, for preview-with-mpcvr).
    param([string] $Name, [string] $AviPath, [string] $AudioDisplayName = $audio.DisplayName, [hashtable] $Settings = @{})
    $dir = Join-Path $OutDir "$Name\player"
    New-Item -ItemType Directory -Force $dir | Out-Null
    Copy-Item $PlayerBinary (Join-Path $dir 'mpc-hc64.exe') -Force
    $mpcvr = Join-Path (Split-Path $PlayerBinary -Parent) 'MPCVR'
    if (Test-Path $mpcvr) { Copy-Item $mpcvr $dir -Recurse -Force }
    $extra = ($Settings.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)`r`n" }) -join ''
    @"
[Settings]
UpdaterAutoCheck=0
DefaultCapture=0
DebugLogMask=3
$extra[Capture]
VidDispName=$($video.DisplayName)
AudDispName=$AudioDisplayName
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

$cases = @('record-with-previews', 'resolution-changes', 'record-camera-audio', 'preview-with-mpcvr', 'preview-after-reselect')
if ($Case) { $cases = $cases | Where-Object { $n = $_; $Case | Where-Object { $n -like $_ } } }

# --- record-with-previews, record-camera-audio --------------------------------------------

function Test-Recording {
    # Record 6 s with both previews on and judge the AVI. -AudioDisplayName '' takes the audio from the video
    # device, and then the audio stream's length is checked as well: from the camera there is nothing else
    # to say the audio pin was really running.
    param([string] $Name, [string] $AudioDisplayName, [switch] $CheckAudioLength)
    $problems = @()
    $avi = Join-Path $OutDir "$Name\test.avi"
    New-Item -ItemType Directory -Force (Split-Path $avi) | Out-Null
    Remove-Item $avi -ErrorAction SilentlyContinue
    $player = Start-CapturePlayer $Name $avi $AudioDisplayName
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
        $streams | ConvertTo-Json | Set-Content (Join-Path $OutDir "$Name\avi-streams.json")
        $vids = @($streams | Where-Object type -eq 'vids'); $auds = @($streams | Where-Object type -eq 'auds')
        Note Gray ("{0}: {1} bytes, {2} video + {3} audio stream(s), video {4} s" -f $Name, (Get-Item $avi).Length, $vids.Count, $auds.Count, ($(if ($vids) { $vids[0].seconds } else { '-' })))
        if ($vids.Count -ne 1) { $problems += "$($vids.Count) video streams, expected 1" }
        if ($auds.Count -ne 1) { $problems += "$($auds.Count) audio streams, expected 1 (a preview pin attached to the mux adds one)" }
        if ($vids -and $vids[0].seconds -lt 4) { $problems += "video stream is $($vids[0].seconds) s of a 6 s recording (mux stalled)" }
        if ($CheckAudioLength -and $auds -and $auds[0].seconds -lt 4) { $problems += "audio stream is $($auds[0].seconds) s of a 6 s recording" }
    }
    Report $Name $problems
}

if ($cases -contains 'record-with-previews') { Test-Recording 'record-with-previews' $audio.DisplayName }

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

# --- preview-after-reselect ---------------------------------------------------------------
#
# Reselect the current dimension three times, 5 s apart (the #4302 reporter's recipe), then read the camera's
# frame number out of the preview twice, a second apart. Every reselection rebuilds the graph. Before the fix
# CFGManager::m_pUnks kept the previous EVR-CP presenter alive after its EVR had left the graph: it went on
# being painted into the same window (a black rectangle, two statistics overlays) with a dangling pointer to
# its EVR (the 2.8.3.2 crash), and the next FindInterface could hand it, not the live presenter, to the frame.
# A live preview shows the strip advancing; a dead one shows black, or a number that does not move. Needs a
# camera that draws the strip (avs-vcamera): skipped when the picture does not decode before any reselection.

function Get-PreviewFrameNumber {
    # The number in the strip along the top of the picture, read from the screen: the camera's picture is
    # fitted into the view window and centred, the strip is 1/12 of it high, 32 blocks, MSB left, white is 1.
    # Returns -1 when a block is neither black nor white (nothing drawn, or not this camera's picture), -2 when
    # the window could not be captured at all. PrintWindow with PW_RENDERFULLCONTENT sees what EVR-CP drew,
    # and unlike a screen copy it works from a session that has no desktop of its own.
    param($Player, [int] $Width, [int] $Height, [string] $Png)
    # The view is the frame's MFC pane, control id AFX_IDW_PANE_FIRST (59648); the bars are AfxControlBar windows.
    $view = $null; $hwnd = [IntPtr]::Zero
    $windows = [System.Collections.Generic.List[string]]::new()
    foreach ($c in $W::Children($Player.Main)) {
        $r = New-Object MpcCapture.W+RECT; [void] $W::GetWindowRect($c, [ref] $r)
        $windows.Add(('{0} {1} id={2} {3},{4}-{5},{6} children={7}' -f $c, $W::Cls($c), $W::GetDlgCtrlID($c), $r.L, $r.T, $r.R, $r.B, $W::Children($c).Count))
        if ($W::GetDlgCtrlID($c) -eq 59648 -and -not $view) { $view = $r; $hwnd = $c }
    }
    if ($Png) { $windows | Set-Content ($Png -replace '\.png$', '.windows.txt') }   # every child, for when the view is not where expected
    if (-not $view) { return -2 }
    $vw = $view.R - $view.L; $vh = $view.B - $view.T
    $scale = [Math]::Min($vw / $Width, $vh / $Height)
    $pw = [int] ($Width * $scale); $ph = [int] ($Height * $scale)
    $px = $view.L + [int] (($vw - $pw) / 2); $py = $view.T + [int] (($vh - $ph) / 2)
    Add-Type -AssemblyName System.Drawing
    $bmp = New-Object System.Drawing.Bitmap $vw, $vh
    $gfx = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $dc = $gfx.GetHdc()
        $ok = $W::PrintWindow($hwnd, $dc, 2)
        $gfx.ReleaseHdc($dc)
        if (-not $ok) { $gfx.Dispose(); $bmp.Dispose(); return -2 }
    } catch { $gfx.Dispose(); $bmp.Dispose(); return -2 }
    if ($Png) { $bmp.Save($Png, [System.Drawing.Imaging.ImageFormat]::Png) }
    $value = 0; $clean = $true
    $y = ($py - $view.T) + [int] ($ph / 24)
    for ($bit = 0; $bit -lt 32; $bit++) {
        $x = ($px - $view.L) + [int] (($bit + 0.5) * $pw / 32)
        $p = $bmp.GetPixel($x, $y)
        $luma = (0.299 * $p.R + 0.587 * $p.G + 0.114 * $p.B)
        if ($luma -gt 192) { $value = $value * 2 + 1 } elseif ($luma -lt 64) { $value = $value * 2 } else { $clean = $false; break }
    }
    $gfx.Dispose(); $bmp.Dispose()
    if ($clean) { $value } else { -1 }
}

if ($cases -contains 'preview-after-reselect') {
    $name = 'preview-after-reselect'
    $problems = @()
    New-Item -ItemType Directory -Force (Join-Path $OutDir $name) | Out-Null
    $player = Start-CapturePlayer $name (Join-Path $OutDir "$name\unused.avi")
    $skip = ''
    try {
        $dim = Control $player.Dialog $IDC_COMBO5
        $sel = [int]$W::SendMessage($dim, $CB_GETCURSEL, [IntPtr]::Zero, [IntPtr]::Zero)
        $size = $W::Text($dim)   # "640x480 25.00"
        if ($size -notmatch '^(\d+)x(\d+)') { throw "cannot read the dimension from '$size'" }
        $width = [int] $Matches[1]; $height = [int] $Matches[2]
        $before = Get-PreviewFrameNumber $player $width $height (Join-Path $OutDir "$name\before.png")
        Note Gray "$name`: ${width}x${height}, frame $before before any reselection"
        if ($before -eq -2) { $skip = 'the view window could not be captured' }
        elseif ($before -le 0) { $skip = "the preview shows no frame strip (frame $before); needs avs-vcamera" }
        else {
            for ($n = 1; $n -le 3; $n++) {
                $W::SendMessage($dim, $CB_SETCURSEL, [IntPtr]$sel, [IntPtr]::Zero) | Out-Null
                $r = [IntPtr]::Zero
                $ok = $W::SendMessageTimeout($player.Dialog, $WM_COMMAND, [IntPtr]($IDC_COMBO5 -bor ($CBN_SELCHANGE -shl 16)), $dim, 2, 20000, [ref]$r) -ne [IntPtr]::Zero
                if (-not $ok) { $problems += "reselection $n did not return within 20 s"; break }
                Start-Sleep -Seconds 5
                if ($player.Process.HasExited) { $problems += "player exited after reselection $n, code $($player.Process.ExitCode)"; break }
                if (-not $W::Answers($player.Main, 3000)) { $problems += "main window not answering after reselection $n"; break }
            }
            if (-not $problems) {
                $first = Get-PreviewFrameNumber $player $width $height (Join-Path $OutDir "$name\after-1.png")
                Start-Sleep -Seconds 1
                $second = Get-PreviewFrameNumber $player $width $height (Join-Path $OutDir "$name\after-2.png")
                Note Gray "$name`: frames $first and $second a second apart after three reselections"
                if ($first -le 0 -or $second -le 0) { $problems += "preview not showing the camera's picture after the reselections (frames $first, $second)" }
                elseif ($second -le $first) { $problems += "preview frozen at frame $first after the reselections" }
            }
        }
    } finally {
        if (-not (Stop-CapturePlayer $player)) { $problems += 'player did not close on WM_CLOSE within 20 s' }
    }
    if ($skip) { $skipped++; Note Yellow "SKIP $name`: $skip" } else { Report $name $problems }
}

# --- record-camera-audio ----------------------------------------------------------------

if ($cases -contains 'record-camera-audio') {
    if (-not [MpcCapture.DevEnum]::HasAudioOutput($video.DisplayName)) {
        $skipped++; Note Yellow "SKIP record-camera-audio: $($video.FriendlyName) has no audio output pin"
    } else {
        Test-Recording 'record-camera-audio' '' -CheckAudioLength
    }
}

# --- preview-with-mpcvr ------------------------------------------------------------------
#
# Preview with MPC Video Renderer as the output renderer (DSVidRen 14; LastGPUCheck as the playback suite's
# MPCVR cases set it). MPCVR cannot run a capture graph, so CFGManagerPlayer substitutes EVR-CP
# (594b674b30) when m_bIsCapture -- but CFGManagerCapture set that flag only after its base constructor had
# picked the renderers, so the substitute never applied and MPCVR went into the capture graph
# (clsid2/mpc-hc#4280, where it hung; be66b4b8b1 passes the flag into the constructor). The graph log says
# which renderers were tried: unfixed 2.8.2 logs "Trying MPC Video Renderer" and connects it to the Smart
# Tee, the fix never tries it. No recording, so the case does not depend on the #4285 mux fix. Skipped
# when the player has no MPCVR\ beside it.

if ($cases -contains 'preview-with-mpcvr') {
    $name = 'preview-with-mpcvr'
    if (-not (Test-Path (Join-Path (Split-Path $PlayerBinary -Parent) 'MPCVR\MpcVideoRenderer64.ax'))) {
        $skipped++; Note Yellow "SKIP $name`: no MPCVR\MpcVideoRenderer64.ax beside $PlayerBinary"
    } else {
        $problems = @()
        New-Item -ItemType Directory -Force (Join-Path $OutDir $name) | Out-Null
        try {
            $player = Start-CapturePlayer $name (Join-Path $OutDir "$name\unused.avi") $audio.DisplayName @{ DSVidRen = 14; LastGPUCheck = 500000 }
            try {
                Start-Sleep -Seconds 4
                if (-not $W::Answers($player.Main, 3000)) { $problems += 'main window not answering while previewing' }
            } finally {
                if (-not (Stop-CapturePlayer $player)) { $problems += 'player did not close on WM_CLOSE within 20 s' }
            }
            $log = Join-Path $player.Dir 'filtergraph.log'
            if (-not (Test-Path $log)) { $problems += 'no filtergraph.log' }
            else {
                $lines = Get-Content $log
                if ($lines -match 'Trying MPC Video Renderer') { $problems += 'MPC Video Renderer was tried in the capture graph: ' + ((($lines -match 'MPC Video Renderer') | Select-Object -First 2) -join ' / ') }
                if (-not ($lines -match 'Renderer.* connected to')) { $problems += 'no video renderer connected' }
            }
        } catch {
            # A player that never shows its Live window throws from Start-CapturePlayer: this case's failure.
            Get-Process mpc-hc64 -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$OutDir\$name\*" } | Stop-Process -Force
            $problems += "$_"
        }
        Report $name $problems
    }
}

[pscustomobject]@{ Suite = 'capture'; Passed = $passed; Failed = $failed; Skipped = $skipped; Notes = $notes }
