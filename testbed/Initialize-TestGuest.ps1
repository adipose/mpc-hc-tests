<#
.SYNOPSIS
    Prepare a Windows 10 / 11 Hyper-V guest for the test suites: base settings, test signing, the
    virtual devices, verification, and a checkpoint to restore before each run.

.DESCRIPTION
    Works on a guest New-TestGuest.ps1 just built, or on one you already have, as long as it has a
    local administrator account that logs on at the console. Safe to run again: every step sets a
    state rather than toggling one.

    In order:
      1. Secure Boot off (the VM must be off for that), so test-signed drivers can load.
      2. In the guest, as its administrator account over PowerShell Direct:
           test signing on; rig-id.txt naming the VM; permanent autologon of the console account;
           no sleep, no hibernation, no lock screen, no automatic Windows Update or update reboots;
           Defender exclusions for the test folders; startup sound off. In the CONSOLE account's own
           hive (HKEY_USERS\<its SID>, never the connecting session's HKCU): no system sounds, no
           toast notifications, no screen saver, and MPC-HC's UpdaterAutoCheck=0 / DefaultCapture=1.
      3. A restart, after which test signing must read as on and Secure Boot as off.
      4. The virtual audio endpoint, display and camera, through
         suites\playback\Install-OutputDevices.ps1, which proves each one works (a tone captured, a
         frame captured, a camera recording with advancing frame numbers) and only then shuts the
         guest down and takes the checkpoint.

    Why each setting is there: a system sound once landed in an audio capture as a C/G chord; an
    update reboot mid-run kills a suite; a first-run "check for updates?" prompt inside MPC-HC's
    InitInstance leaves a player that looks healthy but skipped everything after the prompt; a
    host-side HKCU: write over PowerShell Direct lands in the connecting account's hive, not the
    console user's, so per-user settings silently go missing.

.PARAMETER ConfigPath
    The guest's test-bed config (New-TestGuest writes one beside the VM): its credential and console
    account. Default: <VmRoot>\<VMName>\testbed.config.psd1.

.PARAMETER VAudio / VDisplay / VCamera
    Checkouts of the three driver repositories with their builds under build\out\x64. Default: the
    MPC_TEST_VAUDIO / _VDISPLAY / _VCAMERA environment variables, else the submodules of this
    repository.

.PARAMETER SkipDevices
    Settings and test signing only: no virtual devices. The checkpoint is still taken.

.PARAMETER QuietOnly
    For a guest that is already built and in use (a pooled one): only the settings that keep other
    activity off the guest during a run -- no system sounds, toasts, Spotlight, firewall prompt,
    Search indexing or cloud content -- then a restart from inside, a shutdown and the checkpoint.
    Logon, test signing and the devices are left exactly as they are. Without -ConfigPath the
    guest's credential and console account come from the shared test-bed config (its Guests entry
    when it has one). Start it from the checkpoint it should build on; the new checkpoint gets its
    own name and the old one is kept, so the config's Checkpoint for the guest has to be moved to it.

.EXAMPLE
    .\Initialize-TestGuest.ps1 -VMName mpc-testbed-w11
    .\Initialize-TestGuest.ps1 -VMName mpc-testbed-w11 -VAudio C:\dev\vaudio-endpoint -VDisplay C:\dev\idd-vdisplay -VCamera C:\dev\avs-vcamera
    .\Initialize-TestGuest.ps1 -VMName win11-rig-1 -QuietOnly -CheckpointName quiet-20261011
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $VMName,
    [string] $ConfigPath,
    [string] $VmRoot = 'C:\dev\mpc-testbed-vms',
    [string] $VAudio,
    [string] $VDisplay,
    [string] $VCamera,
    [string] $CheckpointName = ('testbed-ready-' + (Get-Date -Format 'yyyyMMdd')),
    [double] $HostFloorGB = 4,
    [switch] $SkipDevices,
    [switch] $QuietOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Testbed.psm1') -Force
$testsRoot = Split-Path $PSScriptRoot -Parent

