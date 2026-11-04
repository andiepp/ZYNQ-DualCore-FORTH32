# Build the QSPI boot image: FSBL + bitstream + ARM program (with the kernel image).
# Usage (from the repository root, after hw/build_hw.tcl and sw/build_sw.tcl): .\sw\build_boot.ps1
# Output: build\boot\BOOT.bin, written to flash by sw\program_flash.ps1
param(
    [string]$Vitis
)
$ErrorActionPreference = 'Stop'
# Vitis 2023.2's bin folder: -Vitis, else $env:XILINX_VITIS, else \Xilinx\Vitis\2023.2 on any drive
if (-not $Vitis) {
    $Vitis = @($env:XILINX_VITIS) + (Get-PSDrive -PSProvider FileSystem | ForEach-Object { Join-Path $_.Root 'Xilinx\Vitis\2023.2' }) |
        Where-Object { $_ -and (Test-Path (Join-Path $_ 'bin\bootgen.bat')) } | ForEach-Object { Join-Path $_ 'bin' } | Select-Object -First 1
    if (-not $Vitis) { throw 'Vitis 2023.2 not found: pass -Vitis <Vitis folder>\bin' }
}
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root 'build\boot'

# build_sw.tcl's platform generate builds the FSBL beside the app
$fsbl = Join-Path $root 'build\sw\forth_pf\zynq_fsbl\fsbl.elf'
$bit = Join-Path $root 'build\hw\forth.bit'
$elf = Join-Path $root 'build\sw\forth_app\Debug\forth_app.elf'
foreach ($f in $fsbl, $bit, $elf) {
    if (-not (Test-Path $f)) { throw "missing $f, build hw and sw first" }
}

New-Item -ItemType Directory -Force $out | Out-Null
$bif = Join-Path $out 'boot.bif'
$image = Join-Path $out 'BOOT.bin'
@"
the_ROM_image:
{
    [bootloader] $($fsbl -replace '\\', '/')
    $($bit -replace '\\', '/')
    $($elf -replace '\\', '/')
}
"@ | Set-Content -Encoding ascii $bif

& "$Vitis\bootgen.bat" -arch zynq -image $bif -o $image -w on
if ($LASTEXITCODE) { exit $LASTEXITCODE }
if (-not (Test-Path $image)) { throw 'bootgen produced no BOOT.bin' }
Write-Host "BOOT: wrote $image ($((Get-Item $image).Length) bytes)"
