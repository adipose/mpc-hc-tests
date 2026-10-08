# Runs on the target, in the console session. One case around the Options dialog and the modern
# theme; the host does the asserting. One JSON object goes to <OutDir>\result.json, with screen
# captures beside it.
#
#   d3d9       options-d3d9-device-hidden-on-one-adapter  #4033, 0654c07e01. Modern Dark, Options at
#              the Output page. On a one-adapter guest the "Select D3D9 Render Device" checkbox
#              (IDC_D3D9DEVICE) and its combo (IDC_D3D9DEVICE_COMBO) must be hidden. The unfixed
#              build never hides them: it only disables them (on the old layout they sit on the
#              Output page itself; on the current one in the "Video Renderer Settings" popup that the
#              page's gear button opens). The other half of the fix: the themed OnEnable wrapped
#              __super::OnEnable in SetRedraw(FALSE)/SetRedraw(TRUE), and SetRedraw(TRUE) sets
#              WS_VISIBLE, so any enable/disable of an already-hidden control showed it again. On the
#              current page the only post-init EnableWindow reaching these controls is the Reset
#              button's (the combo), so after the open-time check the script clicks Reset and then
#              delivers WM_ENABLE (0x000A, winuser.h) to both controls directly -- the same message
#              CWnd::EnableWindow sends -- and checks they are still hidden.
#              The renderer selection (IDC_VIDRND_COMBO) is switched to EVR Custom with a posted
#              CB_SETCURSEL + CBN_SELCHANGE, not a real click: OnDSRendererChange runs the same
#              either way, and what is asserted is the D3D9 controls' visibility, not the combo's
#              input path (real-input combo driving is what Run-ComboHoverCase covers).
param([Parameter(Mandatory)] [string] $Job)

$ErrorActionPreference = 'Stop'
$j = Get-Content -Raw $Job | ConvertFrom-Json
$outDir = $j.OutDir
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory $outDir | Out-Null }
$result = [ordered]@{ started = (Get-Date).ToString('o'); case = $j.Case; error = $null }
$script:proc = $null
$script:mainHwnd = [IntPtr]::Zero

# All message numbers from the SDK headers (winuser.h, CommCtrl.h), never guessed:
#   WM_COMMAND 0x0111, WM_CLOSE 0x0010, WM_ENABLE 0x000A, IDCANCEL 2
#   CB_GETCOUNT 0x0146, CB_GETCURSEL 0x0147, CB_SETCURSEL 0x014E, CB_GETITEMDATA 0x0150, CBN_SELCHANGE 1
#   VIDRNDT_DS_EVR_CUSTOM 11 (AppSettings.h)

