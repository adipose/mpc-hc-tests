# playback suite

Plays generated clips in the player under test and asserts on what reached
the output devices -- not on what the player says it did.

```
New-PlaybackClips.ps1     ffmpeg-synthesised clips and clips.json, the
                          declaration of what each contains (media\, gitignored)
Invoke-Suite.ps1          the suite: deploy the player, run the cases, assert
Run-PlayerCase.guest.ps1  target side: start the player in the console session,
                          grab a frame part-way, wait for it to exit
```

## How a case works

1. A fresh portable profile: `mpc-hc64.ini` is written beside the deployed
   exe, so the player runs in ini mode and nothing carries over from the last
   case or the guest's history. `UpdaterAutoCheck=0` is always in it; without
   it an unattended player sits behind its first-run prompt. A case that is
   the second run of a scenario keeps the history file
   (`mpc-hc64.history.ini`, where positions and track choices live) and
   rewrites only the settings.
2. The player is started from the command line in the console session
   (`<clip> /play /close`, plus whatever the case is about) and left alone,
   or, for a scenario that ends part-way, sent WM_CLOSE at a given time so
   that its own shutdown runs.
3. Evidence is collected from outside the player:
   - **sound** -- the WAV the virtual audio endpoint wrote while the case
     ran, checked by `wavcheck.py`: tone per channel, and how long it lasted.
     One WAV per render stream: a player that opens a second file (next
     file in folder) leaves two, in order, and a case can assert on each;
   - **picture** -- the frame the virtual monitor was sent, captured by
     `vdisplayctl` part-way through: the colour a quarter of the way in from
     each corner of where the fitted picture should be;
   - **process** -- exited by itself, exit code 0.

The clips are built so that content identifies itself: four flat colour
quadrants (orientation), a different sine per channel and per audio track
(which track, which channel), and a subtitle track that draws one solid
band in a colour of its own (which track was rendered). Nothing is compared
against a stored image.

One observation from writing the subtitle cases, not asserted: the internal
renderer put the ASS drawing (`{n5\pos(640,360)\p1}`, an 800x120 box
around the origin) with its bottom-right corner at the position, scaled 1.2x
horizontally and 1.5x vertically on a 1920x1080 screen, where libass would
centre the box there. The band cases only ask which colour is present.

## Cases

| Case | Asserts | Tracker history |
|---|---|---|
| `plays-to-end-and-exits` | `/play /close` exits 0 by itself; 4.0 s of audio, 440 Hz left, 880 Hz right | the baseline the others stand on |
| `default-audio-track` | of two tracks, the one flagged default in the container plays | #99, #1551, #2093, #2673, #3935 |
| `fullscreen-second-monitor` | `/fullscreen /monitor 2` fills the second (virtual) monitor, right way up | #1614, #2859, #2892 |
| `rotation-metadata` | 90 degrees of display rotation is honoured, in the direction ffmpeg's autorotation renders it | #375, #3832, #3909 |
| `remember-position-first-run` | with the option on, closing the window 8 s into a 20 s clip leaves that position in `mpc-hc64.history.ini`, and 8 s of audio was heard | #1595, #1805, #2287, #2659, #3182, #3352, #3847 |
| `remember-position-resumes` | opening the clip again on the same profile plays the remaining 12 s, not 20 | same |
| `remember-position-off-starts-over` | with the option off and the position still on file, the whole 20 s plays | same |
| `repeat-file-forever` | `Loop=1 LoopMode=0`: the 4 s clip is still sounding, same tones, when the window is closed at 10 s | #1691, #1850, #2488, #3324, #3738 |
| `next-file-in-folder` | `AfterPlayback=1`: a.mkv is followed by b.mkv from the same folder, two captures with the two clips' tones | #414, #697, #1419, #2200, #2209, #2579 |
| `default-subtitle-track` | of two ASS tracks, the one flagged default is rendered: its cyan band is in the frame, not track 1's magenta one | #1551, #2452, #2876, #3283, #3914 |
| `external-subtitle-autoload` | `ext.ass` beside `ext.mkv` is loaded unasked and rendered (magenta band) | #1121, #1164, #1894, #3152 |
| `mpcvr-sdr-range` | MPC Video Renderer: 8 bit BT.709 at Y 128 limited comes out at 130.4, the 16-235 expansion | |
| `mpcvr-hdr-to-sdr-125` | 10 bit PQ 0.65 converted to SDR for a 125 nit display comes out at 233.3 | |
| `mpcvr-hdr-to-sdr-200` | the same clip for a 200 nit display comes out at 206.7, and not at the 125 nit level | |
| `mpcvr-hdr-to-sdr-dark` | 10 bit PQ 0.25 for a 200 nit display comes out at 35.2 | |
| `filters-reset-once-from-version-8` | a profile at `SettingsVersion=8` with two internal filters set to 0 comes back at version 9 with both re-enabled | a0735130e |
| `filters-kept-off-at-version-9` | the same profile at the current version keeps both filters at 0: the reset runs once, not on every launch | a0735130e |

