# mouse

Drives the player with real mouse input in the target's console session and
asserts on what the screen showed. It exists for behaviour that depends on
where the pointer is and when it got there, which nothing else in the
framework can reach.

```powershell
.\tests\Invoke-MpcTests.ps1 -Suite mouse
# or on a guest you already hold:
.\tests\suites\mouse\Invoke-Suite.ps1 -VMName <guest> -PlayerBinary <mpc-hc64.exe>
# some cases only (wildcards against the names below; the rest count as skipped):
pwsh -Command "& .\Invoke-Suite.ps1 -VMName <guest> -Case 'filedialog-*','keys-*'"
```

It needs a target with someone logged on at the console, and, for the two
control cases, a Visual Studio C++ toolset on the host to build
`combocase.exe` with. No drivers. The playlist cases play short clips, which
the suite synthesises on the host with ffmpeg (one 4 s video-only clip,
copied on the guest under the six names the cases need), and they need LAV
Filters and D3DX9_43.dll beside the player build so the clips really open.
The player window cases use two more synthesised clips, 15 s and 60 s, the
same way.

## Why real input

A posted `WM_MOUSEMOVE` goes to the window it is addressed to, whatever holds
the mouse capture, and it sits in the queue wherever the sender put it. So
with posted messages the three things a hover bug depends on are the test's
own invention: which window gets the move, when the window being left is told,
and whether a paint is delivered before or after the move.

Issue #4276 was investigated with posted messages first, and they gave two
confident wrong answers. One: a click posted straight to an open combo
bypassed the list's capture, and the hovered item stayed selected after
closing, which real input never does. Two: a hover posted ahead of the paint
that opening the list queues made a plain Windows combo show the hovered item,
which was then reported as "standard Windows behavior". With real input a
plain combo never does that.

`MouseInput.guest.ps1` injects with `SendInput` from an interactive scheduled
task, which is the one way all three are what Windows really does. It cannot
be run from a session's own shell on the host: input from there does not reach
a window, and `GetCursorPos` fails inside the process under test.

## Cases