if ($QuietOnly -and -not $ConfigPath) {
    # A pooled guest has no config of its own beside the VM; the shared one names its account.
    . (Join-Path $testsRoot 'emulator\tools\GuestTransport.ps1')
    $config = Get-TestBedConfig -Guest $VMName
} else {
    if (-not $ConfigPath) { $ConfigPath = Join-Path (Join-Path $VmRoot $VMName) 'testbed.config.psd1' }
    if (-not (Test-Path $ConfigPath)) { throw "No test-bed config at $ConfigPath. New-TestGuest writes one; for a VM of your own, write one like it (Guest, CredentialPath, GuestConsoleUser)." }
    $config = Import-PowerShellDataFile $ConfigPath
    if ($config.Guest -ne $VMName) { throw "$ConfigPath is for $($config.Guest), not $VMName." }
}
$cred = Import-Clixml $config.CredentialPath
$consoleUser = $config.GuestConsoleUser

$vm = Get-VM -Name $VMName
if ($vm.Generation -ne 2) { throw "$VMName is Generation $($vm.Generation); this script handles Generation 2 (Windows 10 / 11) guests." }

# What keeps other activity off the guest while a suite runs, applied by both the full preparation and
# -QuietOnly. Over PowerShell Direct as the administrator, into the console account's own hive.
$quietSettings = {
    param($user)
    $ErrorActionPreference = 'Stop'
    function Set-Reg([string] $Path, [string] $Name, $Value, [string] $Type = 'DWord') {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
    }
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\BootAnimation' DisableStartupSound 1
    # No firewall prompt when a test program opens a listening socket. MPC-HC's web server does, and on
    # Windows 11 the "allow public and private networks?" dialog then sat over the dialog a case was
    # measuring. The suites only talk to 127.0.0.1, which the firewall never blocks.
    & netsh.exe advfirewall set allprofiles settings inboundusernotification disable | Out-Null
    # Less background work after boot: no Search indexing, no cloud content (Spotlight images, suggested
    # apps). A freshly restored Windows 11 guest was busy enough to start the player 2 s late in cases
    # that time its audio.
    Stop-Service -Name WSearch -Force -ErrorAction SilentlyContinue
    Set-Service -Name WSearch -StartupType Disabled -ErrorAction SilentlyContinue
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' DisableWindowsConsumerFeatures 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' DisableCloudOptimizedContent 1

    # The console account's own hive. It is loaded because the account is logged on (the session
    # was only handed over once its desktop existed).
    $sid = ([Security.Principal.NTAccount] $user).Translate([Security.Principal.SecurityIdentifier]).Value
    $hk = "Registry::HKEY_USERS\$sid"
    if (-not (Test-Path $hk)) { throw "The hive of $user ($sid) is not loaded: is $user logged on at the console?" }
    # No sounds, in the console account and in the hive Windows uses before anyone has logged on (.DEFAULT):
    # a chime at boot was captured on Windows 11 even with the console account silenced. Any sound shares the
    # endpoint stream with the player, so it can also join two cases' audio into one capture or split one.
    foreach ($soundHive in $hk, 'Registry::HKEY_USERS\.DEFAULT') {
        Set-Reg "$soundHive\AppEvents\Schemes" '(default)' '.None' String
        Get-ChildItem "$soundHive\AppEvents\Schemes\Apps" -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -eq '.Current' } |
            ForEach-Object { Set-ItemProperty -Path $_.PSPath -Name '(default)' -Value '' }
    }
    Set-Reg "$hk\Software\Microsoft\Windows\CurrentVersion\PushNotifications" ToastEnabled 0
    # Spotlight, a per-user policy: on the desktop (Windows 11's rotating background with its "Learn about
    # this picture" icon) and on the lock screen.
    Set-Reg "$hk\Software\Policies\Microsoft\Windows\CloudContent" DisableWindowsSpotlightFeatures 1
    Set-Reg "$hk\Software\Policies\Microsoft\Windows\CloudContent" DisableSpotlightCollectionOnDesktop 1
    Set-Reg "$hk\Control Panel\Desktop" ScreenSaveActive '0' String
    $sid
}

