using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace LeftOpen.Tray;

/// <summary>
/// The original LeftOpen door mark, ported from the Swift DoorMark in MenuPanel.swift
/// (33 × 55 view box). Open = the leaf has swung out, leaving the dark interior
/// visible; closed = the leaf sits flush, so only the frame ring and knob show.
/// The frame colour adapts to the taskbar theme, and the leaf is left transparent so
/// the taskbar (or panel) shows through it, exactly like the original's
/// windowBackgroundColor leaf.
/// </summary>
internal static class DoorMark
{
    private const float ViewWidth = 33f;
    private const float ViewHeight = 55f;
    private const float KnobRadius = 1.644f;
    private const float KnobY = 29.134f;

    public static Image Render(int size, bool open, Color frame)
    {
        var bitmap = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(bitmap);
        g.Clear(Color.Transparent);
        Paint(g, new RectangleF(0, 0, size, size), open, frame);
        return bitmap;
    }

    public static Icon RenderIcon(int size, bool open, Color frame)
    {
        using var bitmap = (Bitmap)Render(size, open, frame);
        var handle = bitmap.GetHicon();
        try
        {
            using var borrowed = Icon.FromHandle(handle);
            return (Icon)borrowed.Clone();
        }
        finally
        {
            DestroyIcon(handle);
        }
    }

    /// <summary>Tray icon states, mirroring the original's MenuBarExtra label.</summary>
    public enum TrayState
    {
        /// <summary>Nothing closable: just the closed door.</summary>
        Closed,

        /// <summary>Doors left open: open door plus the closable count.</summary>
        Open,

        /// <summary>Scan failed: warning triangle plus the last known port count.</summary>
        Error,
    }

