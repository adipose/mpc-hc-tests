<#
.SYNOPSIS
    The language suite: switching the interface language while the player runs.

.DESCRIPTION
    Choosing Arabic or Hebrew mirrors the process layout (SetProcessDefaultLayout) and installs a CBT
    hook that mirrors every new top-level window. Before the fix nothing undid either, so after
    switching back to a left-to-right language every new window still came up mirrored until a restart,
    and each switch into an RTL language stacked one more hook.

    Cases (Run-LanguageCase.guest.ps1 on the target, in the console session, one launch each):

      rtl-to-ltr-new-window   start in Hebrew, switch to English in Options, open About: it must be
                              laid out left to right. The About box opened before the switch must be
                              mirrored, or the Hebrew resource did not load and nothing was tested

    Windows that already exist keep the layout they were created with, so the main window stays
    mirrored either way and is only recorded. Nothing here needs real input: the combo is set with
    CB_SETCURSEL and the sheet closed with a posted IDOK, so the scheduled task is only there to put
    the player in the console session.
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

$description = 'Runtime language switch: leaving Hebrew for English must stop mirroring new windows'
$testsRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$repoRoot = Split-Path $testsRoot -Parent
$transport = Join-Path $testsRoot 'emulator\tools\GuestTransport.ps1'

if ($Probe) {
    $ready = $true; $reason = ''
    if (-not (Test-Path $transport)) { $ready = $false; $reason = 'emulator submodule not initialised (git submodule update --init tests/emulator)' }
    return [pscustomobject]@{ Suite = 'language'; Description = $description; Ready = $ready; Reason = $reason }
}

New-Item -ItemType Directory -Force $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path
$passed = 0; $failed = 0; $skipped = 0
$notes = [System.Collections.Generic.List[string]]::new()
function Note { param([string] $Colour, [string] $Text) $notes.Add($Text); Write-Host "  $Text" -ForegroundColor $Colour }
function Finish { [pscustomobject]@{ Suite = 'language'; Passed = $passed; Failed = $failed; Skipped = $skipped; Notes = $notes } }
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
    ViewOptions   = Get-ResourceId 'ID_VIEW_OPTIONS' 815
    HelpAbout     = Get-ResourceId 'ID_HELP_ABOUT' 943
    LanguageCombo = Get-ResourceId 'IDC_COMBO2' 11001
}
$idThemePage = Get-ResourceId 'IDD_PPAGETHEME' 10038

$playerDir = if ($PlayerBinary) { Split-Path (Resolve-Path $PlayerBinary).Path -Parent }
             elseif (Test-Path (Join-Path $repoRoot 'bin\mpc-hc_x64\mpc-hc64.exe')) { Join-Path $repoRoot 'bin\mpc-hc_x64' }
             else { $null }
if (-not $playerDir) { throw 'No player build: pass -PlayerBinary or build this repository (bin\mpc-hc_x64\mpc-hc64.exe).' }

# The player loads a language dll only when its version matches the exe's major.minor.patch and
# silently falls back to English otherwise. A project-only build leaves the dlls of whatever last built
# translations, so check here rather than report a fallback as a result.
$heDll = Join-Path $playerDir 'Lang\mpcresources.he.dll'
if (-not (Test-Path $heDll)) { throw "No ${heDll}: build translations (build.bat Build x64 Translations)." }
$exeVer = (Get-Item (Join-Path $playerDir 'mpc-hc64.exe')).VersionInfo
$dllVer = (Get-Item $heDll).VersionInfo
if ($exeVer.FileMajorPart -ne $dllVer.FileMajorPart -or $exeVer.FileMinorPart -ne $dllVer.FileMinorPart -or $exeVer.FileBuildPart -ne $dllVer.FileBuildPart) {
    throw "mpcresources.he.dll is $($dllVer.FileVersion) and the exe $($exeVer.FileVersion): rebuild translations (build.bat Build x64 Translations)."
}

