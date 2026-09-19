<#
.SYNOPSIS
    Applies the player-side test hooks to the MPC-HC checkout this repository
    is mounted in, or reports which of them it already has.

.DESCRIPTION
    The suites drive the player through a few small additions to it -- verbs
    such as /dvbscansave -- that live upstream once merged and, until then,
    here as patches under hooks\. Each patch is one commit, exported with
    `git format-patch` from the fork's test-hooks branch (upstream develop
    plus the hooks, rebased as develop moves).

    -Check says, per hook, whether the checkout's source already contains it,
    by looking for the marker each hook is known by. The suites make the
    same check against the built binary before they run, so a branch without
    a hook is reported as not ready rather than failing.

    Without -Check, the patches whose hooks are missing are applied with
    `git am`, as commits, onto the current branch. A patch that does not
    apply stops the run with git's own report; nothing is half-applied
    (`git am --abort` is run for you).

.PARAMETER RepoRoot
    The MPC-HC checkout. Default: the parent of this repository's directory,
    which is where it sits when mounted as tests\.

.PARAMETER Check
    Report only.

.EXAMPLE
    .\tests\hooks\Apply-TestHooks.ps1 -Check
    .\tests\hooks\Apply-TestHooks.ps1
#>
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [switch] $Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# What each patch adds, and a string that is in the tree only once it has. The marker is looked for in source
# here and, by the suites, in the binary; keep the two in step when a hook changes.
$hooks = @(
    @{ Patch = '0001-add-dvbscansave-to-store-the-headless-scan-result-as.patch'
       Name = '/dvbscansave'; File = 'src\mpc-hc\AppSettings.cpp'; Marker = 'dvbscansave'
       Upstream = 'clsid2/mpc-hc#4143' }
    @{ Patch = '0002-make-a-headless-scan-that-cannot-run-close-the-playe.patch'
       Name = 'headless scan exit code'; File = 'src\mpc-hc\mplayerc.h'; Marker = 'm_nExitCode'
       Upstream = 'clsid2/mpc-hc#4143' }
)

if (-not (Test-Path (Join-Path $RepoRoot 'src\mpc-hc\mplayerc.cpp'))) {
    throw "$RepoRoot is not an MPC-HC checkout (no src\mpc-hc\mplayerc.cpp)."
}

$missing = @()
foreach ($h in $hooks) {
    $path = Join-Path $RepoRoot $h.File
    $present = (Test-Path $path) -and ((Get-Content $path -Raw) -match [regex]::Escape($h.Marker))
    $state = if ($present) { 'present' } else { 'missing' }
    Write-Host ("  {0,-26} {1,-8} {2}" -f $h.Name, $state, $(if ($present) { '' } else { "($($h.Upstream))" }))
    if (-not $present) { $missing += $h }
}

if ($Check -or -not $missing) {
    if (-not $missing) { Write-Host 'All hooks present.' -ForegroundColor Green }
    return
}

$dirty = git -C $RepoRoot status --porcelain -- src
if ($dirty) { throw 'src\ has uncommitted changes; commit or stash them before applying hooks with git am.' }

foreach ($h in $missing) {
    $patch = Join-Path $PSScriptRoot $h.Patch
    Write-Host "Applying $($h.Name) ..." -ForegroundColor Cyan
    & git -C $RepoRoot am --3way $patch
    if ($LASTEXITCODE -ne 0) {
        & git -C $RepoRoot am --abort 2>$null
        throw "$($h.Patch) did not apply to this branch. Merge the fork's test-hooks branch instead, or rebase the hook."
    }
}
Write-Host 'Hooks applied as commits on the current branch; build the player to use them.' -ForegroundColor Green