if ($QuietOnly) {
    if ((Get-VM $VMName).State -ne 'Running') { Assert-HostMemory -VMName $VMName -FloorGB ($HostFloorGB + (Get-VM $VMName).MemoryStartup / 1GB); Start-VM -Name $VMName }
    $session = Wait-GuestSession -VMName $VMName -Credential $cred -TimeoutMinutes 15 -FloorGB $HostFloorGB -Activity 'starting'
    $sid = Invoke-Command -Session $session -ScriptBlock $quietSettings -ArgumentList $consoleUser
    # Restart from inside (see step 3 below) so the policies and the logon-time state come up as a run will see them.
    Invoke-Command -Session $session { Restart-Computer -Force }
    Remove-PSSession $session -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 30
    $session = Wait-GuestSession -VMName $VMName -Credential $cred -TimeoutMinutes 15 -FloorGB $HostFloorGB -Activity 'restarting'
    $check = Invoke-Command -Session $session -ArgumentList $sid {
        param($sid)
        [pscustomobject]@{
            Scheme = (Get-ItemProperty "Registry::HKEY_USERS\$sid\AppEvents\Schemes").'(default)'
            Toasts = (Get-ItemProperty "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\PushNotifications").ToastEnabled
            Search = (Get-Service WSearch).StartType
        }
    }
    Remove-PSSession $session
    if ($check.Scheme -ne '.None' -or $check.Toasts -ne 0) { throw "After the restart the console account's sound scheme is '$($check.Scheme)' and ToastEnabled $($check.Toasts)." }
    Write-Host "  quiet settings applied for $consoleUser ($sid): sounds $($check.Scheme), toasts off, Search $($check.Search)" -ForegroundColor Green
    Stop-VM -Name $VMName -Force     # a shutdown from inside; -TurnOff would be the hard one
    Get-VMSnapshot -VMName $VMName -Name $CheckpointName -ErrorAction SilentlyContinue | Remove-VMSnapshot
    Checkpoint-VM -Name $VMName -SnapshotName $CheckpointName
    Write-Host "  shut down; checkpoint '$CheckpointName' taken" -ForegroundColor Green
    return
}

