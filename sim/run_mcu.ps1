# Check the multi-cycle unit (rtl/hf32_mcu.v: multiply and floating point) in the Vivado
# simulator against vectors from the bit-exact model in tools/hf32.py.
# Usage (from the repository root): .\sim\run_mcu.ps1 [-Count 4000]
param(
    [int]$Count = 4000,
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
$out = Join-Path $root 'build\sim_mcu'
New-Item -ItemType Directory -Force $out | Out-Null

# the model checks itself against IEEE first, then writes the vectors
python (Join-Path $root 'tools\test_fpu.py') -n ([Math]::Max($Count, 20000)) --vector-count $Count --vectors (Join-Path $out 'mcu_vectors.txt')
if ($LASTEXITCODE) { exit $LASTEXITCODE }

Push-Location $out
try {
    & "$Vivado\xvlog.bat" -nolog (Join-Path $root 'rtl\hf32_mcu.v') (Join-Path $root 'sim\tb_mcu.v') | Select-String 'ERROR|WARNING'
    & "$Vivado\xelab.bat" -nolog -debug off -timescale 1ns/1ps tb_mcu -s mcu_snap | Select-String 'ERROR'
    & "$Vivado\xsim.bat" mcu_snap -nolog -R |
        Where-Object { $_ -notmatch '^(INFO|\*\*\*\*|Vivado Simulator|Time resolution|  \*\*|source |# |ECHO)' }
}
finally {
    Pop-Location
}
