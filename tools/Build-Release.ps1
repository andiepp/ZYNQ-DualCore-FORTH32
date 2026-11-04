<#
.SYNOPSIS
    Builds a ZYNQ-FPGA-FORTH32 release: the Windows app, the board's boot image and the
    documentation, zipped for a GitHub release.

.DESCRIPTION
    Expects the boot image to be built already (hw/build_hw.tcl, sw/build_sw.tcl,
    sw/build_boot.ps1: build\boot\BOOT.bin and the FSBL).
    1. Runs the app's tests and publishes the app as one self-contained ZynqForth32.exe for
       Windows x64 (no .NET installation needed).
    2. Builds the manual's and the design document's PDFs (needs Python with 'markdown' and
       Microsoft Edge; skipped with -SkipPdf, then the committed docs\Manual.pdf and
       docs\Implementation-Details.pdf are used).
    3. Writes to dist\:
         ZYNQ-FPGA-FORTH32-<version>-windows-x64.zip   app, firmware, flash script, documents, examples
         ZYNQ-FPGA-FORTH32-firmware-<version>.zip      BOOT.bin, fsbl.elf and the flash script

.EXAMPLE
    .\tools\Build-Release.ps1
#>
[CmdletBinding()]
param(
    [string]$Version = '1.0',
    [switch]$SkipTests,
    [switch]$SkipPdf
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$dist = Join-Path $root 'dist'
$stage = Join-Path $dist "ZYNQ-FPGA-FORTH32-$Version"
$firmware = Join-Path $stage 'firmware'

$boot = Join-Path $root 'build\boot\BOOT.bin'
$fsbl = Join-Path $root 'build\sw\forth_pf\zynq_fsbl\fsbl.elf'
foreach ($f in $boot, $fsbl) {
    if (-not (Test-Path $f)) { throw "missing ${f}: build hw, sw and the boot image first (README)" }
}

if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force $firmware | Out-Null

$solution = Join-Path $root 'app\ZynqForth.slnx'
if (-not $SkipTests) {
    dotnet test $solution -c Release
    if ($LASTEXITCODE) { throw 'tests failed' }
}
dotnet publish (Join-Path $root 'app\src\ZynqForth\ZynqForth.csproj') -c Release -r win-x64 --self-contained `
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:Version="$Version.0" -o (Join-Path $dist 'publish')
if ($LASTEXITCODE) { throw 'publish failed' }
Copy-Item (Join-Path $dist 'publish\ZynqForth32.exe') $stage

if (-not $SkipPdf) {
    python (Join-Path $root 'tools\manual_pdf.py')
    if ($LASTEXITCODE) { throw 'manual PDF failed' }
    python (Join-Path $root 'tools\manual_pdf.py') design
    if ($LASTEXITCODE) { throw 'design PDF failed' }
}

Copy-Item $boot, $fsbl, (Join-Path $root 'sw\program_flash.ps1') $firmware
Copy-Item (Join-Path $root 'docs\Manual.pdf'), (Join-Path $root 'docs\Implementation-Details.pdf'), (Join-Path $root 'docs\Protocol.md'), (Join-Path $root 'README.md'),
          (Join-Path $root 'CHANGELOG.md'), (Join-Path $root 'LICENSE') $stage
Copy-Item -Recurse (Join-Path $root 'examples') $stage
Copy-Item (Join-Path $root 'tools\zforth.py') $stage

$appZip = Join-Path $dist "ZYNQ-FPGA-FORTH32-$Version-windows-x64.zip"
$fwZip = Join-Path $dist "ZYNQ-FPGA-FORTH32-firmware-$Version.zip"
Remove-Item -Force $appZip, $fwZip -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $appZip
Compress-Archive -Path (Join-Path $firmware '*') -DestinationPath $fwZip
foreach ($z in $appZip, $fwZip) {
    Write-Host ("RELEASE: {0} ({1:N0} bytes)" -f $z, (Get-Item $z).Length)
}
