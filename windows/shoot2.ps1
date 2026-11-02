param([string]$Tab = "persona", [string]$Out = "shot.png")
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class WAPI {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, UIntPtr i);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L; public int T; public int R; public int B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
}
"@
$proc = Get-Process | Where-Object { $_.MainWindowTitle -eq 'ZCode 破甲弹' } | Select-Object -First 1
if (-not $proc) { Write-Output 'window not found'; exit 1 }
$h = $proc.MainWindowHandle
[WAPI]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 400
$idx = @{ "deploy" = 0; "persona" = 1; "dir" = 2; "log" = 3 }[$Tab]
$pt = New-Object WAPI+POINT
$pt.X = 12 + 6 + 118 * $idx + 59
$pt.Y = 10 + 42 + 21
[WAPI]::ClientToScreen($h, [ref]$pt) | Out-Null
[WAPI]::SetCursorPos($pt.X, $pt.Y) | Out-Null
Start-Sleep -Milliseconds 150
[WAPI]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 60
[WAPI]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 800
$r = New-Object WAPI+RECT
[WAPI]::GetWindowRect($h, [ref]$r) | Out-Null
$bmp = New-Object System.Drawing.Bitmap(($r.R - $r.L), ($r.B - $r.T))
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.L, $r.T, 0, 0, $bmp.Size)
$bmp.Save($Out)
$g.Dispose(); $bmp.Dispose()
Write-Output ("saved " + $Tab + " -> " + $Out)
