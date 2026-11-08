<#
.SYNOPSIS
    The ytdl suite: how the player turns yt-dlp's JSON into playlist entries.

.DESCRIPTION
    The player is pointed at fake-ytdlp.cmd (YDLExePath), which prints the
    canned playlist.json for the fake playlist URL and fails for anything else.
    It is launched with /new /open, and the playlist it saves
    (default.mpcpl, beside the exe in portable mode) is read back. That file
    carries each entry's label, file, source URL and yt-dlp subtitles, which is
    everything CYoutubeDLInstance::GetHttpStreams produced for it.

    The four entries are built to show fields leaking from one entry into the
    next: A has a title, series, episode and a subtitle; B has a title only; C
    has no title and its own subtitle; D is url-only.

    Runs on the host: no network, no rig. The player is copied into -OutDir,
    so it never shares a folder or a settings file with another player.
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

$description = 'yt-dlp JSON to playlist entries, through a fake yt-dlp; host only, no network, no rig'
$repoRoot = Split-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path -Parent
if (-not $PlayerBinary) { $PlayerBinary = Join-Path $repoRoot 'bin\mpc-hc_x64\mpc-hc64.exe' }

if ($Probe) {
    $ready = Test-Path $PlayerBinary
    $reason = if ($ready) { '' } else { "no player at $PlayerBinary" }
    return [pscustomobject]@{ Suite = 'ytdl'; Description = $description; Ready = $ready; Reason = $reason; NeedsRig = $false }
}

New-Item -ItemType Directory -Force $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path
$passed = 0; $failed = 0; $skipped = 0
$notes = [System.Collections.Generic.List[string]]::new()
function Note { param([string] $Colour, [string] $Text) $notes.Add($Text); Write-Host "  $Text" -ForegroundColor $Colour }

Add-Type -Namespace YdlSuite -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool PostMessage(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
'@

# --- run the player once ----------------------------------------------------------

$playerDir = Join-Path $OutDir 'player'
if (Test-Path $playerDir) { Remove-Item $playerDir -Recurse -Force }
New-Item -ItemType Directory $playerDir | Out-Null
Copy-Item $PlayerBinary $playerDir
$iconLib = Join-Path (Split-Path $PlayerBinary -Parent) 'mpciconlib.dll'
if (Test-Path $iconLib) { Copy-Item $iconLib $playerDir }

$fake = Join-Path $PSScriptRoot 'fake-ytdlp.cmd'
$ini = @"
[Settings]
UpdaterAutoCheck=0
UseYDL=1
YDLExePath=$fake
YDLSubsPreference=en
UseAutomaticCaptions=0
RememberPlaylistItems=1
DebugLogMask=4
"@
Set-Content -Path (Join-Path $playerDir 'mpc-hc64.ini') -Value $ini -Encoding Unicode

$listUrl = 'https://www.youtube.com/playlist?list=PLfake'
$saved = Join-Path $playerDir 'default.mpcpl'
$p = Start-Process -FilePath (Join-Path $playerDir 'mpc-hc64.exe') -ArgumentList '/new', '/open', $listUrl -PassThru
try {
    # A freshly copied exe can take a while to start (it gets scanned), so wait
    # for the last entry to be in the file rather than for the file.
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline -and -not ((Test-Path $saved) -and (Select-String -Path $saved -Pattern '^4,type' -Quiet))) {
        Start-Sleep -Milliseconds 500
    }
    Start-Sleep -Seconds 1
    $lines = if (Test-Path $saved) { Get-Content $saved } else { @() }
    $p.Refresh()
    $state = if ($p.HasExited) { "exited 0x{0:X}" -f $p.ExitCode } else { "running, cpu $([int]$p.TotalProcessorTime.TotalMilliseconds) ms, window '$($p.MainWindowTitle)'" }
} finally {
    $p.Refresh()
    if (-not $p.HasExited) {
        if ($p.MainWindowHandle -ne [IntPtr]::Zero) { [void][YdlSuite.Win]::PostMessage($p.MainWindowHandle, 0x10, [IntPtr]::Zero, [IntPtr]::Zero) }
        if (-not $p.WaitForExit(10000)) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    }
}
Copy-Item $saved (Join-Path $OutDir 'default.mpcpl') -ErrorAction SilentlyContinue
Copy-Item (Join-Path $playerDir 'youtubedl.log') $OutDir -ErrorAction SilentlyContinue

