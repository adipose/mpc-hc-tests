# mpc-hc-tests

A test suite for MPC-HC. The player revision under test is pinned as a
submodule, so every commit here records exactly which MPC-HC was tested, with
what, and how it fared. Suites live side by side under `suites/`; each brings
its own dependencies as submodules where it needs them.

```
mpc-hc/       the MPC-HC revision under test (build per its own docs)
emulator/     bda-vtuner: virtual DVB/ATSC BDA tuner driver, generated
              transport streams, encoding matrix, host-to-target transport
              (dependency of the dvb suite)
cast-mock/    castv2-mock-device: a mock Google Cast receiver -- mDNS, TLS,
              CastV2 protobuf, adversarial failure switches (dependency of
              the chromecast suite)
suites/
  dvb/        Digital TV: scripted tuner scans, channel-record and
              /dvb/channels.json assertions against the emulator's encoding
              matrix, rendered-frame pixel probes
  chromecast/ Cast sender behaviour (clsid2/mpc-hc#4128) against the mock
              receiver (scaffold; see its README)
```

The shape generalises: a suite is `suites/<name>/` with a README, driving the
pinned player against declared expectations rather than golden images, adding
a submodule where it needs an external dependency the way `dvb` uses the
emulator and `chromecast` uses the cast mock. Natural candidates still open:
playback and format coverage, UI/theming captures, subtitle rendering.

## Setup

```powershell
git clone --recursive https://github.com/adipose/mpc-hc-tests
.\emulator\tools\Install-TestBed.ps1   # WDK ISO, TSDuck, ffmpeg, config
```

The installer downloads and hash-verifies every host-side prerequisite and
creates `testbed.config.psd1` at this root (it detects the submodule layout);
edit that file to point at your target. The config here is found by the
emulator's transport (nearest wins), so one file configures every suite that
drives a target machine. For the dvb suite: follow the emulator README's
Getting started through driver install and stream provisioning, build MPC-HC from `mpc-hc/`, deploy the built
`mpc-hc64.exe` with `LAVFilters64` beside it to the target, then run jobs
from `suites/dvb/` (its README documents each script).

## Versioning

Each submodule pins a SHA (the reproducibility anchor) and declares in
`.gitmodules` the branch it tracks (the intent):

- `mpc-hc` tracks `dvb-json-api` on the fork -- the PR branch carrying the
  enriched `/dvb/channels.json` the dvb suite asserts on. **When that PR
  merges upstream, repoint the submodule to `clsid2/mpc-hc` branch `develop`**
  (edit `.gitmodules` url+branch, `git submodule sync`, update, commit) and
  nothing else here changes.
- `emulator` tracks `master` of bda-vtuner.
- `cast-mock` tracks `main` of castv2-mock-device.

One submodule, one pin: when a suite targets a player branch that is not the
pinned one (the chromecast suite targets `patch666` / PR #4128 until it
merges), bump `mpc-hc` to that branch for the run and commit the bump -- two
suites wanting different player branches simply produce different pairing
commits.

To move to a branch's current tip: `git submodule update --remote <name>`,
re-run the affected suites, and commit the bump -- that commit is the record
of the tested pairing. `suites/dvb/BdaRenderMap.ps1` documents which MPC-HC
JSON spellings the pinned revision emits; revisit it on any player bump.