# Every harness script below finds the guest's credential through this, not the machine's shared config.
$previousConfig = $env:VTUNER_TESTBED_CONFIG
$env:VTUNER_TESTBED_CONFIG = (Resolve-Path $ConfigPath).Path
try {
    # --- 1. firmware -----------------------------------------------------------------
    if ((Get-VMFirmware -VMName $VMName).SecureBoot -ne 'Off') {
        if ((Get-VM $VMName).State -ne 'Off') { Stop-VM -Name $VMName -Force }
        Set-VMFirmware -VMName $VMName -EnableSecureBoot Off
        Write-Host "  Secure Boot off"
    }

    # --- 2. settings in the guest -------------------------------------------------------
    if ((Get-VM $VMName).State -ne 'Running') { Assert-HostMemory -VMName $VMName -FloorGB ($HostFloorGB + (Get-VM $VMName).MemoryStartup / 1GB); Start-VM -Name $VMName }
    $session = Wait-GuestSession -VMName $VMName -Credential $cred -TimeoutMinutes 15 -FloorGB $HostFloorGB -Activity 'starting'
    $summary = Invoke-Command -Session $session -ArgumentList $VMName, $consoleUser, $cred.GetNetworkCredential().Password {
        param($vmName, $user, $pw)
        $ErrorActionPreference = 'Stop'
        # Create a key only when it is missing: New-Item -Force on a key that exists recreates it empty.
        function Set-Reg([string] $Path, [string] $Name, $Value, [string] $Type = 'DWord') {
            if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
            New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
        }

        # Checked here rather than only after the restart: on the first build of mpc-testbed-w11 this call
        # failed without a word (its output went to Out-Null) and only the post-restart check noticed.
        $bcdOut = (& bcdedit.exe /set testsigning on 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { throw "bcdedit /set testsigning on failed ($LASTEXITCODE): $bcdOut" }
        if (-not ((& bcdedit.exe /enum '{current}' | Out-String) -match 'testsigning\s+Yes')) { throw "bcdedit reported success but {current} has no testsigning Yes: $bcdOut" }
        if (-not (Test-Path 'C:\vtuner')) { New-Item -ItemType Directory 'C:\vtuner' | Out-Null }
        [IO.File]::WriteAllText('C:\vtuner\rig-id.txt', $vmName)

        $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        Set-Reg $winlogon AutoAdminLogon '1' String
        Set-Reg $winlogon DefaultUserName $user String
        Set-Reg $winlogon DefaultPassword $pw String
        Set-Reg $winlogon DefaultDomainName $env:COMPUTERNAME String
        Remove-ItemProperty -Path $winlogon -Name AutoLogonCount -ErrorAction SilentlyContinue

        & powercfg.exe /change standby-timeout-ac 0 | Out-Null
        & powercfg.exe /change monitor-timeout-ac 0 | Out-Null
        & powercfg.exe /hibernate off | Out-Null
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization' NoLockScreen 1
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' NoAutoUpdate 1
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' NoAutoRebootWithLoggedOnUsers 1
        $defender = 'skipped'
        try { Add-MpPreference -ExclusionPath 'C:\mpc-test', 'C:\vaudio', 'C:\vdisplay', 'C:\vcamera', 'C:\vtuner'; $defender = 'excluded' } catch { $defender = "not set: $($_.Exception.Message)" }

        # The console account's own hive. It is loaded because the account is logged on (the session
        # was only handed over once its desktop existed).
        $sid = ([Security.Principal.NTAccount] $user).Translate([Security.Principal.SecurityIdentifier]).Value
        $hk = "Registry::HKEY_USERS\$sid"
        if (-not (Test-Path $hk)) { throw "The hive of $user ($sid) is not loaded: is $user logged on at the console?" }
        Set-Reg "$hk\Software\MPC-HC\MPC-HC\Settings" UpdaterAutoCheck 0
        Set-Reg "$hk\Software\MPC-HC\MPC-HC\Settings" DefaultCapture 1

        $os = Get-CimInstance Win32_OperatingSystem
        [pscustomobject]@{ Os = "$($os.Caption) $($os.Version)"; ConsoleSid = $sid; Defender = $defender }
    }
    Invoke-Command -Session $session -ScriptBlock $quietSettings -ArgumentList $consoleUser | Out-Null
    Remove-PSSession $session
    Write-Host "  settings applied: $($summary.Os); console $consoleUser ($($summary.ConsoleSid)); Defender $($summary.Defender)"

    # --- 3. restart for test signing, and check it took -----------------------------------
    # A Windows restart from inside the guest, never Restart-VM: its default is a hard reset, which loses the
    # BCD change just made (the store's registry hive is written to disk lazily). Seen twice on the first
    # mpc-testbed-w11 builds: test signing set and read back, then gone after the reset; one of those resets
    # left a guest that only booted into Automatic Repair.
    $session = New-PSSession -VMName $VMName -Credential $cred
    Invoke-Command -Session $session { Restart-Computer -Force }
    Remove-PSSession $session -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 30
    $session = Wait-GuestSession -VMName $VMName -Credential $cred -TimeoutMinutes 15 -FloorGB $HostFloorGB -Activity 'restarting'
    $state = Invoke-Command -Session $session {
        $bcd = (& bcdedit.exe /enum '{current}' | Out-String)
        $secure = try { Confirm-SecureBootUEFI } catch { $false }
        [pscustomobject]@{ TestSigning = [bool] ($bcd -match 'testsigning\s+Yes'); SecureBoot = $secure; RigId = (Get-Content 'C:\vtuner\rig-id.txt' -Raw) }
    }
    Remove-PSSession $session
    if (-not $state.TestSigning -or $state.SecureBoot) { throw "After the restart test signing is $($state.TestSigning) and Secure Boot $($state.SecureBoot): the virtual devices would not load." }
    Write-Host "  test signing on, Secure Boot off, rig-id $($state.RigId)" -ForegroundColor Green

    # --- 4. devices, verification, checkpoint ------------------------------------------------
    # A rerun on the same day would take a second checkpoint of the same name, and a restore by name would
    # then be ambiguous. The guest has already moved on from it, so it goes.
    Get-VMSnapshot -VMName $VMName -Name $CheckpointName -ErrorAction SilentlyContinue | Remove-VMSnapshot
    if ($SkipDevices) {
        Stop-VM -Name $VMName -Force
        Checkpoint-VM -Name $VMName -SnapshotName $CheckpointName
        Write-Host "  no devices (-SkipDevices); shut down, checkpoint '$CheckpointName' taken" -ForegroundColor Green
        return
    }
    foreach ($pair in @(@('VAudio', $VAudio, 'MPC_TEST_VAUDIO'), @('VDisplay', $VDisplay, 'MPC_TEST_VDISPLAY'), @('VCamera', $VCamera, 'MPC_TEST_VCAMERA'))) {
        if ($pair[1]) { Set-Item "env:$($pair[2])" (Resolve-Path $pair[1]).Path }
    }
    Assert-HostMemory -VMName $VMName -FloorGB $HostFloorGB
    & (Join-Path $testsRoot 'suites\playback\Install-OutputDevices.ps1') -VMName $VMName -CheckpointName $CheckpointName -ConsoleUser $consoleUser
}
finally {
    $env:VTUNER_TESTBED_CONFIG = $previousConfig
}
