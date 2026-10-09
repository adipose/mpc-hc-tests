# lifecycle suite

How the player's frame comes down while a modal it owns is up.

```
Invoke-Suite.ps1              deploy the player, run one launch per case, assert
Run-LifecycleCase.guest.ps1   target side: open Options, request the exit or the
                              reset, record what happened (result.json)
```

## Cases

| case | what it does | what must hold |
|---|---|---|
| `options-exit-deferred` | Options open, `ID_FILE_EXIT` posted to the frame (web interface, exit after playback, `/close`) | the sheet is destroyed before the frame is hidden, and the player exits 0 (#4257) |
| `options-sysclose-deferred` | the same with `WM_SYSCOMMAND SC_CLOSE` (the taskbar) | as above |
| `options-reset-relaunches` | Reset in Options > Miscellaneous, confirmed Yes | the player exits 0, one new instance is running, and the ini no longer has the marker key |

## Why the order and not the crash

Before the fix the exit ran inside the Options sheet's modal pump: `OnClose`
deleted the frame and `ShowOptions` returned into freed memory. That crashes
only when the freed memory has been reused, about one run in twenty on the host
where it was found. The order of the windows coming down is the same every run.
An out-of-context WinEvent hook (`EVENT_OBJECT_HIDE`, `EVENT_OBJECT_DESTROY`)
records it as Windows queued it:

    unfixed  frame hide, sheet hide, sheet destroy, frame destroy
    fixed    sheet hide, sheet destroy, frame hide, frame destroy

The sheet is destroyed before the frame in both orders, because Windows
destroys owned windows before their owner. So "sheet gone before frame" alone
proves nothing. What separates the builds is whether the frame was hidden, which
`OnClose` does early, while the sheet was still up.

## Traps

* **The reset relaunch comes up behind its first-run prompt.** The reset wipes
  `UpdaterAutoCheck` with everything else, so the new instance sits in
  `InitInstance` on the update question. It is counted and then killed; nothing
  waits for its window.
* **Reset is the same before and after the fix.** That case is a guard that the
  relaunch, which now happens from `ExitInstance`, still works. It is not a
  regression test for the crash.
