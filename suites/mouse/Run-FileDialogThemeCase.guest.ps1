# Runs on the target, in the console session. The controls MPC-HC injects into the Windows file dialogs
# (IFileDialogCustomize) under Windows dark mode; the host does the asserting. One JSON object goes to
# <OutDir>\result.json, with a screen capture of the injected check box beside each variant.
#
# #4281. With Windows apps in dark mode the Common File Dialog paints its own injected controls light
# (white label background, blue label text), so the player subclasses them and paints them dark. Three
# ways that went wrong, all exercised here through the folder picker's "Include subdirectories" box:
#
#   foreground   the player is the active window when the dialog opens. The unfixed build themes this
#                one everywhere; it is the control the others are read against.
#   background   another program (notepad) has the foreground. The unfixed build located the dialog by
#                watching the main frame's WM_ACTIVATE/WA_INACTIVE, which never arrives when the frame
#                was not active, so the controls stayed native. Reproduces on Windows 11 only: Windows 10
#                still delivered the message, so on a Windows 10 target this passes the unfixed build too.
#   minimized    the player is minimized when the dialog opens. Same cause, same Windows 11 only caveat.
#   win11style   foreground, modern theme in its Windows 11 style. The unfixed build painted the label and
#                box on a (28,28,28) rectangle, the palette's control colour, on the dialog's (56,56,56).
#   themeoff     foreground, modern theme off. The workaround subclassed the box but only took over its
#                painting when the theme was on, so Windows drew it: blue label on the dark dialog.
#
# Each variant is its own player launch from a fresh portable ini (the job gives the ini text), so
# nothing carries over. Windows dark mode is turned on for the console user for the duration
# (AppsUseLightTheme=0, read by the player at startup) and the previous value is put back at the end.
# The guest script only records: the window the dialog is, whether the player had the foreground, the
# check box's rectangle, and a capture of the check box with a margin of dialog around it.
param([Parameter(Mandatory)] [string] $Job)

$ErrorActionPreference = 'Stop'
$j = Get-Content -Raw $Job | ConvertFrom-Json
$outDir = $j.OutDir
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory $outDir | Out-Null }
$result = [ordered]@{ started = (Get-Date).ToString('o'); error = $null; variants = [ordered]@{} }
$result.osBuild = [Environment]::OSVersion.Version.Build
$personalize = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
$lightBefore = (Get-ItemProperty $personalize -Name AppsUseLightTheme -ErrorAction SilentlyContinue).AppsUseLightTheme
$result.appsUseLightThemeBefore = $lightBefore
$script:proc = $null

# All message numbers from winuser.h: WM_CLOSE 0x0010, WM_COMMAND 0x0111; SW_MINIMIZE 6