`-Case <pattern>` runs only the cases whose name matches (one pattern per
argument, `-like` wildcards), e.g. `-Case default-audio-track` or
`-Case 'remember-position-*'`. A skipped case is not counted at all.

Each was checked the other way round when written: the default-track capture
is rejected against the other track's tone, the stereo capture against
swapped channels, so a pass means something. The two PQ 0.65 cases are each
other's control: the same clip at two display targets must come out at two
different levels, so a stuck value cannot pass both.

The renderer cases differ from the rest in three ways:

- MPC Video Renderer keeps its settings in the registry, not the player's ini,
  under the user that runs the player. `Invoke-PlayerCase -Renderer` hands them
  to `Run-PlayerCase.guest.ps1`, which applies them as that user and puts back
  what was there.
- The ini pins `LastGPUCheck` and the LAV `HWAccel`. Without them MPC-HC writes
  `UseD3D11` back to 1 on a fresh profile, and a Direct3D 9 case would quietly
  run on Direct3D 11.
- The clips are flat fields, 25 s long, captured at 12 s. On a guest with no
  GPU the renderer takes several seconds to start and compiles its shaders, so
  at 3 s the frame is still the player's logo. The expected level is worked out
  from the clip's declaration by `Get-FieldLevel`, not read off another
  renderer, and `New-PlaybackClips.ps1` refuses to write a clip that does not
  decode back to the code value it was given.

## What it needs on the target

Two virtual devices, siblings of the tuner emulator:

- **vaudio-endpoint** -- a sound card that records what is played to it;
- **idd-vdisplay** -- a monitor that can be plugged, unplugged and read back.

Both work on a guest with no GPU and no audio hardware, and both are
submodules here (`tests\vaudio`, `tests\vdisplay`). Running the suite against
a provisioned guest needs them checked out, not built; building
(`tools\Install-Toolchain.ps1`, then `tools\Build.ps1`, in each) is only for
installing the drivers. `$env:MPC_TEST_VAUDIO` and `$env:MPC_TEST_VDISPLAY`
point the suite at other checkouts.

`Install-OutputDevices.ps1` provisions one guest: installs both drivers,
proves each works there (a plug/capture/unplug, and a two-tone played and read
back), and checkpoints the result. On a pooled rig, run it for every guest with
the pool closed to claims.

Installing a driver changes what a guest *is*, so the suite does not do it
unasked. If the devices are absent it reports that and counts itself skipped.
`-InstallDrivers` installs them first: use it on a guest you hold and will
revert, or as part of provisioning a pool.

```powershell
.\tests\suites\playback\Invoke-Suite.ps1 -VMName <guest> -OutDir <dir> `
    -PlayerBinary <path\to\mpc-hc64.exe> [-InstallDrivers]
```

Artefacts per case land in `-OutDir`: the guest's JSON, the captured WAV and
the captured PNG, so a failure can be looked at rather than re-run.

## Not yet here

Anything that needs to *drive* a running player (seek, switch track, change
rate) waits for the `/slave` host described in `..\..\PLAN.md`; these cases
use only the command line. HDR cases need a Windows 11 guest (the virtual
monitor does HDR there) and a renderer that outputs HDR.
