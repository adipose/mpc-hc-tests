# capture

Analog capture (File > Open Device) driven through the capture bar, asserted
from the file it records and from whether the player keeps answering.

## What it needs

A DirectShow video capture device and an audio capture device on the machine
the suite runs on, and a built player. No rig: the probe reports
`NeedsRig = $false`.

On the host that is whatever camera is installed (e2eSoft VCam here). On a
test guest it is the avs-vcamera virtual camera in `vcamera`, which
`..\playback\Install-OutputDevices.ps1` provisions alongside `vaudio` and
`vdisplay`: a test pattern with its frame number drawn in, three sizes in two
formats, and an audio pin of its own. The suite takes whatever
`CLSID_VideoInputDeviceCategory` lists first. `CaptureAudioDevice` in
`testbed.config.psd1` picks the audio source by a friendly-name substring;
otherwise the first audio capture device is used (on a guest, vaudio's
microphone).

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

`record-camera-audio`: `record-with-previews` with no audio device
configured, so `CMainFrame::OpenCapture` takes audio from the video device's
own audio pin (`m_pAudCap = m_pVidCap`), the path a capture card such as the
#4280 reporter's HVR-2250 takes. The audio stream must also run most of the
6 s. Skipped when the video device has no audio output pin, as VCam has not.
The pre-fix build fails it the same way: 0.03 s of video, two audio streams.

`preview-with-mpcvr`: preview only, with MPC Video Renderer as the output
renderer. Capture cannot use MPCVR and must substitute EVR-CP; the
`filtergraph.log` must not show "Trying MPC Video Renderer", a renderer must
connect, and the player must keep answering and close. Unfixed 2.8.2 set the
capture flag after the renderers were chosen and connects MPCVR to the Smart
Tee (clsid2/mpc-hc#4280, be66b4b8b1). It records nothing, so it does not
depend on the #4285 mux fix (#4300, a761b87396). Skipped
without `MPCVR\` beside the player (a release zip has it, a source build does
not).

## Running

    pwsh -File suites\capture\Invoke-Suite.ps1 -PlayerBinary <exe> -Case record-with-previews
    pwsh -File suites\capture\Invoke-Suite.ps1 -PlayerBinary <exe> -VMName <guest>

With `-VMName` the player (with `mpciconlib.dll` and `D3DX9_43.dll`, from
beside the exe or the checkout's `distrib\x64`) and this script go to
`C:\mpc-test\capture` on the guest, and the script runs there in its host
mode as the console user, from an interactive scheduled task: the capture bar
is driven with window messages, which only reach windows on the caller's
desktop. The guest runs Windows PowerShell 5.1, so the script stays within
it. The cases' folders come back to `-OutDir`.

The camera draws its frame number into every frame as 32 black and white
blocks along the top. `vcamera\tests\avicheck.py` reads them back from an
uncompressed recording, with the audio's frequency per channel (the camera's
own audio is 1000 Hz left, 1500 Hz right), so a case can assert that the
picture kept advancing rather than only that the file is long enough.

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
