# mouse

Drives the player with real mouse input in the target's console session and
asserts on what the screen showed. It exists for behaviour that depends on
where the pointer is and when it got there, which nothing else in the
framework can reach.

```powershell
.\tests\Invoke-MpcTests.ps1 -Suite mouse
# or on a guest you already hold:
.\tests\suites\mouse\Invoke-Suite.ps1 -VMName <guest> -PlayerBinary <mpc-hc64.exe>
```

It needs a target with someone logged on at the console, and, for the two
control cases, a Visual Studio C++ toolset on the host to build
`combocase.exe` with. No drivers. The playlist cases play short clips, which
the suite synthesises on the host with ffmpeg (one 4 s video-only clip,
copied on the guest under the six names the cases need), and they need LAV
Filters and D3DX9_43.dll beside the player build so the clips really open.

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

The playlist cases run in one player instance, driven by
`Run-PlaylistInputCase.guest.ps1`, which types with keyboard `SendInput` as
well as clicking. The list is read from outside the player (selection via
`LVM_GETNEXTITEM`, rows via `LVM_GETITEMRECT` through memory allocated in the
player process) and an in-place editor is watched for as an `Edit` child of
the list. The keys case gets its own player instance
(`Run-KeysEditCase.guest.ps1`), plays no media, and opens Options at the Keys
page with `LastUsedPage`, the way the combo cases open the Theme page; it
reads the list the same way.

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

## Adding a case

Write a `Run-<Something>.guest.ps1` that dot-sources `MouseInput.guest.ps1`,
takes a job file, and writes `result.json` and its captures to the job's
`OutDir`; then a job function and an assertion in `Invoke-Suite.ps1` beside
the combo ones. `Start-TargetWindow` starts the program and hands back the
window to work in; `Move-PointerGlide`, `[MouseRig]::Click()` and
`[MouseRig]::ClickThenMove()` are the input; `Save-ScreenRegion` is the
evidence. Keep the asserting on the host and the guest script to recording.

The control ids come from the checkout's `resource.h` when this repository is
mounted in one, and fall back to develop's numbers otherwise.