    /// <summary>
    /// The tray icon, mirroring the original menu bar: door mark plus the closable-port
    /// count in monospaced digits (closed state shows no number; errors show a warning
    /// glyph plus the last known count). SF Symbols have no Windows equivalent, so the
    /// door comes from the repo's own DoorMark geometry and the warning glyph from
    /// Segoe MDL2 Assets.
    /// </summary>
    public static Icon RenderTrayIcon(int size, TrayState state, int count, Color frame)
    {
        var bitmap = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bitmap))
        {
            g.Clear(Color.Transparent);
            g.SmoothingMode = SmoothingMode.AntiAlias;

            if (state == TrayState.Error)
            {
                DrawGlyph(g, '\uE7BA', frame, new RectangleF(1, 1, size * 0.55f, size - 2)); // MDL2 warning
            }
            else
            {
                // The door occupies the left portion at full height.
                Paint(g, new RectangleF(0, 0, size * 0.58f, size), state == TrayState.Open, frame);
            }

            if (count > 0 && (state == TrayState.Open || state == TrayState.Error))
            {
                DrawMonospaceCount(g, count, frame, size);
            }
        }

        var handle = bitmap.GetHicon();
        try
        {
            using var borrowed = Icon.FromHandle(handle);
            return (Icon)borrowed.Clone();
        }
        finally
        {
            bitmap.Dispose();
            DestroyIcon(handle);
        }
    }

    private static void DrawMonospaceCount(Graphics g, int count, Color color, int size)
    {
        var text = count > 99 ? "99" : count.ToString();
        using var font = new Font("Consolas", Math.Max(7f, size * 0.62f), FontStyle.Bold, GraphicsUnit.Pixel);
        using var brush = new SolidBrush(color);
        var measured = g.MeasureString(text, font);
        var x = size - measured.Width - 0.5f;
        var y = (size - measured.Height) / 2f;
        g.DrawString(text, font, brush, x, y);
    }

    private static void DrawGlyph(Graphics g, char glyph, Color color, RectangleF bounds)
    {
        using var font = new Font("Segoe MDL2 Assets", bounds.Height * 0.85f, FontStyle.Regular, GraphicsUnit.Pixel);
        using var brush = new SolidBrush(color);
        var text = glyph.ToString();
        var measured = g.MeasureString(text, font);
        g.DrawString(text, font, brush, bounds.X + ((bounds.Width - measured.Width) / 2f), bounds.Y + ((bounds.Height - measured.Height) / 2f));
    }

    public static void Paint(Graphics g, RectangleF bounds, bool open, Color frame)
    {
        g.SmoothingMode = SmoothingMode.AntiAlias;

        // The original keeps the 33:55 aspect ratio and fits it inside the available box.
        var scale = Math.Min(bounds.Width / ViewWidth, bounds.Height / ViewHeight);
        var offsetX = bounds.X + ((bounds.Width - (ViewWidth * scale)) / 2f);
        var offsetY = bounds.Y + ((bounds.Height - (ViewHeight * scale)) / 2f);

        PointF At(float x, float y) => new(offsetX + (x * scale), offsetY + (y * scale));

        using var frameBrush = new SolidBrush(frame);

        using var back = new GraphicsPath();
        back.AddLine(At(0.74f, 54.51f), At(0.74f, 16.161f));
        back.AddBezier(At(0.74f, 16.161f), At(0.74f, 7.683f), At(7.755f, 0.707f), At(16.28f, 0.707f));
        back.AddBezier(At(16.28f, 0.707f), At(24.805f, 0.707f), At(31.82f, 7.683f), At(31.82f, 16.161f));
        back.AddLine(At(31.82f, 16.161f), At(31.82f, 54.51f));
        back.CloseFigure();

        using var leaf = new GraphicsPath();
        if (open)
        {
            leaf.AddLine(At(9.9f, 49.177f), At(9.9f, 18.124f));
            leaf.AddBezier(At(9.9f, 18.124f), At(9.9f, 10.845f), At(19.563f, 4.007f), At(27.417f, 5.505f));
            leaf.AddBezier(At(27.417f, 5.505f), At(31.965f, 9.711f), At(31.647f, 11.702f), At(31.647f, 18.981f));
            leaf.AddLine(At(31.647f, 18.981f), At(31.647f, 53.609f));
            leaf.CloseFigure();

            // Only the interior the swung-open leaf does not cover stays visible.
            using var visibleOpening = new Region(back);
            visibleOpening.Exclude(leaf);
            g.FillRegion(frameBrush, visibleOpening);
        }
        else
        {
            // Closed leaf: the original paints it in the background colour, so with a
            // transparent leaf there is nothing to fill — the ring and knob remain.
            leaf.AddLine(At(1.501f, 53.695f), At(31.264f, 53.695f));
            leaf.AddLine(At(31.264f, 53.695f), At(31.264f, 16.155f));
            leaf.AddBezier(At(31.264f, 16.155f), At(31.264f, 8.037f), At(24.545f, 1.358f), At(16.382f, 1.358f));
            leaf.AddBezier(At(16.382f, 1.358f), At(8.219f, 1.358f), At(1.501f, 8.037f), At(1.501f, 16.155f));
            leaf.CloseFigure();
        }

        // Frame outline: outer arch minus inner arch (even-odd), as in the original.
        using var outline = new GraphicsPath { FillMode = FillMode.Alternate };
        outline.AddLine(At(0.391f, 16.155f), At(0.391f, 16.155f));
        outline.AddBezier(At(0.391f, 16.155f), At(0.391f, 7.43f), At(7.609f, 0.248f), At(16.383f, 0.248f));
        outline.AddBezier(At(16.383f, 0.248f), At(25.157f, 0.248f), At(32.375f, 7.43f), At(32.375f, 16.155f));
        outline.AddLine(At(32.375f, 16.155f), At(32.375f, 54.805f));
        outline.AddLine(At(32.375f, 54.805f), At(0.391f, 54.805f));
        outline.CloseFigure();

        outline.AddLine(At(1.501f, 53.695f), At(31.264f, 53.695f));
        outline.AddLine(At(31.264f, 53.695f), At(31.264f, 16.155f));
        outline.AddBezier(At(31.264f, 16.155f), At(31.264f, 8.037f), At(24.545f, 1.358f), At(16.382f, 1.358f));
        outline.AddBezier(At(16.382f, 1.358f), At(8.219f, 1.358f), At(1.501f, 8.037f), At(1.501f, 16.155f));
        outline.CloseFigure();
        g.FillPath(frameBrush, outline);

        var knobX = open ? 13.552f : 24.0f;
        var knobSize = KnobRadius * 2 * scale;
        var knobTopLeft = At(knobX - KnobRadius, KnobY - KnobRadius);
        g.FillEllipse(frameBrush, knobTopLeft.X, knobTopLeft.Y, knobSize, knobSize);
    }

    /// <summary>White glyph on the default dark taskbar, near-black on light themes.</summary>
    public static Color ThemeFrameColor()
    {
        try
        {
            using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            var light = key?.GetValue("SystemUsesLightTheme") as int? ?? 0;
            return light == 1 ? Color.FromArgb(0x21, 0x18, 0x11) : Color.FromArgb(0xF2, 0xF2, 0xF2);
        }
        catch
        {
            return Color.FromArgb(0xF2, 0xF2, 0xF2);
        }
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyIcon(IntPtr handle);
}