. $transport
$cfg = Get-TestBedConfig -Guest $VMName
$session = Connect-TestGuest -Guest $VMName
try {
    $console = Invoke-Command -Session $session { (Get-CimInstance Win32_ComputerSystem).UserName }
    $consoleUser = if ($cfg.GuestConsoleUser) { $cfg.GuestConsoleUser } else { ("$console" -split '\\')[-1] }
    if (-not $consoleUser) { throw 'Nobody is logged on at the guest console; the player needs a desktop.' }

    # Deploy: no media is played, so the exe, its icon library and the Hebrew dll are all it needs.
    $stage = Join-Path $OutDir 'player-stage'
    if (Test-Path $stage) { Get-ChildItem $stage -Recurse -File | ForEach-Object { [IO.File]::Delete($_.FullName) } }
    New-Item -ItemType Directory -Force (Join-Path $stage 'Lang') | Out-Null
    Copy-Item (Join-Path $playerDir 'mpc-hc64.exe') $stage
    if (Test-Path (Join-Path $playerDir 'mpciconlib.dll')) { Copy-Item (Join-Path $playerDir 'mpciconlib.dll') $stage }
    Copy-Item $heDll (Join-Path $stage 'Lang')
    $zip = Join-Path $OutDir 'player.zip'
    if (Test-Path $zip) { [IO.File]::Delete($zip) }
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip

    Invoke-Command -Session $session {
        Get-Process mpc-hc64 -ErrorAction SilentlyContinue | Stop-Process -Force
        foreach ($d in 'C:\mpc-test', 'C:\mpc-test\language', 'C:\mpc-test\language\out') { if (-not (Test-Path $d)) { New-Item -ItemType Directory $d | Out-Null } }
    }
    Copy-Item -ToSession $session $zip 'C:\mpc-test\language\player.zip' -Force
    Copy-Item -ToSession $session (Join-Path $PSScriptRoot 'Run-LanguageCase.guest.ps1') 'C:\mpc-test\language\' -Force
    Invoke-Command -Session $session {
        if (Test-Path 'C:\mpc-test\language\player') { Remove-Item 'C:\mpc-test\language\player' -Recurse -Force }
        Expand-Archive 'C:\mpc-test\language\player.zip' 'C:\mpc-test\language\player' -Force
        # the case runs as the console user, who writes its results and the player's ini here
        & icacls 'C:\mpc-test\language' /grant 'Users:(OI)(CI)M' /T | Out-Null
    }
    $version = Invoke-Command -Session $session { (Get-Item 'C:\mpc-test\language\player\mpc-hc64.exe').VersionInfo.ProductVersion }
    Note Gray "player under test: $version from $playerDir"

    # One launch per job, from a fresh portable ini, in the console session through a scheduled task.
    function Invoke-LanguageJob {
        param([string] $Name, [string] $JobCase, [string] $IniText)
        $guestOut = "C:\mpc-test\language\out\$Name"
        $job = @{ Exe = 'C:\mpc-test\language\player\mpc-hc64.exe'; OutDir = $guestOut; Case = $JobCase; Ids = $ids } | ConvertTo-Json -Depth 4
        $json = Invoke-Command -Session $session -ArgumentList $job, $guestOut, $IniText, $consoleUser {
            param($job, $out, $iniText, $user)
            $ErrorActionPreference = 'Continue'
            Get-Process mpc-hc64 -ErrorAction SilentlyContinue | Stop-Process -Force
            if (Test-Path $out) { Remove-Item $out -Recurse -Force }
            New-Item -ItemType Directory $out | Out-Null
            & icacls $out /grant 'Users:(OI)(CI)M' | Out-Null
            Get-ChildItem 'C:\mpc-test\language\player' -Filter '*.ini' | ForEach-Object { [IO.File]::Delete($_.FullName) }
            [IO.File]::WriteAllText('C:\mpc-test\language\player\mpc-hc64.ini', $iniText, [Text.Encoding]::Unicode)
            [IO.File]::WriteAllText('C:\mpc-test\language\job.json', $job)

            $taskArgs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\mpc-test\language\Run-LanguageCase.guest.ps1 -Job C:\mpc-test\language\job.json'
            $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $taskArgs
            $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive
            Register-ScheduledTask -TaskName 'MpcLanguageCase' -Action $action -Principal $principal -Force | Out-Null
            Start-ScheduledTask -TaskName 'MpcLanguageCase'
            $deadline = (Get-Date).AddSeconds(120)
            while (-not (Test-Path "$out\result.json") -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
            Unregister-ScheduledTask -TaskName 'MpcLanguageCase' -Confirm:$false
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

    if (Wanted 'rtl-to-ltr-new-window') {
        $ini = "[Settings]`r`nUpdaterAutoCheck=0`r`nKeepHistory=0`r`nInterfaceLanguage=1037`r`nLastUsedPage=$idThemePage`r`n"
        $run = Invoke-LanguageJob -Name 'rtl-to-ltr-new-window' -JobCase 'rtl-to-ltr' -IniText $ini
        $p = @()
        if (-not $run.aboutBefore.rtl) { $p += "the About box was not mirrored in Hebrew ('$($run.aboutBefore.title)'), so the Hebrew resource did not load and nothing was tested" }
        if ($run.iniAfter -notmatch 'InterfaceLanguage=0') { $p += 'the switch to English was not saved, so it did not apply' }
        if ($run.aboutAfter.rtl) { $p += "the About box opened after switching to English ('$($run.aboutAfter.title)') is still mirrored" }
        Note Gray "main window mirrored throughout (created in Hebrew): $($run.frameRtl)"
        Complete-Case 'rtl-to-ltr-new-window' $p
    }
}
finally {
    Remove-PSSession $session -ErrorAction SilentlyContinue
}

Finish
