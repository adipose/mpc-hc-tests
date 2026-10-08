# capture

Analog capture (File > Open Device) driven through the capture bar, asserted
from the file it records and from whether the player keeps answering.

## What it needs

A DirectShow video capture device and an audio capture device on the machine
the suite runs on, and a built player. No rig: the probe reports
`NeedsRig = $false`.

Today that machine is the host, where e2eSoft VCam is installed. The test
guests have no camera. A virtual capture driver alongside `vaudio` and
`vdisplay` (the WDK's AVStream capture sample is the obvious start, with a
test pattern and a frame counter) would move the suite onto the guests with
no change here: it takes whatever `CLSID_VideoInputDeviceCategory` lists
first. `CaptureAudioDevice` in `testbed.config.psd1` picks the audio source
by a friendly-name substring; otherwise the first audio capture device is
used.

## Cases

`record-with-previews`: Record Video and Record Audio with both previews on,
uncompressed AVI, 6 s. The AVI must have exactly one video and one audio
stream and its video must run most of the 6 s. Before the fix for
clsid2/mpc-hc#4285 the audio preview pin was rendered after the AVI mux was
in the graph, `CFGManager::Connect` attached it to the mux's spare input, and
the mux waited on that phantom stream forever: a 0.48 s file with two audio
streams. The stream headers are read straight from the RIFF `strh` chunks, so
nothing but PowerShell is needed.

`resolution-changes`: select the next video dimension four times while
previewing. Each one tears the graph down and rebuilds it
(`CMainFrame::BuildGraphVideoAudio`); every change must return, the window
must keep answering, and WM_CLOSE must still end the process. The rebuild
path from clsid2/mpc-hc#4280. Skipped when the device offers one dimension.

## Running

    pwsh -File suites\capture\Invoke-Suite.ps1 -PlayerBinary <exe> -Case record-with-previews

Each case gets `results\<case>\player\` with its own copy of the exe and a
portable `mpc-hc64.ini`, so the machine's own player settings are untouched,
and `filtergraph.log` there lists every filter connection the player made.

## Traps

The ini has to sit beside the exe, which is why the exe is copied. The
`/device` switch opens the configured device at startup; without
`UpdaterAutoCheck=0` the first-run prompt would block it. The Record button
is driven by `WM_COMMAND` `BN_CLICKED` to the dialog, not a posted click, so
it does not depend on the pointer; the mouse suite is the place for anything
that does.
