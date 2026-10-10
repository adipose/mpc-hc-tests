<#
.SYNOPSIS
    Build a new Hyper-V test guest from a Windows ISO, unattended, then prepare it with
    Initialize-TestGuest.ps1.

.DESCRIPTION
    Creates the VM, boots the ISO with a generated answer file on a second small ISO, waits for Setup
    to finish and the console account to log on, removes the install media, and hands over to
    Initialize-TestGuest.ps1 (base settings, test signing, the virtual devices, verification, a
    checkpoint).

    Needs membership of Hyper-V Administrators, not an elevated shell.

    Everything the VM needs to be driven later lands in <VmRoot>\<Name>:
      <Name>.vhdx              the disk
      guest.cred.xml           the console account's credential, DPAPI-encrypted for the user who
                               built it (Import-Clixml on another account cannot read it)
      testbed.config.psd1      a test-bed config for this guest alone. Point a run at it with
                                 $env:VTUNER_TESTBED_CONFIG = '<that path>'
                               and every suite's -VMName <Name> uses this guest's credential and
                               console user, with no pool broker involved.

    The answer file holds the account's password in clear text, as Windows Setup requires. It
    exists only on the answer ISO, which is deleted once Setup is done.

.PARAMETER Os
    11, 10 or 7 (profiles.psd1). 7 is not implemented yet: it needs a Generation 1 VM and the WinRM
    transport, since PowerShell Direct needs Windows 10 or later in the guest.

.PARAMETER Iso
    A Windows ISO you provide. Required for 10 and 7.

.PARAMETER DownloadEval
    Windows 11 only: download the 90-day Enterprise evaluation into -ImageCache (8 GB) if it is not
    there already, and use it.

.PARAMETER ImageIndex
    Which image in the ISO's install.wim/esd to install. The evaluation ISO has one; a retail ISO
    lists several editions, and index 1 is usually Home.

.PARAMETER ProductKey
    Optional. A retail ISO may need one to pick the edition without asking.

.PARAMETER VAudio / VDisplay / VCamera
    Passed to Initialize-TestGuest.ps1: checkouts of the driver repositories holding their builds.

.EXAMPLE
    .\New-TestGuest.ps1 -Name mpc-testbed-w11 -Os 11 -DownloadEval
    .\New-TestGuest.ps1 -Name mpc-testbed-w10 -Os 10 -Iso D:\iso\Win10_22H2_x64.iso -ImageIndex 6
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidatePattern('^[A-Za-z0-9-]{1,40}$')] [string] $Name,
    [Parameter(Mandatory)] [ValidateSet('7', '10', '11')] [string] $Os,
    [string] $Iso,
    [switch] $DownloadEval,
    [int] $ImageIndex = 1,
    [string] $ProductKey,
    [string] $VmRoot = 'C:\dev\mpc-testbed-vms',
    [string] $ImageCache = 'C:\dev\mpc-testbed-images',
    [string] $User = 'mpctest',
    [int] $MemoryGB = 4,
    [int] $Cpu = 4,
    [int] $DiskGB = 80,
    [string] $SwitchName = 'Default Switch',
    [double] $HostFloorGB = 4,
    [string] $VAudio,
    [string] $VDisplay,
    [string] $VCamera,
    [switch] $SkipInitialize
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Testbed.psm1') -Force

$osProfile = Get-TestbedProfile $Os
if ($Os -eq '7') { throw 'Windows 7 guests are not implemented yet (Generation 1 and the WinRM transport). See README.md.' }
if (Get-VM -Name $Name -ErrorAction SilentlyContinue) { throw "A VM named $Name already exists. Pick another name, or run Initialize-TestGuest.ps1 on it." }

# --- the image -------------------------------------------------------------------

if (-not $Iso) {
    if (-not $DownloadEval) { throw "Give -Iso, or -DownloadEval for Windows 11." }
    if (-not $osProfile.Download) { throw "There is no evaluation download for Windows $Os; give -Iso." }
    if (-not (Test-Path $ImageCache)) { New-Item -ItemType Directory $ImageCache | Out-Null }
    $Iso = Join-Path $ImageCache $osProfile.Download.Name
    if (-not (Test-Path $Iso)) {
        Write-Host "downloading the Windows $Os evaluation to $Iso (about 8 GB)"
        # The fwlink redirects to a dated file; BITS follows it and resumes after interruptions.
        Start-BitsTransfer -Source $osProfile.Download.Url -Destination $Iso -DisplayName "testbed $Name" -Priority Foreground
    }
}
$Iso = (Resolve-Path $Iso).Path

# --- the VM's folder, credential and config -----------------------------------

$vmDir = Join-Path $VmRoot $Name
if (Test-Path $vmDir) { throw "$vmDir already exists; remove it or pick another name." }
New-Item -ItemType Directory -Force $vmDir | Out-Null

$password = New-GuestPassword
$cred = [pscredential]::new($User, (ConvertTo-SecureString $password -AsPlainText -Force))
$credPath = Join-Path $vmDir 'guest.cred.xml'
$cred | Export-Clixml $credPath

