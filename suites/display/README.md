# display

How the player's windows follow the DPI of the monitor they are on, measured
on the host's own monitors.

## What it needs

Two monitors at different scaling on the machine the suite runs on, and a
built player. No rig: the probe reports `NeedsRig = $false`. The suite never
changes the display scaling; with every monitor at the same DPI the case
reports Skipped, saying so.

It runs from a pane on the host against the interactive desktop. The player
is copied into `-OutDir` with a portable `mpc-hc64.ini` of its own
(`MPCTheme=1`, `ModernThemeMode`, `UpdaterAutoCheck=0`), so a settings file
beside the exe under test is never read or written, and it is started with
`/new` and stopped by its own process id only.

## Cases

`edit-menu-mixed-dpi`: open Options (`WM_COMMAND` 815), walk the page tree
until a page shows a plain Edit, and post `WM_CONTEXTMENU` to it, first with
the dialog on the main window's monitor and then with the dialog on a monitor
at a different DPI. The popup is the player's `#32768` window; its
`GetWindowRect` size is recorded and it is captured with `PrintWindow`. With
r the dialog monitor's DPI over the main monitor's, the menu's width and
height ratios between the two placements must both be within 0.15 of r. Run
in the dark (`ModernThemeMode=0`) and the light (`1`) theme, reported as
`edit-menu-mixed-dpi-dark` and `-light`.

The themed edit menu is a `CMPCThemeMenu` whose items are owner drawn and
measured by the main frame. Before clsid2/mpc-hc#4430 they were measured at
the main window's DPI wherever the menu was tracked. Main window at 144 dpi,
dialog at 96 (r = 0.67):

| build | 144 dpi | 96 dpi | ratios |
|---|---|---|---|
| unfixed | 378x413 | 378x413 | 1.00 / 1.00 |
| fixed (c0ae3a9354) | 378x413 | 262x269 | 0.69 / 0.65 |
| native classic menu | 369x375 | 264x276 | 0.72 / 0.74 |

The main window goes on the primary monitor when another monitor differs from
it, otherwise on any monitor that has a differently scaled partner, and both
windows are placed 50 pixels into the work area of their monitor. A dialog
that does not take its monitor's DPI after the move fails the case as a
harness problem rather than being measured.

## Running

    pwsh -Command "& .\suites\display\Invoke-Suite.ps1 -Exe <mpc-hc64.exe> -Case 'edit-menu-mixed-dpi'"
    .\Invoke-MpcTests.ps1 -Suite display -PlayerBinary <mpc-hc64.exe>

`-Exe` is an alias of `-PlayerBinary`; without either the checkout's
`bin\mpc-hc_x64\mpc-hc64.exe` is used. Each variant gets
`results\<case>-<theme>\` with the player's copy, `sizes.json` and the two
captures, `main-<dpi>dpi.png` and `other-<dpi>dpi.png`.

## Traps

The script makes its thread per-monitor aware (v2) before it reads anything,
so monitor DPIs and window rectangles are physical pixels; the process-wide
setting is also attempted but fails harmlessly when an earlier suite in the
same pwsh has fixed it. A posted `WM_CONTEXTMENU` is enough here: the menu's
size does not depend on the pointer, so this is not a case for the mouse
suite.
