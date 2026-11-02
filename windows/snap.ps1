param([string]$Tab = "deploy", [string]$Out = "shot.png")
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @"
using System;using System.Runtime.InteropServices;
public class W3 { [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h); [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r); [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L; public int T; public int R; public int B; } }
"@
$arg = "--tab=" + $Tab
$p = Start-Process -FilePath 'F:\TZcode\armor-piercer\zcode破甲弹.exe' -ArgumentList $arg -Verb RunAs -PassThru
Start-Sleep -Seconds 4
$proc = Get-Process | Where-Object { $_.Id -eq $p.Id } | Select-Object -First 1
if (-not $proc) { Write-Output 'process died'; exit 1 }
$h = $proc.MainWindowHandle
[W3]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 500
$r = New-Object W3+RECT
[W3]::GetWindowRect($h, [ref]$r) | Out-Null
$bmp = New-Object System.Drawing.Bitmap(($r.R - $r.L), ($r.B - $r.T))
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.L, $r.T, 0, 0, $bmp.Size)
$bmp.Save($Out)
$g.Dispose(); $bmp.Dispose()
Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
Write-Output ("saved " + $Tab + " -> " + $Out)
