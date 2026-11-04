# Run the unit testbench of the serial interfaces, DDS and tone generator (sim/tb_periph.v)
# in the Vivado simulator.
# Usage (from the repository root): .\sim\run_periph.ps1
param(
    [string]$Vivado
)
$ErrorActionPreference = 'Stop'
# Vivado 2023.2's bin folder: -Vivado, else $env:XILINX_VIVADO, else \Xilinx\Vivado\2023.2 on any drive
if (-not $Vivado) {
    $Vivado = @($env:XILINX_VIVADO) + (Get-PSDrive -PSProvider FileSystem | ForEach-Object { Join-Path $_.Root 'Xilinx\Vivado\2023.2' }) |
        Where-Object { $_ -and (Test-Path (Join-Path $_ 'bin\xvlog.bat')) } | ForEach-Object { Join-Path $_ 'bin' } | Select-Object -First 1
    if (-not $Vivado) { throw 'Vivado 2023.2 not found: pass -Vivado <Vivado folder>\bin' }
}
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root 'build\sim_periph'
New-Item -ItemType Directory -Force $out | Out-Null
$rtl = 'fifo.v', 'uart.v', 'spi.v', 'i2c.v', 'dds.v', 'tone.v' | ForEach-Object { Join-Path $root "rtl\$_" }

Push-Location $out
try {
    & "$Vivado\xvlog.bat" -nolog $rtl (Join-Path $root 'sim\tb_periph.v') | Select-String 'ERROR|WARNING'
    & "$Vivado\xelab.bat" -nolog -debug off -timescale 1ns/1ps tb_periph -s periph_snap | Select-String 'ERROR'
    & "$Vivado\xsim.bat" periph_snap -nolog -R |
        Where-Object { $_ -notmatch '^(INFO|\*\*\*\*|Vivado Simulator|Time resolution|  \*\*|source |# |ECHO)' }
}
finally {
    Pop-Location
}
