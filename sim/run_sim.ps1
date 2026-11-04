# Compile the kernel and run the RTL testbench in the Vivado simulator (xsim).
# Usage (from the repository root): .\sim\run_sim.ps1 [-InputFile sim\smoke.txt]
param(
    [string]$InputFile = 'sim\smoke.txt',
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
$out = Join-Path $root 'build\sim'
New-Item -ItemType Directory -Force $out | Out-Null

python (Join-Path $root 'tools\hf32.py') build (Join-Path $root 'forth\kernel.fs') -o (Join-Path $root 'build\forth')
if ($LASTEXITCODE) { exit $LASTEXITCODE }

# The testbench's default file names; the Xilinx .bat launchers mangle '=' in -testplusarg
Copy-Item (Join-Path $root 'build\forth.hex') (Join-Path $out 'forth.hex')
Copy-Item (Join-Path $root $InputFile) (Join-Path $out 'input.txt')
Copy-Item (Join-Path $root 'sim\xadc_stim.txt') (Join-Path $out 'xadc_stim.txt')
# the address of LATEST for the testbench's dictionary walk
$latest = (Select-String -Path (Join-Path $root 'build\forth_image.h') -Pattern 'FORTH_LATEST_ADDR 0x(\w+)').Matches[0].Groups[1].Value
Set-Content -Encoding ascii (Join-Path $out 'latest.hex') $latest
$rtl = Get-ChildItem (Join-Path $root 'rtl') -Filter *.v | ForEach-Object FullName
$glbl = Join-Path (Split-Path $Vivado -Parent) 'data\verilog\src\glbl.v'   # for the XADC model

Push-Location $out
try {
    Remove-Item -Recurse -Force xsim.dir -ErrorAction SilentlyContinue    # no stale snapshot
    & "$Vivado\xvlog.bat" -nolog $rtl (Join-Path $root 'sim\tb_forth.v') $glbl | Select-String 'ERROR|WARNING'
    & "$Vivado\xelab.bat" -nolog -debug off -timescale 1ns/1ps -L unisims_ver tb glbl -s tb_snap | Select-String 'ERROR'
    & "$Vivado\xsim.bat" tb_snap -nolog -R |
        Where-Object { $_ -notmatch '^(INFO|\*\*\*\*|Vivado Simulator|Time resolution|  \*\*|source |# |ECHO)' }
}
finally {
    Pop-Location
}
