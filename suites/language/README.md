# language suite

Switching the interface language while the player runs.

```
Invoke-Suite.ps1             deploy the player and the Hebrew dll, run one launch per case, assert
Run-LanguageCase.guest.ps1   target side: start in Hebrew, switch to English in Options, open
                             About before and after, record its layout (result.json)
```

## Cases

| case | what it does | what must hold |
|---|---|---|
| `rtl-to-ltr-new-window` | starts in Hebrew, sets the language combo in Options > Player to English and closes with OK, opens About | the About box opened after the switch is not `WS_EX_LAYOUTRTL` |

The About box opened before the switch must be mirrored, and the ini must say
`InterfaceLanguage=0` afterwards. Either missing fails the case as "nothing
was tested": the first means the Hebrew dll did not load, the second that the
switch never applied.

## Why

Choosing Arabic or Hebrew calls `SetProcessDefaultLayout(LAYOUT_RTL)` and
installs a CBT hook that mirrors every new top-level window. Before the fix
nothing undid either, so after switching back every new window still came up
mirrored until a restart. Windows that already exist keep the layout they were
created with, on any build, so the main window is only recorded.

The other half of that fix, that switching into Hebrew twice installs one hook
and not two, is not tested here: a second hook mirrors the same windows the
first one does, so nothing a window shows tells them apart.

## Traps

* **The Hebrew dll must be at the exe's version.** The player loads a language
  dll only when its major.minor.patch matches the exe's and silently runs in
  English otherwise. A project-only build leaves the dlls of whatever last
  built translations, so the suite compares the two versions before deploying
  and stops with a message rather than reporting the fallback.
* **Window titles are translated.** The About box and the Options sheet are
  found by class (`#32770`) and process, not by title.

## Results

On `win10-parity-3`, 2026-10-20:

| build | `rtl-to-ltr-new-window` |
|---|---|
| upstream `b8bd6a8751` | FAIL, the About box after the switch is mirrored |
| mpc-hc `patch775` (`67889ae527`) | PASS |
