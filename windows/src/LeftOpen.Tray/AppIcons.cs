using System.Diagnostics;

namespace LeftOpen.Tray;

/// <summary>
/// Per-row icon resolution, mirroring leftopen's chain: the target executable's own
/// icon (installed apps) → the project's favicon.ico → a generic door glyph.
/// </summary>
internal static class AppIcons
{
    public static Image Resolve(string? executablePath, string? projectRoot, int size)
    {
        try
        {
            if (!string.IsNullOrEmpty(executablePath) && File.Exists(executablePath))
            {
                using var icon = Icon.ExtractAssociatedIcon(executablePath);
                if (icon != null)
                {
                    return new Bitmap(icon.ToBitmap(), size, size);
                }
            }
        }
        catch
        {
            // Fall through to the project favicon.
        }

        try
        {
            if (!string.IsNullOrEmpty(projectRoot))
            {
                var favicon = Path.Combine(projectRoot, "favicon.ico");
                if (File.Exists(favicon))
                {
                    using var icon = new Icon(favicon, size, size);
                    return new Bitmap(icon.ToBitmap(), size, size);
                }
            }
        }
        catch
        {
            // Fall through to the fallback glyph.
        }

        return FallbackGlyph(size);
    }

    private static Image FallbackGlyph(int size)
    {
        var bitmap = new Bitmap(size, size);
        using var g = Graphics.FromImage(bitmap);
        g.Clear(Color.Transparent);
        using var brush = new SolidBrush(Color.FromArgb(90, 90, 96));
        using var font = new Font("Segoe UI", size * 0.55f, FontStyle.Bold, GraphicsUnit.Pixel);
        var text = "?";
        var measured = g.MeasureString(text, font);
        g.DrawString(text, font, brush, (size - measured.Width) / 2, (size - measured.Height) / 2);
        return bitmap;
    }
}
