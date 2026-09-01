# Chromecast suite

Tests MPC-HC's Cast sender against the superproject's `cast-mock` submodule
(castv2-mock-device): a mock Google Cast receiver providing mDNS discovery,
TLS on 8009, CastV2 protobuf framing, and adversarial failure switches — so
casting behaviour is asserted without Cast hardware, the way the `dvb` suite
asserts tuner behaviour without broadcast hardware.

Status: scaffold. The mock device is pinned and ready; the player side (Cast
sender support in MPC-HC) is in development on its own branch and is not yet
in the pinned `mpc-hc` revision. Test scripts land here once both halves
exist to connect.

What a test here asserts, when it does:

- **Discovery** — the player finds the mock via mDNS and lists it as a target.
- **Session bring-up** — CONNECT/launch against the mock's receiver, with the
  handshake visible in the mock's log rather than inferred from the player.
- **Media control round trips** — load/play/pause/seek/stop echoed by the
  mock, asserted from its state, not the player's belief about it.
- **Failure paths** — the mock's adversarial switches (refused connections,
  dropped sessions, malformed frames) driving the player's error handling,
  the same declared-expectation style as the dvb suite's fault injection.

Run the mock from the submodule (`python ..\..\cast-mock\mock_cast.py`; see
its README for the switches).
