# gpu-heap

What a graphics user-mode driver does to the heap it shares with the player.

A user-mode display driver is loaded into the application's process, and the
legacy AMD D3D9 driver allocates the great majority of its blocks from
`GetProcessHeap()`. So its objects and the player's land in the same size
classes, and a stray write on either side of that boundary is a write into the
other's object. This suite measures the boundary rather than reasoning about
it.

It drives [amd-driver-emulator](../../amd-driver), which plays the Direct3D
runtime's side of the driver interface: it hands the driver its callback
table, answers the adapter queries with an invented record, and hooks the
driver's own heap imports so every allocation is attributed, counted by size,
and optionally padded with guard zones. The same probe builds as a DLL that is
injected into a running player, where the heap under the driver is the
player's heap with the player's own themed-menu vectors in it.

The subject is clsid2/mpc-hc#4257: a crash in `~CMPCThemeMenu` at exit in
which the 152-byte heap buffer of a `std::vector<MenuObject*>` has had bytes
`0x64..0x6B` zeroed, on twelve machines that all run a 2015 AMD legacy driver
and no machine available for testing has such a card. The `lifecycle` suite
covers a different part of that report, the modal-up exit path.

## What this adds to the instrumentation that already exists

The investigation's quarantine build detours `ntdll!RtlFreeHeap`, so every
free in the process is caught whatever the caller and whatever the heap, and a
block of 137..152 bytes is poisoned instead of freed. That covers use after
free on a block of the victim's size, including one a driver frees itself.
Page heap faults on a write past the end of an allocation. Neither sees a
write into a block that is still live, and that is where this report's damage
sits.

This suite comes at that from the driver's side: guard zones on the driver's
own allocations catch it writing outside them, and the measured distance from
its blocks to blocks of the victim's shape says whether it is positioned to
hit one. It is also the only way to put the 2015 driver's own code in the
player's process on a machine without its hardware, which matters because the
quarantine's clean runs were made against the modern driver on the host, not
that one.

## What it needs

A built probe, or Visual Studio 2022 with the C++ toolset to build it (the
suite builds it when `build\legacy9.exe` is missing). No rig: the probe
reports `NeedsRig = $false`. The two cases that need no driver run anywhere.

The two driver cases additionally need the legacy driver's user-mode DLLs,
which are not redistributed: put `atiumd64.dll` and `atiumd6a.dll` in the
probe's `drivers\` directory or set `MPC_TEST_AMDUMD` (see that directory's
README), and a built player to host them in. Without either, those cases
report Skipped, saying which is missing.

Where the probe is, in order: `$env:MPC_TEST_AMDPROBE`, `AmdProbeRoot` in
`testbed.config.psd1`, the `amd-driver` submodule of this repository, then
`C:\dev\amd-driver-emulator`.

The driver cases start a player on the interactive desktop and close it again.
Nothing is installed, and no kernel call is forwarded to the real kernel
driver.

## Cases

`damage-detector`: plant 256 blocks shaped like the victim (a capacity-19
pointer vector), zero bytes `0x64..0x6B` of one of them, and require a walk of
every heap in the process to find it. A detector that has never fired makes
every quiet result in this suite meaningless, so this case gates the others:
the probe stops before loading any driver if it fails.

`heap-stride`: measure the distance the 152-byte class puts between
consecutive blocks, from the addresses of blocks the probe allocated itself,
and compare it with `-ExpectedStride` (default 160). Measured 160 (`0xA0`) on
Windows 10 22H2 (19045), in 240 of 255 gaps between 256 blocks, and repeated
in three unrelated host processes. The arithmetic figure for a 16-byte header
would be `0xB0`; the x64 LFH entry header is 8 bytes, so 152 + 8 is already
16-aligned. This is a property of the running Windows build, and neighbour
analysis of a damaged block depends on it, so a mismatch fails rather than
being accepted.

The field dumps do not contradict it on three builds that cannot be run here,
but they constrain it rather than measure it. The gap between two capacity-19
buffers in one 64 KB region, which the stride must divide, was:

| OS build | gap | over `0xA0` | over `0xB0` |
|---|---|---|---|
| 10.0.17763 | `0x140` | 2 | not a multiple |
| 10.0.22621 | `0x14A0` | 33 | 30 |
| 10.0.26300 | `0x1400` | 32 | not a multiple |

So `0xB0` is excluded on two of the three, and the `0x140` is the tightest,
being two strides. These are gap constraints from a buffer's own
`first`/`last`/`end` bounds, not three independent readings of a stride; the
live measurement is what the case asserts on.

`legacy-umd-shared-heap`: inject the probe into a running player and open and
close the legacy driver's adapter twelve times. The driver must open, must
still take blocks in the 152-byte class from the player's heap (if it stopped
doing that, the premise every heap-neighbour argument rests on would have
stopped being true, so that is a failure and not a pass), and nothing in the
process may end up carrying the damage pattern. Eight rounds in
`mpc-freehunt-daily`, 2026-11-15: 946 process-heap allocations, 8 in the
152-byte class, 6 of them within four strides of a vector-shaped block, no
damage.

`legacy-umd-guard-zones`: the same, with every driver allocation padded by
`0x140` bytes on each side, checked at every checkpoint and at every free. No
write outside the driver's own allocations in 982 checks. Zero hits out of
zero checks is not a result, so a run that checked nothing fails.

Guard zones move the driver's 152-byte requests out of the class being
studied, so the two driver cases are deliberately separate runs: one asks
whether its blocks land next to a menu vector, the other whether it writes
outside its own.

## Running

    .\Invoke-MpcTests.ps1 -Suite gpu-heap -PlayerBinary <mpc-hc64.exe>
    & .\suites\gpu-heap\Invoke-Suite.ps1 -Case damage-detector,heap-stride
    & .\suites\gpu-heap\Invoke-Suite.ps1 -PlayerBinary <mpc-hc64.exe> -Rounds 8

`-Exe` is an alias of `-PlayerBinary`. Each case writes its probe log and its
JSON result to `-OutDir`, and the injected cases also write the injector's own
output there.

## Traps

- **The hardware is invented.** The driver validates a 608-byte adapter record
  before it will open, and the suite supplies a size field, family 8 and a
  TeraScale-range chip id and revision. The driver therefore takes the paths
  that record selects, which are not necessarily the ones a real card of that
  family would select. A crash under this suite may be the suite; a clean run
  proves less than it looks.
- **The covered window is the adapter phase only**: `OpenAdapter`, `GetCaps`,
  `CloseAdapter`. In every damaged field dump the driver had already been
  unloaded by the time the dump was written, which puts the interesting window
  at `CreateDevice` through graph teardown. That is not covered yet, and the
  passing driver cases say nothing about it.
- The probe's 152-byte driver object (`atiumd6a.dll+0x19442`, a vtable at `+0`
  and 3 at `+0x48`) being a bucket neighbour of the menu vectors is evidence
  for the heap-layout reading of #4257, not for the driver writing the bytes
  itself.
- A DLL cannot be loaded from an agent shell on this machine, which is why the
  probe ships `inject.exe` as a native tool.
