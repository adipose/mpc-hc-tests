# Shared helpers for New-TestGuest.ps1 and Initialize-TestGuest.ps1. Nothing here needs an elevated
# shell: membership of Hyper-V Administrators is enough, which is why the install boots the real ISO
# with an answer file on a second ISO rather than applying the image to a mounted VHDX (mounting and
# partitioning a VHDX on the host needs elevation).

Set-StrictMode -Version Latest

function Get-TestbedProfile {
    param([Parameter(Mandatory)] [ValidateSet('7', '10', '11')] [string] $Os)
    (Import-PowerShellDataFile (Join-Path $PSScriptRoot 'profiles.psd1'))[$Os]
}

# A data ISO (ISO 9660 + Joliet) holding the contents of a folder, written with Windows' own IMAPI2
# file-system imager: no ADK, no oscdimg. Windows Setup looks for autounattend.xml at the root of every
# removable drive, a second DVD included.
function New-IsoFromFolder {
    param([Parameter(Mandatory)] [string] $Folder, [Parameter(Mandatory)] [string] $Path, [string] $Label = 'ANSWER')
    if (-not ('Testbed.IsoWriter' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices.ComTypes;
namespace Testbed {
public static class IsoWriter {
    public static void Write(string path, object comStream, int blockSize, int totalBlocks) {
        var stream = (IStream)comStream;
        var buffer = new byte[blockSize];
        IntPtr read = System.Runtime.InteropServices.Marshal.AllocHGlobal(4);
        try {
            using (var file = File.Create(path)) {
                for (int i = 0; i < totalBlocks; i++) {
                    stream.Read(buffer, blockSize, read);
                    int n = System.Runtime.InteropServices.Marshal.ReadInt32(read);
                    file.Write(buffer, 0, n);
                }
            }
        } finally { System.Runtime.InteropServices.Marshal.FreeHGlobal(read); }
    }
}
}
'@
    }
    $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $fsi.FileSystemsToCreate = 3        # FsiFileSystemISO9660 | FsiFileSystemJoliet
    $fsi.VolumeName = $Label
    $fsi.Root.AddTree((Resolve-Path $Folder).Path, $false)
    $result = $fsi.CreateResultImage()
    [Testbed.IsoWriter]::Write($Path, $result.ImageStream, $result.BlockSize, $result.TotalBlocks)
}

# Keystrokes to the VM's keyboard through the Hyper-V WMI provider. Used once, to answer the DVD's
# "Press any key to boot from CD or DVD" so Setup starts; nothing else is typed into a guest. Keep the
# window short: the prompt shows a second or two after power-on and lasts about five, and a key still
# arriving once Setup's own window is up lands on its focused Cancel button. That happened with 25 s:
# Setup sat on "Are you sure you want to quit?" at 11% for an hour.
function Send-VMKey {
    param([Parameter(Mandatory)] [string] $VMName, [int] $KeyCode = 0x0D, [int] $ForSeconds = 8)
    $deadline = (Get-Date).AddSeconds($ForSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $vm = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_ComputerSystem -Filter "ElementName='$VMName'"
            $kb = Get-CimAssociatedInstance -InputObject $vm -ResultClassName Msvm_Keyboard -ErrorAction Stop
            if ($kb) { [void] (Invoke-CimMethod -InputObject $kb -MethodName TypeKey -Arguments @{ keyCode = [uint32] $KeyCode }) }
        } catch { }
        Start-Sleep -Milliseconds 700
    }
}

# Free physical memory on the host, in GB. The host runs other VMs and sessions; a build or run that
# would push it under the floor stops rather than starve them.
function Get-HostFreeGB { [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB, 1) }

function Assert-HostMemory {
    param([Parameter(Mandatory)] [string] $VMName, [double] $FloorGB = 4)
    $free = Get-HostFreeGB
    if ($free -lt $FloorGB) {
        Stop-VM -Name $VMName -TurnOff -Force -ErrorAction SilentlyContinue
        throw "Host free memory fell to $free GB (floor $FloorGB GB); $VMName was turned off so the host's other VMs keep running. Free some memory and resume."
    }
}

# A PowerShell Direct session as the guest's own account, retried until the guest answers. A heartbeat
# only means the integration services are up; the session is what proves the account exists and has
# logged on at least once (which is when the profile and the console session the tests need exist).
function Wait-GuestSession {
    param(
        [Parameter(Mandatory)] [string] $VMName,
        [Parameter(Mandatory)] [pscredential] $Credential,
        [int] $TimeoutMinutes = 20,
        [double] $FloorGB = 4,
        [string] $Activity = 'waiting for the guest'
    )
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $started = Get-Date
    while ((Get-Date) -lt $deadline) {
        Assert-HostMemory -VMName $VMName -FloorGB $FloorGB
        try {
            $s = New-PSSession -VMName $VMName -Credential $Credential -ErrorAction Stop
            # The account answering is not enough: wait for its desktop, which autologon creates.
            $desktop = Invoke-Command -Session $s { [bool] (Get-Process explorer -ErrorAction SilentlyContinue) }
            if ($desktop) { return $s }
            Remove-PSSession $s
        } catch { }
        Write-Host ("  {0}: {1:N0} min, host free {2} GB" -f $Activity, ((Get-Date) - $started).TotalMinutes, (Get-HostFreeGB))
        Start-Sleep -Seconds 30
    }
    throw "$VMName did not answer as its own account with a desktop within $TimeoutMinutes minutes ($Activity)."
}