$configPath = Join-Path $vmDir 'testbed.config.psd1'
@"
# Test-bed config for the guest $Name alone, written by New-TestGuest.ps1.
# Use it for a run with: `$env:VTUNER_TESTBED_CONFIG = '$configPath'
@{
    Transport        = '$($osProfile.Transport)'
    Guest            = '$Name'
    CredentialPath   = '$credPath'
    RequireRigId     = `$true
    GuestConsoleUser = '$User'
    Os               = '$Os'
}
"@ | Set-Content $configPath -Encoding utf8

# --- the answer file ---------------------------------------------------------------

$answerDir = Join-Path $vmDir 'answer'
New-Item -ItemType Directory -Force $answerDir | Out-Null
$xml = Get-Content (Join-Path $PSScriptRoot "unattend\$($osProfile.Unattend)") -Raw
$fields = @{
    LOCALE       = 'en-US'
    IMAGEINDEX   = "$ImageIndex"
    PRODUCTKEY   = $(if ($ProductKey) { "<ProductKey><Key>$ProductKey</Key><WillShowUI>OnError</WillShowUI></ProductKey>" } else { '' })
    COMPUTERNAME = ($Name -replace '[^A-Za-z0-9-]', '').Substring(0, [math]::Min(15, ($Name -replace '[^A-Za-z0-9-]', '').Length))
    TIMEZONE     = (Get-TimeZone).Id
    USER         = $User
    PASSWORD     = $password
}
foreach ($k in $fields.Keys) { $xml = $xml.Replace("{{$k}}", $fields[$k]) }
if ($xml -match '\{\{[A-Z]+\}\}') { throw "answer file template has an unfilled field: $($Matches[0])" }
[xml] $xml | Out-Null     # well-formed, or stop here rather than at Setup
[IO.File]::WriteAllText((Join-Path $answerDir 'autounattend.xml'), $xml, [Text.UTF8Encoding]::new($false))
$answerIso = Join-Path $vmDir 'answer.iso'
New-IsoFromFolder -Folder $answerDir -Path $answerIso
Remove-Item $answerDir -Recurse -Force
$password = $null

# --- the VM --------------------------------------------------------------------------

Write-Host "creating $Name (Windows $Os, Generation $($osProfile.Generation), $MemoryGB GB fixed, $Cpu vCPU, $DiskGB GB disk)"
$vhd = Join-Path $vmDir "$Name.vhdx"
New-VM -Name $Name -Generation $osProfile.Generation -MemoryStartupBytes ($MemoryGB * 1GB) -NewVHDPath $vhd -NewVHDSizeBytes ($DiskGB * 1GB) -SwitchName $SwitchName -Path $VmRoot | Out-Null
Set-VMMemory -VMName $Name -DynamicMemoryEnabled $false -StartupBytes ($MemoryGB * 1GB)
Set-VMProcessor -VMName $Name -Count $Cpu
# Checkpoints are taken deliberately (Initialize-TestGuest ends in one); none behind anyone's back.
Set-VM -Name $Name -AutomaticCheckpointsEnabled $false -CheckpointType Standard -AutomaticStopAction ShutDown
Enable-VMIntegrationService -VMName $Name -Name 'Guest Service Interface'
if ($osProfile.Tpm) {
    try { Set-VMKeyProtector -VMName $Name -NewLocalKeyProtector; Enable-VMTPM -VMName $Name; Write-Host '  virtual TPM enabled' }
    catch { Write-Host "  no virtual TPM ($($_.Exception.Message.Split([char]10)[0])); the answer file's LabConfig bypass covers Setup" -ForegroundColor Yellow }
}
$dvd = Add-VMDvdDrive -VMName $Name -Path $Iso -Passthru
Add-VMDvdDrive -VMName $Name -Path $answerIso
Set-VMFirmware -VMName $Name -FirstBootDevice $dvd

# --- install ----------------------------------------------------------------------------

Assert-HostMemory -VMName $Name -FloorGB ($HostFloorGB + $MemoryGB)   # room for the VM on top of the floor
Start-VM -Name $Name
Write-Host "  started; answering the DVD boot prompt"
Send-VMKey -VMName $Name
$t0 = Get-Date
$session = Wait-GuestSession -VMName $Name -Credential $cred -TimeoutMinutes 90 -FloorGB $HostFloorGB -Activity 'installing'
$info = Invoke-Command -Session $session { $o = Get-CimInstance Win32_OperatingSystem; "$($o.Caption) $($o.Version)" }
Remove-PSSession $session
Write-Host ("  installed in {0:N0} min: {1}" -f ((Get-Date) - $t0).TotalMinutes, $info) -ForegroundColor Green

# The media go: the answer ISO holds the password in clear text, and a DVD first in the boot order
# would offer to start Setup again on every boot.
Stop-VM -Name $Name -Force
Get-VMDvdDrive -VMName $Name | Remove-VMDvdDrive
Remove-Item $answerIso -Force
Set-VMFirmware -VMName $Name -FirstBootDevice (Get-VMHardDiskDrive -VMName $Name)

if ($SkipInitialize) { Write-Host "  left off; run Initialize-TestGuest.ps1 -VMName $Name next"; return }
$deviceArgs = @{}
if ($VAudio) { $deviceArgs.VAudio = $VAudio }; if ($VDisplay) { $deviceArgs.VDisplay = $VDisplay }; if ($VCamera) { $deviceArgs.VCamera = $VCamera }
& (Join-Path $PSScriptRoot 'Initialize-TestGuest.ps1') -VMName $Name -ConfigPath $configPath -HostFloorGB $HostFloorGB @deviceArgs
