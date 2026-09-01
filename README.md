# mpc-dvb-tests

Integration tests for MPC-HC's Digital TV support, run against the
**bda-vtuner** software tuner. Both dependencies are pinned as submodules, so
every commit here records exactly which emulator revision was tested against
exactly which MPC-HC revision.

```
emulator/   bda-vtuner: virtual BDA driver, stream generation, encoding
            matrix, host-to-target transport (see its README to set up the
            tuner first)
mpc-hc/     the MPC-HC revision under test (build it per its own docs; deploy
            the built mpc-hc64.exe with LAVFilters64 beside it to the target)
harness/    the tests: scripted scans, channel-record and /dvb/channels.json
            assertions against the emulator's matrix, rendered-frame pixel
            probes
```

## Setup

```powershell
git clone --recursive <this repo>
Copy-Item emulator\testbed.sample.psd1 testbed.config.psd1   # then edit
```

The config at this root is found by the emulator's transport (nearest wins),
so one file configures everything. Follow the emulator README's Getting
started through driver install and stream provisioning, build MPC-HC from
`mpc-hc/`, then run jobs from `harness/` (its README documents each script).

## Versioning

Each submodule pins a SHA (the reproducibility anchor) and declares in
`.gitmodules` the branch it tracks (the intent):

- `mpc-hc` tracks `dvb-json-api` on the fork -- the PR branch carrying the
  enriched `/dvb/channels.json` these tests assert on. **When that PR merges
  upstream, repoint the submodule to `clsid2/mpc-hc` branch `develop`** (edit
  `.gitmodules` url+branch, `git submodule sync`, update, commit) and nothing
  else here changes.
- `emulator` tracks `master` of bda-vtuner.

To move to a branch's current tip: `git submodule update --remote <name>`,
re-run the tests, and commit the bump -- that commit is the record of the
tested pairing. `harness/BdaRenderMap.ps1` documents which MPC-HC JSON
spellings the pinned revision emits; revisit it on any player bump.
