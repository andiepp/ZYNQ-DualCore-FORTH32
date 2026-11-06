# Write BOOT.bin to the Arty Z7's 16 MB QSPI flash over JTAG and verify it.
# Usage (from the repository root): .\sw\program_flash.ps1
#        (from a release's firmware folder): .\program_flash.ps1 -Vitis <Vitis or Vivado Lab bin folder>
# Set JP4 to JTAG while programming, then to QSPI and power-cycle to boot from flash.
param(
    [string]$Vitis,
    [string]$Image,
    [string]$Fsbl
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

# a release ships BOOT.bin and fsbl.elf beside this script; the repository has them in build\
if (-not $Image) {
    $Image = if (Test-Path (Join-Path $PSScriptRoot 'BOOT.bin')) { Join-Path $PSScriptRoot 'BOOT.bin' }
             else { Join-Path $root 'build\boot\BOOT.bin' }
}
if (-not $Fsbl) {
    $Fsbl = if (Test-Path (Join-Path $PSScriptRoot 'fsbl.elf')) { Join-Path $PSScriptRoot 'fsbl.elf' }
            else { Join-Path $root 'build\sw\forth_pf\zynq_fsbl\fsbl.elf' }
}
foreach ($f in $Image, $Fsbl) {
    if (-not (Test-Path $f)) { throw "missing $f, run sw\build_boot.ps1 first" }
}
# Vitis 2023.2's bin folder: -Vitis, else $env:XILINX_VITIS, else \Xilinx\Vitis\2023.2 on any drive (or pass Vivado Lab's bin folder)
if (-not $Vitis) {
    $Vitis = @($env:XILINX_VITIS) + (Get-PSDrive -PSProvider FileSystem | ForEach-Object { Join-Path $_.Root 'Xilinx\Vitis\2023.2' }) |
        Where-Object { $_ -and (Test-Path (Join-Path $_ 'bin\program_flash.bat')) } | ForEach-Object { Join-Path $_ 'bin' } | Select-Object -First 1
    if (-not $Vitis) { throw 'Vitis 2023.2 not found: pass -Vitis <Vitis folder>\bin' }
}
$tool = Join-Path $Vitis 'program_flash.bat'
if (-not (Test-Path $tool)) { throw "missing $tool, pass -Vitis <folder with program_flash.bat>" }

# S25FL128S, one chip in quad mode; the image starts at 0, the saved Forth sources sit at 0xFE0000 (core 0) and 0xFD0000 (core 1)
# program_flash exits 0 even when it fails, so its output is checked as well. It prints
# thousands of lines; the script shows the phases and their percentages as they come and keeps
# the whole output in a log file.
$log = Join-Path $env:TEMP 'program_flash.log'
Write-Host ("FLASH: writing {0} ({1:N1} MB) to the QSPI flash and verifying it." -f `
    (Split-Path $Image -Leaf), ((Get-Item $Image).Length / 1MB))
Write-Host 'FLASH: this takes about 2 to 3 minutes; keep the board on and JP4 on JTAG until it is done.'
$started = Get-Date
$phase = 'start'
$shown = ''
$lines = New-Object System.Collections.Generic.List[string]
# a line on stderr is output like any other, not a stop: the output decides below
$ErrorActionPreference = 'Continue'
& $tool -f $Image -offset 0 -flash_type qspi-x4-single -fsbl $Fsbl -verify 2>&1 | ForEach-Object {
    $line = "$_"
    $lines.Add($line)
    $step = $null
    if ($line -match 'Retrieving Flash info') { $step = 'connecting to the board' }
    elseif ($line -match 'Performing (\w+) Operation') { $phase = $Matches[1].ToLower(); $step = "$phase 0%" }
    elseif ($line -match '(\w+) Operation successful') { $step = "$($Matches[1].ToLower()) done" }
    elseif ($line -match '^ERROR|Operation Failed') { $step = $line }
    elseif ($line -match '(?:^|\s|>)(\d{1,3})%') { $step = "$phase $($Matches[1])%" }
    if ($step -and $step -ne $shown) {
        $shown = $step
        Write-Host ("  {0,4:N0} s  {1}" -f ((Get-Date) - $started).TotalSeconds, $step)
    }
}
$exit = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
$lines | Set-Content -Encoding UTF8 $log
if ($exit -or ($lines -match '^ERROR|Operation Failed')) {
    $lines | Where-Object { $_ -notmatch '^ECHO ' } | Select-Object -Last 30 | Write-Host
    throw "program_flash failed (is JP4 on JTAG?); the whole output is in $log"
}
Write-Host ("FLASH: BOOT.bin written and verified in {0:N0} s; set JP4 to QSPI and power-cycle the board" -f `
    ((Get-Date) - $started).TotalSeconds)
