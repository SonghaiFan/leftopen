using LeftOpen.Core;

namespace LeftOpen.Tray;

/// <summary>
/// The door glyph for the system tray: a closed door when localhost is quiet,
/// an open door when something was left running. Drawn with GDI+ in a colour
/// that adapts to the light/dark taskbar theme, like leftopen's DoorMark.
/// </summary>
internal static class DoorIcon
{
    public static Icon Closed(int size) => Create(size, open: false);

    public static Icon Open(int size) => Create(size, open: true);

    public static void Paint(Graphics g, Rectangle bounds, bool open, Color color)
    {
        g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        using var pen = new Pen(color, Math.Max(1.5f, bounds.Width / 12f));
        var thickness = Math.Max(3, bounds.Width / 7);

        // Door frame: rounded rectangle outline.
        var frame = Rectangle.Inflate(bounds, -thickness, -thickness / 2);
        frame.Height += thickness / 2;
        using var framePath = RoundedRect(frame, bounds.Width / 8);
        g.DrawPath(pen, framePath);

        if (open)
        {
            // The leaf swung outwards: a parallelogram from the frame's edge.
            var leaf = new[]
            {
                new PointF(frame.Right - thickness - 1, frame.Top + thickness),
                new PointF(frame.Right + thickness * 1.1f, frame.Top + thickness * 2.2f),
                new PointF(frame.Right + thickness * 1.1f, frame.Bottom - 1),
                new PointF(frame.Right - thickness - 1, frame.Bottom - thickness / 2),
            };
            using var leafPath = new System.Drawing.Drawing2D.GraphicsPath();
            leafPath.AddPolygon(leaf);
            using var fill = new SolidBrush(Color.FromArgb(90, color));
            g.FillPath(fill, leafPath);
            g.DrawPath(pen, leafPath);

            // Knob on the frame side.
            g.FillEllipse(new SolidBrush(color), frame.Left + thickness, frame.Top + frame.Height / 2 - thickness, thickness * 1.2f, thickness * 1.2f);
        }
        else
        {
            // Closed leaf fills the frame, with a knob on the right.
            var leaf = Rectangle.Inflate(frame, -thickness / 3, -thickness / 3);
            using var leafPath = RoundedRect(leaf, bounds.Width / 10);
            g.FillPath(new SolidBrush(Color.FromArgb(60, color)), leafPath);
            g.DrawPath(pen, leafPath);

            var knobSize = Math.Max(3, bounds.Width / 9);
            var knob = new Rectangle(leaf.Right - knobSize - thickness, leaf.Top + leaf.Height / 2 - knobSize / 2, knobSize, knobSize);
            g.FillEllipse(new SolidBrush(color), knob);
        }
    }

    private static System.Drawing.Drawing2D.GraphicsPath RoundedRect(Rectangle bounds, int radius)
    {
        var path = new System.Drawing.Drawing2D.GraphicsPath();
        var d = radius * 2;
        path.AddArc(bounds.Left, bounds.Top, d, d, 180, 90);
        path.AddArc(bounds.Right - d, bounds.Top, d, d, 270, 90);
        path.AddArc(bounds.Right - d, bounds.Bottom - d, d, d, 0, 90);
        path.AddArc(bounds.Left, bounds.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    private static Icon Create(int size, bool open)
    {
        using var bitmap = new Bitmap(size, size);
        using (var g = Graphics.FromImage(bitmap))
        {
            g.Clear(Color.Transparent);
            Paint(g, new Rectangle(0, 0, size, size), open, TaskbarGlyphColor());
        }

        return Icon.FromHandle(bitmap.GetHicon());
    }

    /// <summary>White glyph on the default dark taskbar, dark glyph on light themes.</summary>
    public static Color TaskbarGlyphColor()
    {
        try
        {
            using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            var light = key?.GetValue("SystemUsesLightTheme") as int? ?? 0;
            return light == 1 ? Color.FromArgb(32, 32, 32) : Color.FromArgb(240, 240, 240);
        }
        catch
        {
            return Color.FromArgb(240, 240, 240);
        }
    }
}
