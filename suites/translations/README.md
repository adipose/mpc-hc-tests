# translations suite

The checkout's translation files through the MPC-HC Translation Studio's
validation ruleset. The Studio (`mpc-hc-translations`, a sibling repository)
owns the rules; `potool\potool.py` there is their single source, the one its
CI gate runs against `clsid2/mpc-hc`. This suite loads that script instead of
restating the rules.

```
Invoke-Suite.ps1      probe: python, and a Studio checkout with potool
                      run: every src\mpc-hc\mpcresources\PO\*.po through potool
```

Where the Studio is: `$env:MPC_TEST_STUDIO`, else `StudioRoot` in
`testbed.config.psd1`, else `C:\dev\mpc-hc-translations` when that exists.
No player, no rig.

## What passes and fails

One result per `.po` file: clean (no error) passes, an error fails. Warnings
(mnemonic and newline parity, whitespace, length ratio, empty msgstr) are
advisory in the ruleset and are summarised per rule in the notes, not counted.

On a branch, a file the branch changed is also run in potool's PR mode against
the version at the merge-base with `upstream/develop` (or `origin/develop`),
which adds the structural rules: same `(msgctxt, msgid)` key set, headers
unchanged, only `msgstr` moved.

Results: `potool-report.json` in the run's output directory, one row per file
with its error lines.

## Known state

On upstream develop `b803b50150` the ruleset flags four files
(`de`, `es`, `tr` at `IDS_STATSBAR_SIGNAL_FORMAT`, `ro` at
`IDS_THUMBNAILS_INFO_HEADER`) that are not wrong: potool's environment
variable mask (`%name%`) takes `%ld%` out of `%ld%%` and `%dx%` out of
`%dx%d`, so the msgid loses specifiers the msgstr keeps. Reported to the
Studio 2026-09-18; the suite shows them as failures until the ruleset is
fixed, because it runs the ruleset as it is.

## Not here yet: the fit scan

The check the clipped-text reports call for (#2697, #2816, #4076, #4107,
#4141, #4159) is whether a translated caption is wider than its control. The
Studio does exactly that, rendering the real dialogs off-screen from its
neutral resource DLL (`LivePreview::MeasureFit`, driven by `EnsureFitScan`),
but only from inside its window. When the Studio publishes a headless entry
point (`potool\fitscan.*`, taking a PO directory and writing JSON with one
record per string that does not fit), `Invoke-FitScan` in the suite is where
it plugs in; until then the suite reports that check as skipped. Do not probe
`Studio.exe` by running it with a switch: it ignores what it does not know
and opens its window, and an orchestrator then waits on it.
