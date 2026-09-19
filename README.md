# MPC-HC test framework

Integration tests for MPC-HC, run against the build of whichever branch this
repository is mounted in. It is mounted as the `tests\` submodule of an MPC-HC
checkout; nothing under `src/` depends on it, and a branch that never
initialises it is unaffected. Four submodules of its own carry the test
devices. The few player-side additions the suites drive live under `hooks\`
until they are upstream.

```powershell
# in any MPC-HC branch
git submodule add https://github.com/adipose/mpc-hc-tests.git tests
git submodule update --init --recursive tests
.\tests\hooks\Apply-TestHooks.ps1        # the player changes the suites need, as commits
```

```
Invoke-MpcTests.ps1   the orchestrator: probes every suite, claims a test
                      rig once (only if a runnable suite needs one), runs what
                      is runnable, aggregates results
unit/                 native unit tests: a console exe linking the player's
                      DSUtil/Subtitles/SubPic static libraries and exercising
                      pure logic (parsers, path/text/language helpers) with
                      fixture input -- no player, no rig, runs in seconds.
                      GoogleTest (submodule unit/googletest) plus MpcGtest.h
                      for expected failures and isolated tests, a fixture
                      corpus, and Invoke-UnitTests.ps1 to build and run it
emulator/             bda-vtuner (submodule): virtual DVB/ATSC BDA tuner
                      driver, generated transport streams, encoding matrix,
                      and the host-to-target transport every suite uses
cast-mock/            castv2-mock-device (submodule): mock Google Cast
                      receiver -- mDNS, TLS, CastV2 protobuf, adversarial
                      failure switches
vaudio/               vaudio-endpoint (submodule): virtual sound card that
                      records what is played to it -- stereo to 7.1, shared
                      and exclusive mode
vdisplay/             idd-vdisplay (submodule): virtual monitor that can be
                      plugged, unplugged and read back -- chosen modes, HDR on
                      Windows 11
suites/
  unit/               the unit tier as a suite: builds and runs unit/, needs
                      no rig (its probe reports NeedsRig = $false)
  dvb/                Digital TV: headless tuner scans (/dvbscan) against
                      the virtual tuner, channel records asserted against
                      the emulator's encoding matrix; deeper standalone
                      scripts for dialog-driven scans and rendered-frame
                      probes
  chromecast/         Cast sender behaviour against the mock receiver
                      (scaffold; see its README)
  dvb-playback/       Tunes channels on the virtual tuner; asserts each
                      channel's tone reaches the virtual sound card
  playback/           Plays generated clips; asserts on the audio and the
                      frames that reached a virtual sound card and a
                      virtual monitor on the target
  translations/       The checkout's .po files through the Translation
                      Studio's ruleset (potool, loaded from that sibling
                      repository); no rig
```

## Unit tests

The unit tier stands apart from the rest of the framework: it runs no player
and needs no rig, so it is the one tier that works on a bare bench.

```powershell
.\tests\unit\Invoke-UnitTests.ps1 -InitSubmodules   # first run: fetch libs, build, run
.\tests\unit\Invoke-UnitTests.ps1                   # thereafter: incremental build + run
.\tests\unit\Invoke-UnitTests.ps1 -NoBuild WebVTT,TextFile   # a subset, no rebuild
.\tests\unit\Invoke-UnitTests.ps1 -NoBuild -List
.\tests\Invoke-MpcTests.ps1 -Suite unit             # or through the orchestrator
```

It needs a Visual Studio with the C++ toolset and `nasm.exe` on `PATH` (libass
assembles its kernels with it), the same as the player's own build. The build
step fetches the submodules the linked libraries need, and GoogleTest, which is
compiled into the executable. Tests, fixtures and `MpcGtest.h` live in
`tests\unit`; the orchestrator wrapper is `suites\unit`. The executable is a
GoogleTest binary, so Visual Studio's Test Explorer finds the tests in
`MpcUnitTests.vcxproj` as they are, and every `--gtest_*` option works.

A suite is `suites/<name>/` with a README and an `Invoke-Suite.ps1`
implementing the contract documented in `Invoke-MpcTests.ps1`: `-Probe`
reports readiness cheaply, a run takes `-VMName`/`-OutDir`/`-PlayerBinary`
and returns pass/fail counts. Suites assert declared expectations rather
than golden images, and add a submodule where they need an external
dependency the way `dvb` uses the emulator and `chromecast` the cast mock.

## The feedback loop

The primary test surface is the headless scan: `mpc-hc64.exe /dvbscan
<start>-<stop> /dvbscanout <file>` scans without the dialog, writes the
channel records as JSON, and exits. Assertions read that file. The web
interface (`/dvb/channels.json`, same JSON) and the dialog-driven harness
remain as secondary surfaces -- useful precisely because they exercise
different player paths -- but nothing in the framework depends on them to
answer "did this build decode correctly".

`PLAN.md` sets out where this goes: the test contract (verbs, the `/slave`
control API, recorded observation) the framework asserts through, the
coverage map, and the smallest steps that complete the `dvb` and
`chromecast` suites.

## Hooks: what the player has to have

The suites reach the player through its command line and its `/slave`
API. A handful of verbs are additions for testing, small enough to be
proposed upstream one at a time (`/dvbscan` from #4138 already is). Until
each is merged it is a patch under `hooks\`, one commit each, exported from
the fork's `test-hooks` branch (upstream develop plus the hooks, rebased as
develop moves):

| Hook | Adds | Upstream |
|---|---|---|
| `0001-add-dvbscansave-…` | `/dvbscansave`: the headless scan stores the channels it found | clsid2/mpc-hc#4143 |
| `0002-make-a-headless-scan-…` | exit code 1 and no modal box when a headless scan cannot run | clsid2/mpc-hc#4143 |

`hooks\Apply-TestHooks.ps1 -Check` says which the checkout already has;
without `-Check` it applies the missing ones with `git am`. A branch that
would rather not carry the commits can merge `test-hooks` instead, or run
without them: every suite probes the built binary for the verb it needs and
reports itself not ready rather than failing.

## Setup

```powershell
git submodule update --init --recursive tests
.\tests\emulator\tools\Install-TestBed.ps1    # WDK ISO, TSDuck, ffmpeg, config
```

The installer creates `tests\testbed.config.psd1` (gitignored); edit it to
point at your target machine (emulator README, *Where it runs*). Then follow
the emulator README's Getting started through driver install and stream
provisioning, build MPC-HC per this repository's own docs, and:

```powershell
.\tests\Invoke-MpcTests.ps1 -List    # what is runnable, and why not
.\tests\Invoke-MpcTests.ps1          # run everything runnable
```

## Versioning

The player under test is the checkout this repository is mounted in --
there is no player pin. The branch's submodule commit pins the tests, and
this repository's own submodules pin the devices: `emulator` tracks
`master` of bda-vtuner, `cast-mock`, `vaudio` and `vdisplay` track `main`
of castv2-mock-device, vaudio-endpoint and idd-vdisplay. A bump commit is
the record of the tested pairing.
`suites/dvb/BdaRenderMap.ps1` documents which channel-record spellings the
player emits; revisit it when the JSON format changes.
