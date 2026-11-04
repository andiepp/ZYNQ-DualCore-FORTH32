# Captures the ZYNQ-DualCore-FORTH32 main window into a PNG (the window must be visible on screen).
# Usage: .\app\tools\Capture-Window.ps1 -Out docs\images\ide-dark.png [-ProcessName ZynqDualForth32]
param(
    [Parameter(Mandatory)][string]$Out,
    [string]$ProcessName = 'ZynqDualForth32'
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class Win {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int size);
}
'@
[Win]::SetProcessDPIAware() | Out-Null
$process = Get-Process $ProcessName | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $process) { throw "no $ProcessName window" }
$handle = $process.MainWindowHandle
[Win]::SetForegroundWindow($handle) | Out-Null
Start-Sleep -Milliseconds 400
$rect = New-Object Win+RECT
# DWMWA_EXTENDED_FRAME_BOUNDS = 9: the visible frame without the invisible resize border
[Win]::DwmGetWindowAttribute($handle, 9, [ref]$rect, [Runtime.InteropServices.Marshal]::SizeOf($rect)) | Out-Null
$width = $rect.Right - $rect.Left
$height = $rect.Bottom - $rect.Top
$bitmap = New-Object System.Drawing.Bitmap $width, $height
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bitmap.Size)
$full = [IO.Path]::GetFullPath($Out)
New-Item -ItemType Directory -Force (Split-Path $full) | Out-Null
$bitmap.Save($full, [System.Drawing.Imaging.ImageFormat]::Png)
$graphics.Dispose(); $bitmap.Dispose()
Write-Host "CAPTURE: $full ($width x $height)"