if (-not $lines) { throw "the player saved no playlist within 60 s; player $state (log: $OutDir\youtubedl.log)" }

# --- parse the saved playlist -----------------------------------------------------

$entries = @{}
foreach ($line in $lines) {
    if ($line -notmatch '^(\d+),([^,]+),(.*)$') { continue }
    $i = [int]$Matches[1]; $key = $Matches[2]; $val = $Matches[3]
    if (-not $entries.ContainsKey($i)) { $entries[$i] = @{ label = ''; filename = ''; ydlSourceURL = ''; subs = [System.Collections.Generic.List[string]]::new() } }
    switch ($key) {
        'label'        { $entries[$i].label = $val }
        'filename'     { $entries[$i].filename = $val }
        'ydlSourceURL' { $entries[$i].ydlSourceURL = $val }
        { $_ -in 'ydl_sub', 'ydl_auto_sub' } { $entries[$i].subs.Add(($val -split ',')[-1]) }
    }
}
function E { param([int] $i) if ($entries.ContainsKey($i)) { $entries[$i] } else { @{ label = '<missing>'; filename = ''; ydlSourceURL = ''; subs = @() } } }
function Subs { param([int] $i) ((E $i).subs -join ' ') }

# --- cases ------------------------------------------------------------------------

$cases = @(
    @{ Name = 'playlist-entry-count'
       What = 'four entries, one per playlist.json entry'
       Ok   = { $entries.Count -eq 4 }
       Got  = { "$($entries.Count) entries" } }
    @{ Name = 'playlist-titles-independent'
       What = 'B has its own title and no series/episode from A; C, which has no title, has an empty one'
       Ok   = { (E 1).label.StartsWith('E01. SeriesA - Entry A (') -and (E 2).label.StartsWith('Entry B (') -and (E 3).label.StartsWith(' (') }
       Got  = { "1='$((E 1).label)' 2='$((E 2).label)' 3='$((E 3).label)'" } }
    @{ Name = 'playlist-subtitles-independent'
       What = 'each entry has only its own subtitles: A a.en.vtt, B none, C c.en.vtt, D none'
       Ok   = { (Subs 1) -eq 'http://example.invalid/a.en.vtt' -and (Subs 2) -eq '' -and (Subs 3) -eq 'http://example.invalid/c.en.vtt' -and (Subs 4) -eq '' }
       Got  = { "1='$(Subs 1)' 2='$(Subs 2)' 3='$(Subs 3)' 4='$(Subs 4)'" } }
    @{ Name = 'playlist-url-only-entry'
       What = 'the url-only entry D takes nothing from C: its own file, no title, the playlist URL as source'
       Ok   = { (E 4).filename -eq 'http://example.invalid/d.mp4' -and (E 4).label.StartsWith(' (') -and (E 4).ydlSourceURL -eq $listUrl }
       Got  = { "file='$((E 4).filename)' label='$((E 4).label)' source='$((E 4).ydlSourceURL)'" } }
)

$results = foreach ($c in $cases) {
    $ok = [bool](& $c.Ok)
    $got = & $c.Got
    if ($ok) { $passed++; Note Green "PASS $($c.Name)" } else { $failed++; Note Red "FAIL $($c.Name): expected $($c.What); got $got" }
    [pscustomobject]@{ case = $c.Name; passed = $ok; expected = $c.What; got = $got }
}
$results | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $OutDir 'result.json') -Encoding UTF8

[pscustomobject]@{ Suite = 'ytdl'; Passed = $passed; Failed = $failed; Skipped = $skipped; Notes = $notes }
