# Runs both cores in the RTL testbench at once (core 0 with one input, core 1 with another)
# and compares each core's output with the instruction-set simulator's two-core run.
# The inputs must not depend on timing between the cores (wait for mail, use locks).
# Usage (from the repository root): .\sim\run_dual.ps1 [-Input0 dual0] [-Input1 dual1]
param(
    [string]$Input0 = 'dual0',
    [string]$Input1 = 'dual1',
    [string]$Vivado
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root 'build\regress'
New-Item -ItemType Directory -Force $out | Out-Null

function Lines([string]$path) {
    Get-Content $path | ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and $_ -notmatch '^(\[|\*\*|run|exit|\$finish|HF32)' }
}

$iss0 = Join-Path $out "$Input0.core0.iss.txt"
$iss1 = Join-Path $out "$Input1.core1.iss.txt"
$rtl0 = Join-Path $out "$Input0.core0.rtl.txt"
$rtl1 = Join-Path $out "$Input1.core1.rtl.txt"
$kernel = Join-Path $root 'forth\kernel.fs'
# one simulator run with both cores (shared mailboxes, locks and shared RAM)
python (Join-Path $root 'tools\hf32.py') run $kernel -f (Join-Path $root "sim\$Input0.txt") `
    --input-file1 (Join-Path $root "sim\$Input1.txt") --out1 $iss1 2>&1 | Out-File -Encoding ascii $iss0

$arguments = @{ InputFile = "sim\$Input0.txt"; InputFile1 = "sim\$Input1.txt" }
if ($Vivado) { $arguments.Vivado = $Vivado }
& (Join-Path $PSScriptRoot 'run_sim.ps1') @arguments 2>&1 | Out-File -Encoding ascii $rtl0
Copy-Item (Join-Path $root 'build\sim\core1.txt') $rtl1
Get-Content $rtl0 | Where-Object { $_ -match '^\[tb\]' }

$failed = 0
foreach ($pair in @(@(0, $iss0, $rtl0), @(1, $iss1, $rtl1))) {
    $a = @(Lines $pair[1])
    $b = @(Lines $pair[2])
    $diff = Compare-Object $a $b -SyncWindow 0
    if ($diff) {
        $failed++
        "[dual] core $($pair[0]) : $(@($diff).Count) differing lines (ISS $($a.Count), RTL $($b.Count))"
        $diff | Select-Object -First 6 | ForEach-Object { "    $($_.SideIndicator) $($_.InputObject)" }
    } else {
        "[dual] core $($pair[0]) : $($a.Count) lines, RTL = ISS"
    }
}
exit $failed
