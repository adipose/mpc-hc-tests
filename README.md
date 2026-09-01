# mpc-hc-tests (retired)

This repository is retired. The test framework now lives inside the MPC-HC
tree itself: `tests/` on the `test-framework` branch of
https://github.com/adipose/mpc-hc, where tests and player change together
and the branch merges upstream `develop` cleanly.

What moved where:

- `suites/dvb`, `suites/chromecast` → `tests/suites/` on that branch, with a
  generic orchestrator (`tests/Invoke-MpcTests.ps1`) and a headless-scan
  feedback loop (`/dvbscan`, upstream since clsid2/mpc-hc#4138) in place of
  the web-API dependency.
- The `emulator` (bda-vtuner) and `cast-mock` (castv2-mock-device)
  submodules → `tests/emulator` and `tests/cast-mock` there.
- The `mpc-hc` submodule is gone: the enclosing repository is the player
  under test.

The history here records emulator-player pairings tested before the move.
