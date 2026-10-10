<#
.SYNOPSIS
    The lifecycle suite: how the player's frame comes down while a modal it owns is up.

.DESCRIPTION
    An exit requested while the Options dialog was open ran inside the dialog's modal pump. OnClose
    deleted the frame with ShowOptions still on the stack, and ShowOptions returned into freed memory
    (#4257, DrDump 1000443). Whether that crashes depends on the freed memory being reused, about one
    run in twenty here, so the crash is not what is asserted. What is asserted is the order Windows
    reports the windows coming down in, which is the same every run: before the fix the frame is hidden
    while the sheet is still up; after it the sheet is gone before the frame is even hidden.

    Cases (Run-LifecycleCase.guest.ps1 on the target, in the console session, one launch each):

      options-exit-deferred      ID_FILE_EXIT posted with Options up, as the web interface, "exit
                                 after playback" and /close do
      options-sysclose-deferred  WM_SYSCOMMAND SC_CLOSE posted with Options up, as the taskbar does
      options-reset-relaunches   Reset settings from Options > Miscellaneous: the player exits, one
                                 new instance comes up, and the settings are gone. A guard, passing
                                 on builds before and after the fix alike

    Nothing here needs real input: these are posted commands and the evidence is a WinEvent hook, so
    the scheduled task is only there to put the player in the console session.
#>
[CmdletBinding()]
param(
    [switch] $Probe,
    [string] $VMName = '',
    [string] $OutDir = (Join-Path $PSScriptRoot 'results'),
    [string] $PlayerBinary,
    [string[]] $Case          # wildcards against case names; empty runs everything
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$description = 'Frame teardown with a modal up: an exit with Options open must close the sheet before the frame (#4257); a settings reset still relaunches'
$testsRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$repoRoot = Split-Path $testsRoot -Parent
$transport = Join-Path $testsRoot 'emulator\tools\GuestTransport.ps1'

if ($Probe) {
    $ready = $true; $reason = ''
    if (-not (Test-Path $transport)) { $ready = $false; $reason = 'emulator submodule not initialised (git submodule update --init tests/emulator)' }
    return [pscustomobject]@{ Suite = 'lifecycle'; Description = $description; Ready = $ready; Reason = $reason }
}

New-Item -ItemType Directory -Force $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path
$passed = 0; $failed = 0; $skipped = 0
$notes = [System.Collections.Generic.List[string]]::new()
function Note { param([string] $Colour, [string] $Text) $notes.Add($Text); Write-Host "  $Text" -ForegroundColor $Colour }
function Finish { [pscustomobject]@{ Suite = 'lifecycle'; Passed = $passed; Failed = $failed; Skipped = $skipped; Notes = $notes } }
function Complete-Case {
    param([string] $Name, [string[]] $Problems)
    $Problems = @($Problems | Where-Object { $_ })
    if ($Problems.Count -eq 0) { $script:passed++; Note Green "PASS $Name" }
    else { $script:failed++; Note Red "FAIL ${Name}: $($Problems -join ' | ')" }
}
function Wanted {
    param([string] $Name)
    if (-not $Case) { return $true }
    foreach ($c in $Case) { if ($Name -like $c) { return $true } }
    $script:skipped++
    $false
}

# The player's numbers come from the checkout's resource.h when this repository is mounted in one. The
# defaults are develop's.
function Get-ResourceId {
    param([string] $Name, [int] $Default)
    $header = Join-Path $repoRoot 'src\mpc-hc\resource.h'
    if (Test-Path $header) {
        $hit = Select-String -Path $header -Pattern ("^#define\s+{0}\s+(\d+)" -f [regex]::Escape($Name)) | Select-Object -First 1
        if ($hit) { return [int]$hit.Matches[0].Groups[1].Value }
    }
    $Default
}
$ids = @{
    ViewOptions = Get-ResourceId 'ID_VIEW_OPTIONS' 815
    FileExit    = Get-ResourceId 'ID_FILE_EXIT' 816
    ResetButton = Get-ResourceId 'IDC_RESET_SETTINGS' 11133
}
$idMiscPage = Get-ResourceId 'IDD_PPAGEMISC' 10052

$playerDir = if ($PlayerBinary) { Split-Path (Resolve-Path $PlayerBinary).Path -Parent }
             elseif (Test-Path (Join-Path $repoRoot 'bin\mpc-hc_x64\mpc-hc64.exe')) { Join-Path $repoRoot 'bin\mpc-hc_x64' }
             else { $null }
if (-not $playerDir) { throw 'No player build: pass -PlayerBinary or build this repository (bin\mpc-hc_x64\mpc-hc64.exe).' }

. $transport
$cfg = Get-TestBedConfig
$session = Connect-TestGuest -Guest $VMName
try {
    $console = Invoke-Command -Session $session { (Get-CimInstance Win32_ComputerSystem).UserName }
    $consoleUser = if ($cfg.GuestConsoleUser) { $cfg.GuestConsoleUser } else { ("$console" -split '\\')[-1] }
    if (-not $consoleUser) { throw 'Nobody is logged on at the guest console; the player needs a desktop.' }

    # Deploy: no media is played, so the exe and its icon library are all the player needs.
    $stage = Join-Path $OutDir 'player-stage'
    if (Test-Path $stage) { Get-ChildItem $stage -Recurse -File | ForEach-Object { [IO.File]::Delete($_.FullName) } }
    New-Item -ItemType Directory -Force $stage | Out-Null
    Copy-Item (Join-Path $playerDir 'mpc-hc64.exe') $stage
    if (Test-Path (Join-Path $playerDir 'mpciconlib.dll')) { Copy-Item (Join-Path $playerDir 'mpciconlib.dll') $stage }
    $zip = Join-Path $OutDir 'player.zip'
    if (Test-Path $zip) { [IO.File]::Delete($zip) }
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip

    Invoke-Command -Session $session {
        Get-Process mpc-hc64 -ErrorAction SilentlyContinue | Stop-Process -Force
        foreach ($d in 'C:\mpc-test', 'C:\mpc-test\lifecycle', 'C:\mpc-test\lifecycle\out') { if (-not (Test-Path $d)) { New-Item -ItemType Directory $d | Out-Null } }
    }
    Copy-Item -ToSession $session $zip 'C:\mpc-test\lifecycle\player.zip' -Force
    Copy-Item -ToSession $session (Join-Path $PSScriptRoot 'Run-LifecycleCase.guest.ps1') 'C:\mpc-test\lifecycle\' -Force
    Invoke-Command -Session $session {
        if (Test-Path 'C:\mpc-test\lifecycle\player') { Remove-Item 'C:\mpc-test\lifecycle\player' -Recurse -Force }
        Expand-Archive 'C:\mpc-test\lifecycle\player.zip' 'C:\mpc-test\lifecycle\player' -Force
        # the case runs as the console user, who writes its results and the player's ini here
        & icacls 'C:\mpc-test\lifecycle' /grant 'Users:(OI)(CI)M' /T | Out-Null
    }
    $version = Invoke-Command -Session $session { (Get-Item 'C:\mpc-test\lifecycle\player\mpc-hc64.exe').VersionInfo.ProductVersion }
    Note Gray "player under test: $version from $playerDir"

    # One launch per job, from a fresh portable ini, in the console session through a scheduled task.
    function Invoke-LifecycleJob {
        param([string] $Name, [string] $JobCase, [string] $How, [string] $IniText)
        $guestOut = "C:\mpc-test\lifecycle\out\$Name"
        $job = @{ Exe = 'C:\mpc-test\lifecycle\player\mpc-hc64.exe'; OutDir = $guestOut; Case = $JobCase; How = $How; Ids = $ids } | ConvertTo-Json -Depth 4
        $json = Invoke-Command -Session $session -ArgumentList $job, $guestOut, $IniText, $consoleUser {
            param($job, $out, $iniText, $user)
            $ErrorActionPreference = 'Continue'
            Get-Process mpc-hc64 -ErrorAction SilentlyContinue | Stop-Process -Force
            if (Test-Path $out) { Remove-Item $out -Recurse -Force }
            New-Item -ItemType Directory $out | Out-Null
            & icacls $out /grant 'Users:(OI)(CI)M' | Out-Null
            Get-ChildItem 'C:\mpc-test\lifecycle\player' -Filter '*.ini' | ForEach-Object { [IO.File]::Delete($_.FullName) }
            Remove-Item 'C:\mpc-test\lifecycle\player\default.mpcpl' -Force -ErrorAction SilentlyContinue
            [IO.File]::WriteAllText('C:\mpc-test\lifecycle\player\mpc-hc64.ini', $iniText, [Text.Encoding]::Unicode)
            [IO.File]::WriteAllText('C:\mpc-test\lifecycle\job.json', $job)

            $taskArgs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\mpc-test\lifecycle\Run-LifecycleCase.guest.ps1 -Job C:\mpc-test\lifecycle\job.json'
            $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $taskArgs
            $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive
            Register-ScheduledTask -TaskName 'MpcLifecycleCase' -Action $action -Principal $principal -Force | Out-Null
            Start-ScheduledTask -TaskName 'MpcLifecycleCase'
            $deadline = (Get-Date).AddSeconds(180)
            while (-not (Test-Path "$out\result.json") -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
            Unregister-ScheduledTask -TaskName 'MpcLifecycleCase' -Confirm:$false
            Get-Process mpc-hc64 -ErrorAction SilentlyContinue | Stop-Process -Force
            if (Test-Path "$out\result.json") { Get-Content "$out\result.json" -Raw } else { $null }
        }
        if (-not $json) { throw "job $Name produced no result on the guest" }
        $local = Join-Path $OutDir $Name
        New-Item -ItemType Directory -Force $local | Out-Null
        Set-Content (Join-Path $local 'result.json') $json
        $run = $json | ConvertFrom-Json
        if ($run.error) { throw "job $Name failed on the guest: $($run.error)" }
        $run
    }

    $plainIni = "[Settings]`r`nUpdaterAutoCheck=0`r`nKeepHistory=0`r`n"

    # The exit cases. Each of the four events must be there, so a run that saw nothing cannot pass.
    function Test-ExitDeferred {
        param($Run)
        $p = @()
        if (-not $Run.exited) { $p += 'the player did not exit within 20 s' }
        elseif ($Run.exitCode -ne 0) { $p += ('exit code 0x{0:X8}' -f [uint32]$Run.exitCode) }
        $ev = @($Run.events)
        foreach ($e in 'sheet destroy', 'frame hide', 'frame destroy') { if ($e -notin $ev) { $p += "no '$e' event (saw: $($ev -join ', '))" } }
        if ('sheet destroy' -in $ev -and 'frame hide' -in $ev -and [array]::IndexOf($ev, 'frame hide') -lt [array]::IndexOf($ev, 'sheet destroy')) {
            $p += "the frame was hidden with Options still up, so OnClose ran inside the sheet's pump ($($ev -join ', '))"
        }
        $p
    }
    foreach ($x in @(@{ Name = 'options-exit-deferred'; How = 'exit' }, @{ Name = 'options-sysclose-deferred'; How = 'sysclose' })) {
        if (Wanted $x.Name) {
            $run = Invoke-LifecycleJob -Name $x.Name -JobCase 'exit' -How $x.How -IniText $plainIni
            Complete-Case $x.Name (Test-ExitDeferred $run)
        }
    }

    # The reset guard. Options opens at Miscellaneous; ResetMarker is a key only a reset removes.
    if (Wanted 'options-reset-relaunches') {
        $resetIni = "[Settings]`r`nUpdaterAutoCheck=0`r`nKeepHistory=0`r`nLastUsedPage=$idMiscPage`r`nResetMarker=1`r`n"
        $run = Invoke-LifecycleJob -Name 'options-reset-relaunches' -JobCase 'reset' -How '' -IniText $resetIni
        $p = @()
        if (-not $run.exited) { $p += 'the first instance did not exit within 20 s' }
        elseif ($run.exitCode -ne 0) { $p += ('first instance exit code 0x{0:X8}' -f [uint32]$run.exitCode) }
        if (-not $run.relaunched) { $p += 'no new instance started' }
        if ($run.instancesLeft -ne 1) { $p += "$($run.instancesLeft) instances running afterwards, not 1" }
        if ($run.iniAfter -match 'ResetMarker') { $p += 'the settings survived the reset' }
        Complete-Case 'options-reset-relaunches' $p
    }
}
finally {
    Remove-PSSession $session -ErrorAction SilentlyContinue
}

Finish
