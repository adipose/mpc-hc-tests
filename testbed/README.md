# testbed

Build and prepare a Hyper-V guest for the suites, unattended, on any Windows host
with Hyper-V. Membership of the Hyper-V Administrators group is enough; no
elevated shell.

```
.\New-TestGuest.ps1 -Name mpc-testbed-w11 -Os 11 -DownloadEval
.\New-TestGuest.ps1 -Name mpc-testbed-w10 -Os 10 -Iso D:\iso\Win10_22H2_x64.iso -ImageIndex 6
.\Initialize-TestGuest.ps1 -VMName <a guest you already have>
```

Then run any suite against it:

```
$env:VTUNER_TESTBED_CONFIG = 'C:\dev\mpc-testbed-vms\mpc-testbed-w11\testbed.config.psd1'
Import-Module .\Testbed.psm1
$cred = Import-Clixml C:\dev\mpc-testbed-vms\mpc-testbed-w11\guest.cred.xml
Start-TestGuest -VMName mpc-testbed-w11 -Credential $cred -Checkpoint testbed-ready-<date>
..\suites\playback\Invoke-Suite.ps1 -VMName mpc-testbed-w11 -PlayerBinary <exe>
Stop-VM mpc-testbed-w11
```

`Start-TestGuest` restores the checkpoint, boots, waits for the console
account's desktop and then for the guest to go idle (total CPU under 10% for
30 s, giving up after 10 minutes with a warning). A guest just booted is busy
for minutes, and on Windows 11 that started the player late enough to fail
cases that time its audio; a fixed sleep was either too short or wasted.

## Adding a built guest to a shared config or pool

A guest with its own account and checkpoint joins a shared
`testbed.config.psd1` through a `Guests` entry, which `Get-TestBedConfig` and
`Connect-TestGuest` (emulator\tools\GuestTransport.ps1) apply whenever that
guest is the one being driven:

```
Guests = @{
    'mpc-testbed-w11' = @{
        CredentialPath   = 'C:\dev\mpc-testbed-vms\mpc-testbed-w11\guest.cred.xml'
        GuestConsoleUser = 'mpctest'
        Checkpoint       = 'testbed-ready-20261011'
    }
}
```

A session that was handed the guest then needs only its name:
`Restore-TestGuest -Guest mpc-testbed-w11` (its own checkpoint, boot, desktop,
idle), and every suite with `-VMName mpc-testbed-w11`. The credential file is
DPAPI-encrypted for the account that built the guest, so the config must be
used by that same Windows account.

A guest that was set up some other way (the original pool) can still be noisy:
system sounds, toasts, Spotlight, Search. A sound shares the endpoint stream
with the player, and on win11-rig-1 one bridged two cases into a single 30 s
capture. `Initialize-TestGuest.ps1 -VMName <guest> -QuietOnly -CheckpointName
<name>` applies just those settings, leaving logon, test signing and the
devices alone, and takes a new checkpoint beside the old one. Point the
guest's `Checkpoint` in the config at it.

## What each script does

`New-TestGuest.ps1` creates the VM (Generation 2, fixed memory, a virtual TPM
where the host can make one), boots the Windows ISO with a generated answer
file on a second small ISO, waits until the console account has logged on,
removes both ISOs and hands over to `Initialize-TestGuest.ps1`. The answer file
is filled from `unattend\`; the ISO that carries it is written with Windows'
own IMAPI2, so no ADK is needed, and it is deleted after Setup because it holds
the account's password in clear text.

`Initialize-TestGuest.ps1` turns Secure Boot off, then over PowerShell Direct:
test signing on, `C:\vtuner\rig-id.txt`, permanent autologon, no sleep, lock
screen, automatic updates or update reboots, Defender exclusions for the test
folders, no firewall prompts, no Search indexing or cloud content; and in the
console account's own hive (Spotlight off too) (never the connecting session's
`HKCU:`) no system sounds, notifications or screen saver, and MPC-HC's
`UpdaterAutoCheck=0` and `DefaultCapture=1`. After a restart it checks test
signing took, then installs and verifies the virtual audio endpoint, display
and camera with `suites\playback\Install-OutputDevices.ps1`, and only a guest
that passes is shut down and checkpointed. Run it again at any time; every step
sets a state.

## Files beside the VM

`<VmRoot>\<Name>\` (default `C:\dev\mpc-testbed-vms`) holds the disk,
`guest.cred.xml` (the console account's credential, DPAPI-encrypted for the
user who built the guest) and `testbed.config.psd1`, a config for this guest
alone. Pointing `VTUNER_TESTBED_CONFIG` at it is what lets the suites find the
guest's credential without touching the shared config or the pool broker.

## Windows versions (`profiles.psd1`)

| | image | VM | transport | virtual devices |
|---|---|---|---|---|
| 11 | your ISO, or `-DownloadEval` (90-day Enterprise evaluation, 8 GB) | Gen 2, vTPM | PowerShell Direct | audio, display, camera |
| 10 | your ISO | Gen 2 | PowerShell Direct | audio, display, camera |
| 7 | your ISO and key | Gen 1 | WinRM | none: not implemented yet |

Windows 7 needs a Generation 1 VM and the WinRM transport (PowerShell Direct
needs Windows 10 or later in the guest), and the indirect display driver model
the virtual display uses starts at Windows 10 1607. It would be a target for
the cases that need no devices.

## Limits worth knowing

- Host memory: the guest gets fixed memory (4 GB by default) and the scripts
  turn it off if the host's free memory falls under `-HostFloorGB` (4 GB) while
  they wait. Turn the guest off when it is not in use.
- The evaluation expires after 90 days. Rebuilding is one command.
- The tuner emulator (the dvb suites) is not installed by these scripts yet.
- The driver binaries must be built (`tools\Build.ps1` in each driver
  repository, which needs the WDK). Point `-VAudio`, `-VDisplay`, `-VCamera` at
  the checkouts that hold the builds.
