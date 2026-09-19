<#
.SYNOPSIS
    The translations suite: the checkout's .po files through the MPC-HC
    Translation Studio's validation ruleset.

.DESCRIPTION
    The Studio (mpc-hc-translations, a sibling repository) owns the rules for
    what a translation file may contain; its potool\potool.py is the single
    source of those rules, the same one its CI gate applies to clsid2/mpc-hc.
    This suite loads that script rather than restating the rules: every
    src\mpc-hc\mpcresources\PO\*.po of the checkout is run through it, and a
    file with an error fails the suite. Warnings are advisory there and here.

    On a branch, a file the branch changed is also checked in potool's PR mode
    against the version at the merge-base with upstream develop, which adds
    the structural rules (same key set, headers unchanged, only msgstr moved).

    Not here yet: the fit scan. The Studio measures every translated caption
    against its control by rendering the real dialogs off-screen
    (LivePreview::MeasureFit, driven by EnsureFitScan), which is the check
    the clipped-text reports (#2697, #2816, #4076, #4107, #4141, #4159) call
    for. It runs inside the Studio's UI and has no headless entry point; when
    Studio.exe gains one, Invoke-FitScan below is where it plugs in.

    Where the Studio is: $env:MPC_TEST_STUDIO, else StudioRoot in
    testbed.config.psd1, else C:\dev\mpc-hc-translations if that exists.

    No player, no rig.
#>
[CmdletBinding()]
param(
    [switch] $Probe,
    [string] $VMName = '',
    [string] $OutDir = (Join-Path $PSScriptRoot 'results'),
    [string] $PlayerBinary
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$description = "The checkout's .po files through the Translation Studio's validation ruleset (potool); no player, no rig"
$testsRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$repoRoot = Split-Path $testsRoot -Parent
$poDir = Join-Path $repoRoot 'src\mpc-hc\mpcresources\PO'

function Find-StudioRoot {
    if ($env:MPC_TEST_STUDIO) { return $env:MPC_TEST_STUDIO }
    $dir = $testsRoot
    while ($dir) {
        $cand = Join-Path $dir 'testbed.config.psd1'
        if (Test-Path $cand) {
            $cfg = Import-PowerShellDataFile $cand
            if ($cfg.ContainsKey('StudioRoot') -and $cfg.StudioRoot) { return $cfg.StudioRoot }
            break
        }
        $dir = Split-Path $dir -Parent
    }
    if (Test-Path 'C:\dev\mpc-hc-translations\potool\potool.py') { return 'C:\dev\mpc-hc-translations' }
    $null
}

$studio = Find-StudioRoot
$potool = if ($studio) { Join-Path $studio 'potool\potool.py' } else { $null }

if ($Probe) {
    $ready = $true; $reason = ''
    if (-not (Test-Path $poDir)) { $ready = $false; $reason = "no PO directory at $poDir" }
    elseif (-not (Get-Command python -ErrorAction SilentlyContinue)) { $ready = $false; $reason = 'python not on PATH' }
    elseif (-not $studio) { $ready = $false; $reason = 'Translation Studio checkout not found (set MPC_TEST_STUDIO or StudioRoot in testbed.config.psd1)' }
    elseif (-not (Test-Path $potool)) { $ready = $false; $reason = "no potool at $potool" }
    return [pscustomobject]@{ Suite = 'translations'; Description = $description; Ready = $ready; Reason = $reason; NeedsRig = $false }
}

New-Item -ItemType Directory -Force $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path
$passed = 0; $failed = 0; $skipped = 0
$notes = [System.Collections.Generic.List[string]]::new()
function Note { param([string] $Colour, [string] $Text) $notes.Add($Text); Write-Host "  $Text" -ForegroundColor $Colour }

# --- which files the branch changed, for PR mode --------------------------------

$baseRef = $null
foreach ($cand in 'upstream/develop', 'origin/develop') {
    if (git -C $repoRoot rev-parse --verify --quiet $cand 2>$null) { $baseRef = $cand; break }
}
$changed = @{}
if ($baseRef) {
    $mergeBase = git -C $repoRoot merge-base HEAD $baseRef 2>$null
    if ($mergeBase) {
        foreach ($f in @(git -C $repoRoot diff --name-only $mergeBase HEAD -- 'src/mpc-hc/mpcresources/PO/*.po')) {
            if ($f) { $changed[(Split-Path $f -Leaf)] = $mergeBase }
        }
    }
}
Note Gray ("Studio ruleset: {0}; {1} .po files{2}" -f $potool, (Get-ChildItem $poDir -Filter *.po).Count,
    $(if ($changed.Count) { "; $($changed.Count) changed on this branch, checked in PR mode against $baseRef" } else { '' }))

# --- every file through potool ------------------------------------------------

$report = [System.Collections.Generic.List[object]]::new()
$warningsByRule = @{}
$tmp = Join-Path $OutDir 'base'
New-Item -ItemType Directory -Force $tmp | Out-Null

foreach ($po in Get-ChildItem $poDir -Filter *.po | Sort-Object Name) {
    $args = @($potool, $po.FullName)
    if ($changed.ContainsKey($po.Name)) {
        $basePath = Join-Path $tmp $po.Name
        $rel = "src/mpc-hc/mpcresources/PO/$($po.Name)"
        # Bytes as stored, not re-decoded through the console: potool checks the encoding and BOM itself.
        Start-Process git -ArgumentList @('-C', "`"$repoRoot`"", 'show', "`"$($changed[$po.Name]):$rel`"") -RedirectStandardOutput $basePath -NoNewWindow -Wait
        if ((Get-Item $basePath).Length -gt 0) { $args += @('--base', $basePath) }
    }
    $output = & python @args 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $summary = $output | Where-Object { $_ -match '^\S+\.po: (\d+) error\(s\), (\d+) warning\(s\)' } | Select-Object -Last 1
    $errors = if ($summary -match '(\d+) error') { [int]$Matches[1] } else { -1 }
    $warnings = if ($summary -match '(\d+) warning') { [int]$Matches[1] } else { -1 }
    foreach ($w in @($output | Where-Object { $_ -match '^\s*WARNING (\S+)' })) {
        $rule = ($w -replace '^\s*WARNING (\S+).*', '$1')
        $warningsByRule[$rule] = 1 + $(if ($warningsByRule.ContainsKey($rule)) { $warningsByRule[$rule] } else { 0 })
    }
    $errorLines = @($output | Where-Object { $_ -match '^\s*ERROR' })
    $report.Add([pscustomobject]@{ file = $po.Name; exit = $code; errors = $errors; warnings = $warnings; prMode = $changed.ContainsKey($po.Name); errorLines = $errorLines })

    if ($code -eq 0 -and $errors -eq 0) { $passed++ }
    else {
        $failed++
        $first = if ($errorLines) { $errorLines[0].Trim() } elseif ($summary) { $summary } else { ($output | Select-Object -Last 1) }
        Note Red "FAIL $($po.Name): $first"
    }
}

$report | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $OutDir 'potool-report.json')
$totalWarnings = ($report | Measure-Object warnings -Sum).Sum
$ruleSummary = ($warningsByRule.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "$($_.Key) $($_.Value)" }) -join ', '
Note ($(if ($failed) { 'Red' } else { 'Green' })) "$($report.Count) files: $passed clean, $failed with errors; $totalWarnings advisory warning(s) ($ruleSummary)"

# --- the fit scan, when the Studio can be driven without its window ----------------

function Invoke-FitScan {
    # The Studio's off-screen fit scan (LivePreview::MeasureFit over every dialog of the neutral resource
    # DLL, per language) is the check for translated captions wider than their controls. It has no
    # command-line form yet. When it does, run it here against $poDir and turn each "does not fit" into a
    # failure line: language, dialog, control, rendered px, available px.
    $exe = if ($studio) { Get-ChildItem (Join-Path $studio 'studio') -Recurse -Filter Studio.exe -ErrorAction SilentlyContinue | Select-Object -First 1 } else { $null }
    if (-not $exe) { return 'fit scan: no Studio.exe built in the Studio checkout' }
    $help = & $exe.FullName --help 2>&1 | Out-String
    if ($help -notmatch 'fit-scan') { return 'fit scan: Studio.exe has no headless --fit-scan yet (asked of the Studio); the rendered-width check is not run' }
    return $null
}
$fit = Invoke-FitScan
if ($fit) { $skipped++; Note Yellow "SKIP $fit" }

[pscustomobject]@{ Suite = 'translations'; Passed = $passed; Failed = $failed; Skipped = $skipped; Notes = $notes }
