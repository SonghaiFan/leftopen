# Builds the Windows application icon (multi-size .ico) from the original repo artwork.
# Usage: powershell -File windows\Scripts\make-icon.ps1
param(
    [string]$Source = "assets\leftopen-iOS-Default-1024@1x.png",
    [string]$Output = "windows\src\LeftOpen.Tray\Assets\leftopen.ico"
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

# The icon builder runs as inline C# to sidestep PowerShell 5.1 overload-resolution quirks.
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @"
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;

public static class IcoBuilder
{
    public static void Build(string sourcePath, string outputPath, int[] sizes)
    {
        using (Image source = Image.FromFile(sourcePath))
        {
            byte[][] payloads = new byte[sizes.Length][];
            for (int i = 0; i < sizes.Length; i++)
            {
                using (Bitmap bmp = new Bitmap(sizes[i], sizes[i]))
                using (Graphics g = Graphics.FromImage(bmp))
                {
                    g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                    g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    g.DrawImage(source, 0, 0, sizes[i], sizes[i]);
                    using (MemoryStream ms = new MemoryStream())
                    {
                        bmp.Save(ms, ImageFormat.Png);
                        payloads[i] = ms.ToArray();
                    }
                }
            }

            // ICONDIR + ICONDIRENTRY[] + PNG payloads (PNG-in-ICO is supported since Vista).
            using (FileStream fs = File.Create(outputPath))
            using (BinaryWriter bw = new BinaryWriter(fs))
            {
                bw.Write((ushort)0);
                bw.Write((ushort)1);
                bw.Write((ushort)sizes.Length);

                int offset = 6 + 16 * sizes.Length;
                for (int i = 0; i < sizes.Length; i++)
                {
                    byte dimension = sizes[i] >= 256 ? (byte)0 : (byte)sizes[i];
                    bw.Write(dimension);
                    bw.Write(dimension);
                    bw.Write((byte)0);
                    bw.Write((byte)0);
                    bw.Write((ushort)1);
                    bw.Write((ushort)32);
                    bw.Write((uint)payloads[i].Length);
                    bw.Write((uint)offset);
                    offset += payloads[i].Length;
                }

                foreach (byte[] payload in payloads)
                {
                    bw.Write(payload);
                }
            }
        }
    }
}
"@

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$sourcePath = Join-Path $repoRoot $Source
if (!(Test-Path $sourcePath)) { throw "Icon source not found: $sourcePath" }

$outputPath = Join-Path $repoRoot $Output
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outputPath) | Out-Null

$sizes = @(16, 20, 24, 32, 40, 48, 64, 128, 256)
[IcoBuilder]::Build($sourcePath, $outputPath, $sizes)

Write-Host "Wrote $Output ($((Get-Item $outputPath).Length) bytes, sizes: $($sizes -join ', '))" -ForegroundColor Green
