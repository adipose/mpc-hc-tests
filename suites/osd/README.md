# osd

Shows an on-screen message in fullscreen with the docked panels up and again
without them, and asserts the message box is the same size both times.

```powershell
.\tests\Invoke-MpcTests.ps1 -Suite osd
# or on a guest you already hold:
.\tests\suites\osd\Invoke-Suite.ps1 -VMName <guest> -PlayerBinary <mpc-hc64.exe> [-MpcvrPath <MpcVideoRenderer64.ax>]
```

```
Invoke-Suite.ps1          the suite: deploy the player and the renderer, run the cases, assert
Run-OsdCase.guest.ps1     target side: play fullscreen, show a message with and without
                          the panels, capture the window, measure the box
```

## Why

In fullscreen the docked panels and toolbars sit on top of the video.
`MoveVideoWindow` keeps the renderer's window at the full screen while the
video view underneath the panels shrinks. With MPC Video Renderer the OSD is a
bitmap that the renderer stretches over its whole back buffer, and before
#4277 it was sized from the shrunken view, so the message grew whenever a
panel or toolbar was shown.

## Cases

| case | renderer | what must hold |
|---|---|---|
| `osd-size-with-panels-evr-cp` | EVR-CP | the control: its OSD is a window of its own and has never been stretched, so this proves the box can be measured on the target |
| `osd-size-with-panels-mpcvr` | MPC Video Renderer | the message box with the playlist and toolbars docked is the box without them, to within 2 pixels (#4277) |

If the control fails, a pass on the MPCVR case means nothing.

Each case also fails as "nothing was tested" if the video view was not
actually smaller than the screen with the panels up, or not the whole screen
without them. The view's client rect is recorded with every capture for that.

Results on `win10-parity-2` (1024x768, WARP), Pause message:

| build | EVR-CP, panels / none | MPCVR, panels / none | result |
|---|---|---|---|
| develop before the fix (ff9ba1de93) | 80x42 / 80x42 | 110x46 / 79x42 | control passes, MPCVR fails |
| with the fix (adipose/mpc-hc patch753) | 80x42 / 80x42 | 79x42 / 79x42 | both pass |

## How a case works

1. A fresh portable profile beside the deployed exe. It pins the modern theme
   in dark mode, so the box fill is a known colour (`#202020`) whatever the
   guest's app mode is, and makes the OSD opaque. It also keeps the fullscreen
   toolbars up for five seconds after the switch
   (`HideFullscreenControlsDelay=5000`), which stands in for a mouse parked
   over them.
2. The player is started in the console session from an interactive
   scheduled task and driven by posting `WM_COMMAND` to its main window:
   playlist on, fullscreen, play/pause. Nothing depends on the pointer.
3. The first capture is taken with the playlist and the toolbars docked. Then
   the playlist is closed, the toolbars hide on their own, and the message is
   shown again, as the same word, for the second capture.
4. The capture is `PrintWindow` with `PW_RENDERFULLCONTENT`, which includes
   what the renderer drew. The box is found by its fill colour in the top-left
   part of the window, clear of the playlist, whose background is the same
   colour.

## The renderer

MPC Video Renderer is not part of the player build. The player loads
`MPCVR\MpcVideoRenderer64.ax` from beside its own exe without registration,
so the suite deploys it there and changes nothing on the guest. The case
records the path the renderer was loaded from.

The `.ax` comes from `-MpcvrPath`, `$env:MPC_TEST_MPCVR`, an `MPCVR` folder in
the build's own directory, or a K-Lite install, in that order. With none of
them, the MPCVR case is skipped.

## Traps

* The guests render with WARP. MPCVR works there, in borderless fullscreen.
  Exclusive fullscreen is not covered, and `PrintWindow` returns a stale frame
  in that mode anyway.
* A guest's profile follows the Windows app mode, which is light on these
  guests, and a light OSD box is white. The pinned theme in the ini is what
  makes the fill colour known.
* Do not judge whether the panels were showing from pixel colours. Whether the
  playlist auto-hides depends on where the real pointer happens to be, and its
  colour depends on the theme. The view's client rect says whether the panels
  were docked.
