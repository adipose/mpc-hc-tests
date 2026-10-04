<#
.SYNOPSIS
    Builds combocase.exe, the suite's control program, into bin\ beside this script.

.DESCRIPTION
    One source file, no dependencies, static CRT. The manifest is embedded on purpose: without it the program
    gets the old user32 combo box rather than the comctl32 v6 one the player uses, and the control then
    measures a different control. A copy of the exe alone, without an embedded manifest, did exactly that once.

    Returns the path of the exe, or $null when no Visual Studio with the C++ toolset is installed.
#>
[CmdletBinding()]
param([switch] $Force)

$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'combocase.cpp'
$bin = Join-Path $PSScriptRoot 'bin'
$exe = Join-Path $bin 'combocase.exe'
if (-not $Force -and (Test-Path $exe) -and (Get-Item $exe).LastWriteTime -ge (Get-Item $source).LastWriteTime) { return $exe }

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) { return $null }
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { return $null }
$vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path $vcvars)) { return $null }

New-Item -ItemType Directory -Force $bin | Out-Null
$output = & cmd /c "`"$vcvars`" >nul 2>&1 && cl /nologo /W3 /EHsc /O1 /std:c++17 `"$source`" /Fo`"$bin\\`" /Fe`"$exe`" user32.lib gdi32.lib comctl32.lib /link /SUBSYSTEM:WINDOWS /MANIFEST:EMBED" 2>&1
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $exe)) { throw "combocase did not build: $($output -join ' | ')" }
$exe