try {
    . (Join-Path $PSScriptRoot 'MouseInput.guest.ps1')
    Add-Type -AssemblyName System.Windows.Forms

    Add-Type @'
using System;
using System.Runtime.InteropServices;
public class FdRig {
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
}
'@

    # The first visible dialog-class top-level window of the process: the file dialog, once it is up.
    function Find-FileDialog {
        param([uint32] $ProcId)
        [MouseRig]::FindTop($ProcId, '#32770', '')
    }

    # The injected check box is a plain Button whose text is the resource string the player gave it.
    function Find-CheckBox {
        param([IntPtr] $Dialog, [string] $Label)
        $script:found = [IntPtr]::Zero
        [void][MouseRig]::EnumChildWindows($Dialog, {
            param($h, $l)
            if ([MouseRig]::ClassOf($h) -eq 'Button' -and [MouseRig]::TitleOf($h) -eq $Label) { $script:found = $h; return $false }
            return $true
        }, [IntPtr]::Zero)
        $script:found
    }

    Set-ItemProperty $personalize -Name AppsUseLightTheme -Value 0 -Type DWord

    foreach ($v in $j.Variants) {
        $r = [ordered]@{ error = $null }
        $script:proc = $null
        $stealer = $null
        try {
            Get-ChildItem (Split-Path $j.Exe -Parent) -Filter '*.ini' | ForEach-Object { [IO.File]::Delete($_.FullName) }
            [IO.File]::WriteAllText((Join-Path (Split-Path $j.Exe -Parent) 'mpc-hc64.ini'), $v.IniText, [Text.Encoding]::Unicode)

            $t = Start-TargetWindow -Exe $j.Exe -ArgumentLine '/new' -TopClass 'MediaPlayerClassicW'
            $script:proc = $t.Process
            $top = $t.Root

            switch ($v.Mode) {
                'minimized' {
                    [void][FdRig]::ShowWindow($top, 6)
                    Start-Sleep -Milliseconds 800
                }
                'background' {
                    # another window takes the foreground with a real click on its caption; the player stays
                    # restored. A form of our own rather than notepad: on Windows 11 notepad is a packaged app
                    # whose window does not belong to the process Start-Process returns.
                    $stealer = New-Object System.Windows.Forms.Form
                    $stealer.Text = 'foreground'; $stealer.StartPosition = 'Manual'
                    $stealer.Location = New-Object System.Drawing.Point 600, 300
                    $stealer.Size = New-Object System.Drawing.Size 300, 200
                    $stealer.Show(); [System.Windows.Forms.Application]::DoEvents()
                    Start-Sleep -Milliseconds 500
                    [void][MouseRig]::MoveTo(700, 312); Start-Sleep -Milliseconds 200
                    [void][MouseRig]::Click(); Start-Sleep -Milliseconds 500
                    [System.Windows.Forms.Application]::DoEvents()
                }
            }
            $r.playerForegroundBefore = ([MouseRig]::GetForegroundWindow() -eq $top)
            $r.playerMinimized = [FdRig]::IsIconic($top)

            $dlg = [IntPtr]::Zero
            for ($i = 0; $i -lt 10 -and $dlg -eq [IntPtr]::Zero; $i++) {
                [void][MouseRig]::PostMessage($top, 0x0111, [IntPtr][int]$j.OpenDirectoryCommand, [IntPtr]::Zero)   # WM_COMMAND
                Start-Sleep -Milliseconds 1500
                $dlg = Find-FileDialog ([uint32]$script:proc.Id)
            }
            if ($dlg -eq [IntPtr]::Zero) { throw 'the folder picker never appeared' }
            Start-Sleep -Milliseconds 2000
            if ($stealer) { $stealer.Close(); $stealer.Dispose(); $stealer = $null; [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 400 }
            # On its own, top-left, so nothing else on a small guest screen is in the capture.
            [void][MouseRig]::SetWindowPos($dlg, [IntPtr]::Zero, 20, 20, 900, 600, 0x0004 -bor 0x0010)
            Start-Sleep -Milliseconds 1200
            $dr = New-Object MouseRig+RECT
            [void][MouseRig]::GetWindowRect($dlg, [ref]$dr)
            $r.dialog = @{ L = $dr.L; T = $dr.T; R = $dr.R; B = $dr.B }

            $cb = Find-CheckBox $dlg $j.CheckBoxLabel
            $r.checkBoxFound = ($cb -ne [IntPtr]::Zero)
            if ($cb -eq [IntPtr]::Zero) { throw "no Button titled '$($j.CheckBoxLabel)' in the dialog" }
            $cr = New-Object MouseRig+RECT
            [void][MouseRig]::GetWindowRect($cb, [ref]$cr)
            # The check box with a 12 px margin of dialog on every side: the margin is the reference colour.
            $m = 12
            $png = "$($v.Name).png"
            Save-ScreenRegion (Join-Path $outDir $png) ($cr.L - $m) ($cr.T - $m) ($cr.R + $m) ($cr.B + $m)
            $r.png = $png
            $r.margin = $m
            $r.checkBox = @{ W = $cr.R - $cr.L; H = $cr.B - $cr.T }

            [void][MouseRig]::PostMessage($dlg, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE
            Start-Sleep -Milliseconds 800
        } catch {
            $r.error = $_.Exception.Message + ' @ ' + $_.InvocationInfo.PositionMessage
        } finally {
            if ($stealer) { $stealer.Close(); $stealer.Dispose(); [System.Windows.Forms.Application]::DoEvents() }
            if ($script:proc) {
                $main = [MouseRig]::FindTop([uint32]$script:proc.Id, 'MediaPlayerClassicW', '')
                if ($main -ne [IntPtr]::Zero) { [void][MouseRig]::PostMessage($main, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) }
                if (-not $script:proc.WaitForExit(10000)) { Stop-Process -Id $script:proc.Id -Force -ErrorAction SilentlyContinue; $r.killedOnClose = $true }
            }
            $result.variants[$v.Name] = $r
        }
    }
} catch {
    $result.error = $_.Exception.Message + ' @ ' + $_.InvocationInfo.PositionMessage
} finally {
    if ($null -ne $lightBefore) { Set-ItemProperty $personalize -Name AppsUseLightTheme -Value $lightBefore -Type DWord }
    else { Remove-ItemProperty $personalize -Name AppsUseLightTheme -ErrorAction SilentlyContinue }
    $result.finished = (Get-Date).ToString('o')
    $result | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $outDir 'result.json')
}