try {
    . (Join-Path $PSScriptRoot 'MouseInput.guest.ps1')

    function Send-Int {
        param([IntPtr] $Hwnd, [uint32] $Msg, [IntPtr] $W, [IntPtr] $L)
        [MouseRig]::SendMessage($Hwnd, $Msg, $W, $L).ToInt32()
    }

    function Click-Center {
        param([IntPtr] $Hwnd)
        $r = New-Object MouseRig+RECT
        [void][MouseRig]::GetWindowRect($Hwnd, [ref]$r)
        Move-PointerGlide ([int](($r.L + $r.R) / 2)) ([int](($r.T + $r.B) / 2))
        Start-Sleep -Milliseconds 300
        [void][MouseRig]::Click()
        Start-Sleep -Milliseconds 600
    }

    # A window's region, optionally with a margin, clipped to the screen.
    function Save-WindowShot {
        param([string] $Name, [IntPtr] $Hwnd, [int] $Margin = 0)
        $r = New-Object MouseRig+RECT
        [void][MouseRig]::GetWindowRect($Hwnd, [ref]$r)
        $scrW = [MouseRig]::GetSystemMetrics(0); $scrH = [MouseRig]::GetSystemMetrics(1)
        $l = [Math]::Max(0, $r.L - $Margin); $tp = [Math]::Max(0, $r.T - $Margin)
        $rt = [Math]::Min($scrW, $r.R + $Margin); $bt = [Math]::Min($scrH, $r.B + $Margin)
        $png = "$Name.png"
        Save-ScreenRegion (Join-Path $outDir $png) $l $tp $rt $bt
        @{ png = $png; rect = @{ L = $l; T = $tp; R = $rt; B = $bt }; window = @{ L = $r.L; T = $r.T; R = $r.R; B = $r.B } }
    }

    function Open-Options {
        $t = Start-TargetWindow -Exe $j.Exe -TopClass 'MediaPlayerClassicW' -PostCommand ([int]$j.PostCommand) -DialogTitle $j.DialogTitle
        $script:proc = $t.Process
        $script:mainHwnd = [IntPtr]::Zero
        $t
    }

    function Close-OptionsDialog {
        param([IntPtr] $Root)
        [void][MouseRig]::PostMessage($Root, 0x0111, [IntPtr]2, [IntPtr]::Zero)   # WM_COMMAND, IDCANCEL
        Start-Sleep -Milliseconds 800
    }

    function Invoke-D3D9Case {
        $t = Open-Options
        $root = $t.Root            # the Options dialog, at the Output page (the job's ini set LastUsedPage)
        $result.optionsForeground = $t.Foreground

        $vidCombo = [MouseRig]::FindChild($root, [int]$j.Ids.VidRndCombo)
        if ($vidCombo -eq [IntPtr]::Zero) { throw 'the renderer combo (IDC_VIDRND_COMBO) was not found; not on the Output page?' }
        $n = Send-Int $vidCombo 0x0146 ([IntPtr]::Zero) ([IntPtr]::Zero)      # CB_GETCOUNT
        $evrCustom = -1
        for ($i = 0; $i -lt $n; $i++) {
            if ((Send-Int $vidCombo 0x0150 ([IntPtr]$i) ([IntPtr]::Zero)) -eq 11) { $evrCustom = $i; break }   # CB_GETITEMDATA
        }
        if ($evrCustom -lt 0) { throw 'no EVR Custom entry in the renderer combo' }
        [void][MouseRig]::SendMessage($vidCombo, 0x014E, [IntPtr]$evrCustom, [IntPtr]::Zero)   # CB_SETCURSEL
        $page = [MouseRig]::GetParent($vidCombo)
        [void][MouseRig]::PostMessage($page, 0x0111, [IntPtr]((1 -shl 16) -bor [int]$j.Ids.VidRndCombo), $vidCombo)   # WM_COMMAND, CBN_SELCHANGE
        Start-Sleep -Milliseconds 800
        $result.rendererSetToEvrCustom = ((Send-Int $vidCombo 0x0147 ([IntPtr]::Zero) ([IntPtr]::Zero)) -eq $evrCustom)   # CB_GETCURSEL

        $container = $root
        $modal = [IntPtr]::Zero
        $d3d9check = [MouseRig]::FindDescendant($root, [int]$j.Ids.D3D9Check)
        if ($d3d9check -ne [IntPtr]::Zero) {
            $result.layout = 'on-page'   # the old layout: the D3D9 selection sits on the Output page itself
        } else {
            $result.layout = 'popup'     # the current layout: the page's gear opens Video Renderer Settings
            $gear = [MouseRig]::FindChild($root, [int]$j.Ids.GearButton)
            if ($gear -eq [IntPtr]::Zero) { throw 'no D3D9 controls on the page and the settings button was not found' }
            # the gear is enabled from OnUpdateVideoRendererSettings, which runs at idle: wait for the
            # selection change to reach it before clicking
            $deadline = (Get-Date).AddSeconds(5)
            while (-not [MouseRig]::IsWindowEnabled($gear) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
            if (-not [MouseRig]::IsWindowEnabled($gear)) { throw 'the renderer settings button stayed disabled after switching to EVR Custom' }
            Click-Center $gear
            $deadline = (Get-Date).AddSeconds(15)
            while ($modal -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds 400
                $modal = [MouseRig]::FindTop([uint32]$script:proc.Id, '', $j.Ids.ModalTitle)
            }
            if ($modal -eq [IntPtr]::Zero) { throw "the '$($j.Ids.ModalTitle)' dialog never appeared" }
            $container = $modal
            $d3d9check = [MouseRig]::FindDescendant($modal, [int]$j.Ids.D3D9Check)
        }
        $d3d9combo = [MouseRig]::FindDescendant($container, [int]$j.Ids.D3D9Combo)
        if ($d3d9check -eq [IntPtr]::Zero -or $d3d9combo -eq [IntPtr]::Zero) { throw 'the D3D9 device controls were not found' }
        $result.d3d9Adapters = Send-Int $d3d9combo 0x0146 ([IntPtr]::Zero) ([IntPtr]::Zero)   # CB_GETCOUNT: one entry per adapter

        $result.atOpen = [ordered]@{
            checkVisible = [MouseRig]::IsWindowVisible($d3d9check)
            comboVisible = [MouseRig]::IsWindowVisible($d3d9combo)
            checkEnabled = [MouseRig]::IsWindowEnabled($d3d9check)
            comboEnabled = [MouseRig]::IsWindowEnabled($d3d9combo)
        }
        $result.atOpenShot = (Save-WindowShot 'at-open' $container).png

        # Reset is the page's own post-init EnableWindow on the combo; WM_ENABLE to both controls is
        # the same message any EnableWindow would deliver, and hits the themed OnEnable that used to
        # set WS_VISIBLE back on hidden controls.
        if ($result.layout -eq 'popup') {
            $reset = [MouseRig]::FindChild($container, [int]$j.Ids.ResetButton)
            if ($reset -ne [IntPtr]::Zero) { Click-Center $reset }
        }
        foreach ($h in @($d3d9check, $d3d9combo)) {
            [void][MouseRig]::SendMessage($h, 0x000A, [IntPtr]1, [IntPtr]::Zero)       # WM_ENABLE, TRUE
            [void][MouseRig]::SendMessage($h, 0x000A, [IntPtr]::Zero, [IntPtr]::Zero)  # WM_ENABLE, FALSE
        }
        Start-Sleep -Milliseconds 400
        $result.afterEnable = [ordered]@{
            checkVisible = [MouseRig]::IsWindowVisible($d3d9check)
            comboVisible = [MouseRig]::IsWindowVisible($d3d9combo)
        }
        $result.afterEnableShot = (Save-WindowShot 'after-enable' $container).png

        if ($modal -ne [IntPtr]::Zero) {
            Close-OptionsDialog $modal
            $script:modalClosed = ([MouseRig]::FindTop([uint32]$script:proc.Id, '', $j.Ids.ModalTitle) -eq [IntPtr]::Zero)
            $result.modalClosed = $script:modalClosed
        }
        Close-OptionsDialog $root
    }

    switch ($j.Case) {
        'd3d9'        { Invoke-D3D9Case }
        default       { throw "unknown case '$($j.Case)'" }
    }
} catch {
    $result.error = $_.Exception.Message + ' @ ' + $_.InvocationInfo.PositionMessage
} finally {
    if ($script:proc) {
        try {
            # Close any dialog the case left open, then the player. After a modal,
            # Process.MainWindowHandle can be stale: find the frame by class.
            $dlg = [MouseRig]::FindTop([uint32]$script:proc.Id, '', $j.DialogTitle)
            if ($dlg -ne [IntPtr]::Zero) {
                [void][MouseRig]::PostMessage($dlg, 0x0111, [IntPtr]2, [IntPtr]::Zero)   # WM_COMMAND, IDCANCEL
                Start-Sleep -Milliseconds 800
            }
            $main = [MouseRig]::FindTop([uint32]$script:proc.Id, 'MediaPlayerClassicW', '')
            if ($main -ne [IntPtr]::Zero) {
                [void][MouseRig]::PostMessage($main, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE
            }
            if (-not $script:proc.WaitForExit(15000)) {
                Stop-Process -Id $script:proc.Id -Force -ErrorAction SilentlyContinue
                $result.killedOnClose = $true
            } else {
                $result.exitCode = $script:proc.ExitCode
            }
        } catch {
            Stop-Process -Id $script:proc.Id -Force -ErrorAction SilentlyContinue
        }
    }
    $result.finished = (Get-Date).ToString('o')
    $result | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $outDir 'result.json')
}