| case | what it drives | what must hold |
|---|---|---|
| `control-plain-windows-combo` | a plain comctl32 combo in `combocase.exe` | with the list just opened and the pointer on an item, the face still shows the selected item |
| `control-harness-detects-echo` | the same combo, invalidated on mouse-leave | the face does change: the harness can see the defect |
| `combo-hover-keeps-selected-item-<theme>` | the OSD font and "Time on seekbar" combos on the Theme options page | as the first control; and closing without a pick leaves the selection alone |
| `combo-click-selects-item-<theme>` | the same two combos | clicking a list item selects that item |
| `playlist-type-to-find` | typing a name's first letter with the selection just before two entries that match it | the selection lands on the entry the search starts from, not past it (#3844) |
| `playlist-click-time-column-no-edit` | a click on an entry's time column | the editor that may open holds the entry's name, never the time cell's text (#3885 item 1) |
| `keys-double-click-edits` | a real double-click on a key entry's hotkey cell in Options > Player > Keys | the in-place hotkey editor opens within 1 s (#3853) |
| `keys-esc-cancels-text-edit` | same run: a click into the RemoteCmd and then the RepCnt cell of a selected key entry, real keys typed, then Esc | each cell keeps its old value (RepCnt stays 5) and Apply stays disabled |
| `options-d3d9-device-hidden-on-one-adapter` | Options > Output, renderer switched to EVR Custom, the D3D9 device controls found on the page (old layout) or in the renderer settings popup | with one adapter the checkbox and combo are hidden, and stay hidden over an enable/disable cycle (#4033) |
| `filedialog-injected-themed-foreground` | File > Open Directory with Windows in dark mode, the player active | the "Include subdirectories" box the player injects into the folder picker paints dark: light text straight on the dialog's background |
| `filedialog-injected-themed-background` | the same, with notepad holding the foreground | as above (#4281 part 1; see the Windows 11 note below) |
| `filedialog-injected-themed-minimized` | the same, with the player minimized | as above (#4281 part 1) |
| `filedialog-injected-themed-win11style` | the same, modern theme in its Windows 11 style | the label is not on a rectangle of its own: the dialog is Windows's and its background does not follow the player's palette (#4281 part 2) |
| `status-audio-tooltip-<n>ch` | a 1, 2 and 6 channel clip playing in the modern theme with Audio Info off; the pointer moved onto the status bar's audio channel icon | a tooltip comes up over the icon carrying the channels as Audio Info writes them: mono, 2.0, 5.1 (#4257; develop has no tooltip there) |
| `filedialog-injected-themed-themeoff` | the same, modern theme off | still painted dark: the dark dialog workaround runs without the theme (#4281, found while fixing) |
| `playlist-edit-survives-autohide` | windowed auto-hide; the playlist's inline edit opened by a slow second click, then the pointer moved onto the video past the 2 s delay | the edit is still open and the playlist still shown; once Escape cancels the edit, the playlist hides (#4279 item 3) |
| `playlist-edit-drag-survives-autohide` | the same, but a text selection started in the edit and dragged onto the video with the button held, held past the delay and released there | the edit survives the hold and the release (#4279 item 4) |
| `playlist-edit-drag-survives-autohide-fullscreen` | the same in fullscreen, where docked panels auto-hide by the fullscreen rules | as above (#4279 item 4) |
| `playlist-edit-wheel-keeps-edit-and-volume` | three wheel notches over the open edit, three over the list below it, then two over the video | the edit stays open and the volume does not move until the notches over the video, which must lower it (#4279 item 5) |
| `window-resize-below-minimum-no-drift` | `LimitWindowProportions` on; the top-left corner dragged inwards 560 px, far past the minimum size | the right and bottom edges do not move at any of the 140 sizing steps (#4279 item 6) |
| `playlist-playing-item-drawn-while-renaming` | row 0 (a 15 s clip) renamed until it ends and row 1 starts playing | row 1 is drawn with its name while the edit is still open (#4279 item 9) |
| `playlist-web-index-repaints` | the web interface's `setplaylistindex` moves playback from row 0 to row 1 | both rows look as a forced redraw of the list draws them (#4279 item 1) |
| `panel-zone-holds-while-editing` | the playlist and the Edit List editor docked side by side, the playlist's edit open, the pointer on the video past the delay | neither panel hides or moves, and the edit stays open; both hide once it is cancelled (#4279 item 10) |
| `fullscreen-toggle-no-basic-frame-<theme>` | five fullscreen round trips by real double-clicks on the video, the screen recorded at 60 fps with ffmpeg's gdigrab (dark theme, theme off) | no recorded frame in the 0.8 s after any toggle shows the Vista/7 basic frame's light blue border where the window stood, and every round really covered the screen and came back (#4330) |

The fullscreen frame cases need ffmpeg on the host's PATH: it is copied to the
guest to record, and reads the recording back on the host. The unfixed build
never shows the basic frame on the first entry after launch, so the case makes
five round trips. madVR makes the flash last far longer (about 0.3 s), but it
is not on the guests and the case does not need it: without it the unfixed build
still showed the frame on most entries on both Windows 10 and 11.

The Options/theme case runs in `Run-OptionsThemeCase.guest.ps1`, one case per
job. The theme comes from the ini (`MPCTheme`, `ModernThemeMode` 0 = Dark / 1 =
Light).

The file dialog cases run in `Run-FileDialogThemeCase.guest.ps1`, one job and
one player launch per variant. The guest script turns Windows dark mode on for
the console user (`AppsUseLightTheme=0`, which the player reads at startup)
and puts the old value back when it is done. The capture is the injected check
box with a margin of dialog around it, and the margin is the reference the
label background is compared with. Before bb78c2c0fe the player found the
dialog by watching its own main frame for `WM_ACTIVATE`, which only arrives
when the frame was active; with the player inactive that message still came on
Windows 10 but not on Windows 11. So the background and minimized cases prove
the fix on a Windows 11 target only; on Windows 10 they pass the unfixed build
as well, and the suite says so when the target is older than build 22000.

The playlist cases run in one player instance, driven by
`Run-PlaylistInputCase.guest.ps1`, which types with keyboard `SendInput` as
well as clicking. The list is read from outside the player (selection via
`LVM_GETNEXTITEM`, rows via `LVM_GETITEMRECT` through memory allocated in the
player process) and an in-place editor is watched for as an `Edit` child of
the list. The keys case gets its own player instance
(`Run-KeysEditCase.guest.ps1`), plays no media, and opens Options at the Keys
page with `LastUsedPage`, the way the combo cases open the Theme page; it
reads the list the same way.

The player window cases (#4279) run in `Run-PlayerWindowCase.guest.ps1`, one
launch per case, in the modern dark theme, the window at 980x620 in the top
left of the guest's screen. The guest script records a series of states
(whether the inline edit is open, where the playlist and the named panels are,
the volume slider's position, focus, capture, and which window was under the
pointer) and the host judges them. The edit is the one the list itself opened,
read with `LVM_GETEDITCONTROL`; the volume is `TBM_GETPOS` on the player's only
trackbar. Two of them judge the screen: the renaming case counts text pixels in
row 1's name (anything over 48 off the row's commonest colour), and the web
case compares both rows with a capture taken after a forced redraw of the list.
Every case carries a control that fails when it tested nothing: the panel never
hid at all, the wheel over the video did not change the volume, the pointer
never got past the minimum size, the playing mark did not visibly move.

The zone case tells the zone fix (e0a9c7b3f7) apart on its own, not only
develop: against patch755 with only that commit reverted, the Edit List editor
hid, the playlist moved 198 px right and the edit ended.

Both themes run, because the defect behind #4276 was in neither theme's
painting but in an `Invalidate()` the two share.

If `control-harness-detects-echo` fails, a pass on the player cases means
nothing: the harness could not see the defect on that target at all.

## How the face is judged

The combo cannot be asked what its face shows. `WM_GETTEXT` and
`CB_GETCURSEL` both answer with the open list's selection, and that follows
the pointer, so they report the hovered item whether or not it was drawn.

So the face is read off the screen. Each round ends with a capture
(`CopyFromScreen`, which sees popups the way a person does), and the face is
the part of the combo inside its border and left of the drop-down button. A
hover that lands 0, 30, 60 or 100 ms after the opening click is compared with
one that lands at 800 ms, by which time any build shows the selected item. More
than 8 pixels differing by more than 48 in a channel is a different face; a
wrong item is over a hundred.

A round counts only if the hover really happened: the list is open and its
selection moved off the selected item. Otherwise the case fails as "nothing was
tested" rather than passing on a pointer that missed.

## Traps

* **A list ignores a move to the point it last saw.** Hovering the same pixel
  in two rounds moves the selection in the first and does nothing in the
  second. Every round hovers a different row and column.
* **Which row is which.** A long list opens scrolled so the selected item is
  its first row; a short one opens from item 0. With the pointer above an open
  list, the list selects its first visible row.
* **`WindowFromPoint` does not say where input goes.** Over a combo inside a
  group box it returns the group box. Judge aim by what happened.
* **The control program must embed its manifest.** A copy of the exe without
  it gets the old user32 combo instead of comctl32 v6, and measures a different
  control. `Build-ComboCase.ps1` embeds it.
* **`SendInput` checks the size of `INPUT`.** 40 bytes on x64; anything else
  and the call injects nothing and says so only through its return value.
* **The pointer is not in the captures.** `CopyFromScreen` leaves it out; each
  record carries its position instead.
* **A posted wheel never takes the route a real one does.** The player
  re-dispatches real wheel input from a `WH_MOUSE` hook (`CMouseWheelHook` in
  `MouseTouch.h`): first to the window under the pointer and, when that returns
  0, to the main frame, which turns it into volume. A hook only sees input from
  the input queue, so a `WM_MOUSEWHEEL` posted or sent to the inline edit or
  the list skips it. On #4279 a half-fixed build passed every posted and sent
  wheel while a real notch on the same edit still changed the volume. Inject
  with `[MouseRig]::Wheel()`.
* **Where a real wheel lands depends on `MouseWheelRouting`.** Windows 10's
  default (2, "scroll inactive windows when I hover over them") delivers it to
  the window under the pointer, not the focus window, so a wheel case aims the
  pointer at the window it means and checks the record's `under`. The player
  window cases record the value as `mouseWheelRouting`.
* **Auto-hide must be seen to hide.** A case about something surviving
  auto-hide passes trivially if the panel never auto-hid at all, so each one
  also requires the panel to hide once the edit is closed.
* **An auto-hidden panel is shown by the pointer, not a command.** Posting
  `ID_VIEW_PLAYLIST` toggles the bar, so over a panel that auto-hide has hidden
  it turns the playlist off. The guest script moves the pointer into the right
  edge's zone first and only posts the command when that did not show it.
* **The Edit List editor asks first.** Without `EnableEDLEditor=1` its command
  raises "Do you want to activate the EDL editor?" and the case sits behind a
  modal.
* **A drag needs the button's halves apart.** `ButtonDown()` and `ButtonUp()`
  with moves in between; `Click()` cannot hold the button across a move.

## Adding a case

Write a `Run-<Something>.guest.ps1` that dot-sources `MouseInput.guest.ps1`,
takes a job file, and writes `result.json` and its captures to the job's
`OutDir`; then a job function and an assertion in `Invoke-Suite.ps1` beside
the combo ones. `Start-TargetWindow` starts the program and hands back the
window to work in; `Move-PointerGlide`, `[MouseRig]::Click()`,
`[MouseRig]::ClickThenMove()`, `ButtonDown()`/`ButtonUp()`, `Wheel()` and
`KeyPress()` are the input; `[MouseRig]::ListItemRect()` aims at a list view
row of another process (`LVM_GETITEMRECT` through memory allocated in it, in
screen coordinates); `Save-ScreenRegion` and `Save-WindowShot` (a window's part
of the screen, or the whole screen when the window is mostly off it) are the
evidence. Keep the asserting on the host and the guest script to recording.

The control ids come from the checkout's `resource.h` when this repository is
mounted in one, and fall back to develop's numbers otherwise.
