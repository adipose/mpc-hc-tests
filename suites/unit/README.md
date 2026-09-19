# unit suite

The native unit tier as an orchestrator suite. A thin wrapper over
`tests\unit\Invoke-UnitTests.ps1`: it builds `tests\unit\MpcUnitTests.vcxproj`
(which references the player's `DSUtil`, `Subtitles` and `SubPic` static
libraries so msbuild builds them as dependencies, and compiles GoogleTest in
from the `unit\googletest` submodule), runs the resulting console exe, and
reports its counts from the JSON GoogleTest writes.

This suite runs no player and needs no rig, so its probe returns
`NeedsRig = $false`; the orchestrator then claims no test guest when the unit
suite is the only runnable one.

```powershell
.\tests\Invoke-MpcTests.ps1 -Suite unit     # through the orchestrator
.\tests\unit\Invoke-UnitTests.ps1           # directly (build + run)
.\tests\unit\Invoke-UnitTests.ps1 -NoBuild WebVTT,TextFile   # a subset
.\tests\unit\Invoke-UnitTests.ps1 -NoBuild -ExeArgs '--gtest_filter=WebVTT.Style*'
.\tests\unit\Invoke-UnitTests.ps1 -NoBuild -List
```

The tests are ordinary GoogleTest (`TEST`, `EXPECT_*`, `ASSERT_*`), plus two
macros from `tests\unit\MpcGtest.h`:

`TEST_EXPECTED_FAILURE(Suite, Name, "reason")` documents a bug still present
in the code under test. The body runs with its failures captured; at least one
is what the marker expects, and the test passes carrying the reason as a test
property, counted here as *skipped*, not failed. When the bug is fixed the
body stops failing, the test fails with "remove the marker", the exe returns
non-zero and the suite fails until the marker is removed with the fix.

`TEST_ISOLATED(Suite, Name)` runs the body in a child process (a GoogleTest
death test) with a timeout, for input that may crash, hang or corrupt the
heap. A crash there is a failure of that one test, reported with the exit
status and, when the PDB is there, the frames it happened in. The two compose
as `TEST_ISOLATED_EXPECTED_FAILURE` for a crash that is a known bug.