# The VM's screen as a PNG, through Hyper-V's thumbnail call (RGB565 pixels). For seeing where an
# unattended install or a first logon has got to without opening a console window.
function Save-VMScreen {
    param([Parameter(Mandatory)] [string] $VMName, [Parameter(Mandatory)] [string] $Path, [int] $Width = 1024, [int] $Height = 768)
    $ns = 'root\virtualization\v2'
    $svc = Get-CimInstance -Namespace $ns -ClassName Msvm_VirtualSystemManagementService
    $vm = Get-CimInstance -Namespace $ns -ClassName Msvm_ComputerSystem -Filter "ElementName='$VMName'"
    $sd = Get-CimAssociatedInstance -InputObject $vm -ResultClassName Msvm_VirtualSystemSettingData | Where-Object VirtualSystemType -eq 'Microsoft:Hyper-V:System:Realized'
    $r = Invoke-CimMethod -InputObject $svc -MethodName GetVirtualSystemThumbnailImage -Arguments @{ TargetSystem = $sd; WidthPixels = [uint16] $Width; HeightPixels = [uint16] $Height }
    if ($r.ReturnValue -ne 0) { throw "GetVirtualSystemThumbnailImage returned $($r.ReturnValue)" }
    Add-Type -AssemblyName System.Drawing
    $bytes = [byte[]] $r.ImageData
    $bmp = [System.Drawing.Bitmap]::new($Width, $Height, [System.Drawing.Imaging.PixelFormat]::Format16bppRgb565)
    $data = $bmp.LockBits([System.Drawing.Rectangle]::new(0, 0, $Width, $Height), [System.Drawing.Imaging.ImageLockMode]::WriteOnly, $bmp.PixelFormat)
    for ($y = 0; $y -lt $Height; $y++) { [System.Runtime.InteropServices.Marshal]::Copy($bytes, $y * $Width * 2, [IntPtr]($data.Scan0.ToInt64() + $y * $data.Stride), $Width * 2) }
    $bmp.UnlockBits($data)
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}

# Wait until the guest is idle: its total CPU under -BelowPercent for -ForSeconds in a row, sampled every
# 3 s through one PowerShell Direct session, giving up (with a warning, not an error) after -TimeoutMinutes.
# A guest just restored and booted is busy for minutes (indexing, Defender, store and cloud content), and on
# Windows 11 that delayed the player's start by 2 s or more in cases that time its audio; a fixed sleep was
# either too short or wasted. Returns how long it waited and the last sample.
function Wait-GuestIdle {
    param(
        [Parameter(Mandatory)] [string] $VMName,
        [Parameter(Mandatory)] [pscredential] $Credential,
        [int] $BelowPercent = 10,
        [int] $ForSeconds = 30,
        [int] $TimeoutMinutes = 10
    )
    $started = Get-Date
    $s = New-PSSession -VMName $VMName -Credential $Credential -ErrorAction Stop
    try {
        $calmSince = $null; $last = $null
        while (((Get-Date) - $started).TotalMinutes -lt $TimeoutMinutes) {
            $last = Invoke-Command -Session $s { [int] (Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'").PercentProcessorTime }
            if ($last -lt $BelowPercent) {
                if (-not $calmSince) { $calmSince = Get-Date }
                if (((Get-Date) - $calmSince).TotalSeconds -ge $ForSeconds) {
                    return [pscustomobject]@{ Idle = $true; WaitedSec = [int] ((Get-Date) - $started).TotalSeconds; LastCpu = $last }
                }
            } else { $calmSince = $null }
            Start-Sleep -Seconds 3
        }
        Write-Warning "$VMName did not stay under $BelowPercent% CPU for $ForSeconds s within $TimeoutMinutes min (last $last%); going on."
        [pscustomobject]@{ Idle = $false; WaitedSec = [int] ((Get-Date) - $started).TotalSeconds; LastCpu = $last }
    } finally { Remove-PSSession $s -ErrorAction SilentlyContinue }
}

# Restore a guest to a checkpoint, start it, and return once its console account has a desktop and the guest
# has gone idle: the state a run should start from.
function Start-TestGuest {
    param(
        [Parameter(Mandatory)] [string] $VMName,
        [Parameter(Mandatory)] [pscredential] $Credential,
        [string] $Checkpoint,
        [double] $FloorGB = 4
    )
    if ((Get-VM $VMName).State -ne 'Off') { Stop-VM -Name $VMName -Force }
    if ($Checkpoint) { Restore-VMSnapshot -VMName $VMName -Name $Checkpoint -Confirm:$false }
    Assert-HostMemory -VMName $VMName -FloorGB ($FloorGB + (Get-VM $VMName).MemoryStartup / 1GB)
    Start-VM -Name $VMName
    $s = Wait-GuestSession -VMName $VMName -Credential $Credential -TimeoutMinutes 10 -FloorGB $FloorGB -Activity 'booting'
    Remove-PSSession $s
    Wait-GuestIdle -VMName $VMName -Credential $Credential
}

# A password made only of letters and digits: it goes into an XML answer file and a registry value,
# and nothing in either has to be escaped.
function New-GuestPassword {
    $chars = [char[]] 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $bytes = [byte[]]::new(24)
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
}

Export-ModuleMember -Function Get-TestbedProfile, New-IsoFromFolder, Send-VMKey, Get-HostFreeGB, Assert-HostMemory, Wait-GuestSession, New-GuestPassword, Save-VMScreen, Wait-GuestIdle, Start-TestGuest
