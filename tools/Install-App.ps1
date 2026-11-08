<#
.SYNOPSIS
    Installs the ZYNQ-DualCore-FORTH32 app for the current user and puts a
    ZYNQ-DualCore-FORTH32 shortcut on the desktop.

.DESCRIPTION
    Takes ZynqDualForth32.exe from -Exe, else from dist\publish (a local release build), else
    downloads the release's app zip from GitHub. Copies it and the icon
    (app\tools\ZYNQ-DUAL-FORTH32.ico) to -InstallDir and creates "ZYNQ-DualCore-FORTH32" on
    the desktop: the app with --connect, starting in this repository's examples folder. Run it
    again after a new release to refresh the copy; the app's settings
    (%LocalAppData%\ZYNQ-DualCore-FORTH32) are kept. The single-core app's installation and
    shortcut (ZYNQ-FORTH32) are not touched.

.EXAMPLE
    .\tools\Install-App.ps1
    .\tools\Install-App.ps1 -Version 4.2.1 -InstallDir D:\Apps\ZYNQ-DualCore-FORTH32
#>
[CmdletBinding()]
param(
    [string]$Version = '4.2.1',
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'ZYNQ-DualCore-FORTH32\app'),
    [string]$Exe
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

if (-not $Exe) {
    $local = Join-Path $root 'dist\publish\ZynqDualForth32.exe'
    if (Test-Path $local) {
        $Exe = $local
    } else {
        $zip = Join-Path $env:TEMP "ZYNQ-DualCore-FORTH32-$Version-windows-x64.zip"
        $url = "https://github.com/andiepp/ZYNQ-DualCore-FORTH32/releases/download/v$Version/ZYNQ-DualCore-FORTH32-$Version-windows-x64.zip"
        Write-Host "INSTALL: downloading $url"
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
        $unpacked = Join-Path $env:TEMP "ZYNQ-DualCore-FORTH32-$Version"
        if (Test-Path $unpacked) { Remove-Item -Recurse -Force $unpacked }
        Expand-Archive -Path $zip -DestinationPath $unpacked
        $Exe = Join-Path $unpacked 'ZynqDualForth32.exe'
    }
}
if (-not (Test-Path $Exe)) { throw "missing $Exe" }

if (Get-Process ZynqDualForth32 -ErrorAction SilentlyContinue) {
    throw 'the app is running: close it first'
}
New-Item -ItemType Directory -Force $InstallDir | Out-Null
$target = Join-Path $InstallDir 'ZynqDualForth32.exe'
if ((Resolve-Path $Exe).Path -ne [IO.Path]::GetFullPath($target)) {
    Copy-Item $Exe $target -Force
}
Copy-Item (Join-Path $root 'app\tools\ZYNQ-DUAL-FORTH32.ico') $InstallDir -Force

$link = Join-Path ([Environment]::GetFolderPath('Desktop')) 'ZYNQ-DualCore-FORTH32.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($link)
$shortcut.TargetPath = $target
$shortcut.Arguments = '--connect'
$shortcut.WorkingDirectory = Join-Path $root 'examples'
$shortcut.IconLocation = (Join-Path $InstallDir 'ZYNQ-DUAL-FORTH32.ico') + ',0'
$shortcut.Description = 'ZYNQ-DualCore-FORTH32: two 32-bit Forth cores with floating point on the Arty Z7-20'
$shortcut.Save()

Write-Host ("INSTALL: {0} version {1}" -f $target, (Get-Item $target).VersionInfo.FileVersion)
Write-Host "INSTALL: shortcut $link"
