<#
.SYNOPSIS
    Installs the ZYNQ-FPGA-FORTH32 app for the current user and puts a ZYNQ-FORTH32 shortcut
    on the desktop.

.DESCRIPTION
    Takes ZynqForth32.exe from -Exe, else from dist\publish (a local release build), else
    downloads the release's app zip from GitHub. Copies it and the icon
    (app\tools\ZYNQ-FORTH32.ico) to -InstallDir and creates "ZYNQ-FORTH32" on the desktop:
    the app with --connect, starting in this repository's examples folder. Run it again after
    a new release to refresh the copy; the app's settings (%LocalAppData%\ZYNQ-FPGA-FORTH32)
    are kept.

.EXAMPLE
    .\tools\Install-App.ps1
    .\tools\Install-App.ps1 -Version 3.1 -InstallDir D:\Apps\ZYNQ-FPGA-FORTH32
#>
[CmdletBinding()]
param(
    [string]$Version = '3.1',
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'ZYNQ-FPGA-FORTH32\app'),
    [string]$Exe
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

if (-not $Exe) {
    $local = Join-Path $root 'dist\publish\ZynqForth32.exe'
    if (Test-Path $local) {
        $Exe = $local
    } else {
        $zip = Join-Path $env:TEMP "ZYNQ-FPGA-FORTH32-$Version-windows-x64.zip"
        $url = "https://github.com/andiepp/ZYNQ-FPGA-FORTH32/releases/download/v$Version/ZYNQ-FPGA-FORTH32-$Version-windows-x64.zip"
        Write-Host "INSTALL: downloading $url"
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
        $unpacked = Join-Path $env:TEMP "ZYNQ-FPGA-FORTH32-$Version"
        if (Test-Path $unpacked) { Remove-Item -Recurse -Force $unpacked }
        Expand-Archive -Path $zip -DestinationPath $unpacked
        $Exe = Join-Path $unpacked 'ZynqForth32.exe'
    }
}
if (-not (Test-Path $Exe)) { throw "missing $Exe" }

if (Get-Process ZynqForth32 -ErrorAction SilentlyContinue) {
    throw 'the app is running: close it first'
}
New-Item -ItemType Directory -Force $InstallDir | Out-Null
$target = Join-Path $InstallDir 'ZynqForth32.exe'
if ((Resolve-Path $Exe).Path -ne [IO.Path]::GetFullPath($target)) {
    Copy-Item $Exe $target -Force
}
Copy-Item (Join-Path $root 'app\tools\ZYNQ-FORTH32.ico') $InstallDir -Force

$link = Join-Path ([Environment]::GetFolderPath('Desktop')) 'ZYNQ-FORTH32.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($link)
$shortcut.TargetPath = $target
$shortcut.Arguments = '--connect'
$shortcut.WorkingDirectory = Join-Path $root 'examples'
$shortcut.IconLocation = (Join-Path $InstallDir 'ZYNQ-FORTH32.ico') + ',0'
$shortcut.Description = 'ZYNQ-FPGA-FORTH32: 32-bit Forth with floating point on the Arty Z7-20'
$shortcut.Save()

Write-Host ("INSTALL: {0} version {1}" -f $target, (Get-Item $target).VersionInfo.FileVersion)
Write-Host "INSTALL: shortcut $link"
