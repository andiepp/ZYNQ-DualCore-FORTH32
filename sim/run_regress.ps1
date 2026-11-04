# Runs every sim\*.txt input (or the ones given) through the instruction-set simulator and the
# RTL testbench and compares Forth's output line by line (RTL = ISS).
# Usage (from the repository root): .\sim\run_regress.ps1 [-Inputs smoke,divide]
param(
    # not board31.txt: it is the 3.1 board script for jumpers that connect both ways; the
    # testbench's loopback connects one way only (periph.txt's pins), so its UART test would
    # wait forever in the RTL
    [string[]]$Inputs = @('smoke', 'divide', 'float', 'manual_checks', 'periph', 'shield', 'pwm', 'manual_examples'),
    [string]$Vivado
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root 'build\regress'
New-Item -ItemType Directory -Force $out | Out-Null
$failed = 0

# the transcript lines: Forth's echo and answers, without simulator chatter
function Lines([string]$path) {
    Get-Content $path | ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and $_ -notmatch '^(\[|\*\*|run|exit|\$finish|HF32)' }
}

foreach ($name in $Inputs) {
    $input = Join-Path $root "sim\$name.txt"
    $iss = Join-Path $out "$name.iss.txt"
    $rtl = Join-Path $out "$name.rtl.txt"
    python (Join-Path $root 'tools\hf32.py') run (Join-Path $root 'forth\kernel.fs') -f $input 2>&1 | Out-File -Encoding ascii $iss
    $arguments = @{ InputFile = "sim\$name.txt" }
    if ($Vivado) { $arguments.Vivado = $Vivado }
    & (Join-Path $PSScriptRoot 'run_sim.ps1') @arguments 2>&1 | Out-File -Encoding ascii $rtl
    $a = @(Lines $iss)
    $b = @(Lines $rtl)
    $diff = Compare-Object $a $b -SyncWindow 0
    if ($diff) {
        $failed++
        "[regress] $name : $(@($diff).Count) differing lines (ISS $($a.Count), RTL $($b.Count))"
        $diff | Select-Object -First 6 | ForEach-Object { "    $($_.SideIndicator) $($_.InputObject)" }
    } else {
        "[regress] $name : $($a.Count) lines, RTL = ISS"
    }
}
"[regress] $($Inputs.Count) inputs, $failed differ"
exit $failed
