using LeftOpen.Core;

namespace LeftOpen.Tray;

static class Program
{
    /// <summary>Named event a second launch uses to ask the running instance to show its panel.</summary>
    internal const string OpenPanelEventName = @"Local\LeftOpenApp.OpenPanel";

    /// <summary>
    /// LeftOpen tray app: a door in the notification area. No window, no dock,
    /// no background scanning — the scan runs only while the panel is open,
    /// mirroring leftopen's MenuBarExtra philosophy.
    /// </summary>
    [STAThread]
    static void Main(string[] args)
    {
        // Snapshot mode (mirrors the original repo's snapshot-panel script): render
        // the panel with a real scan to a PNG and exit. Skips the single-instance
        // handshake so it works even while the tray app is running.
        if (args.Length == 2 && args[0] == "--snapshot")
        {
            ApplicationConfiguration.Initialize();
            var snapshotPanel = new PanelForm(_ => { });
            var path = Path.GetFullPath(args[1]);

            // The awaits and BeginInvoke callbacks inside SnapshotAsync need a
            // running message loop, so pump it via Application.Run and close the
            // form (ending the loop) when the render is done.
            _ = SnapshotAndQuit(snapshotPanel, path);
            Application.Run(snapshotPanel);
            return;
        }

        using var singleInstance = new Mutex(true, @"Local\LeftOpenApp.SingleInstance", out var isFirst);
        if (!isFirst)
        {
            // Already running: ask that instance to open its panel (so a shortcut or
            // a second launch brings the panel up instead of doing nothing). Hand
            // over the foreground right first — this process was started by the
            // user, so it may call SetForegroundWindow while the running instance
            // (signalled from a background thread) may not.
            AllowSetForegroundWindow(AsfwAny);
            if (EventWaitHandle.TryOpenExisting(OpenPanelEventName, out var openEvent))
            {
                openEvent.Set();
                openEvent.Dispose();
            }

            return;
        }

        using var panelEvent = new EventWaitHandle(false, EventResetMode.AutoReset, OpenPanelEventName);

        ApplicationConfiguration.Initialize();
        Thread.CurrentThread.Name = "ui";

        var context = new TrayContext();
        var listener = new Thread(() =>
        {
            while (true)
            {
                if (!panelEvent.WaitOne())
                {
                    return;
                }

                context.OpenPanel();
            }
        })
        {
            IsBackground = true,
            Name = "open-panel-listener",
        };
        listener.Start();

        Application.Run(context);
        GC.KeepAlive(singleInstance);
    }

    private const uint AsfwAny = 0xFFFFFFFF;

    private static async Task SnapshotAndQuit(PanelForm panel, string path)
    {
        try
        {
            await panel.SnapshotAsync(path);

            // Also dump the tray icon states next to the panel snapshot so the
            // notification-area rendering can be inspected without hunting for the
            // icon in the tray overflow.
            var trayPath = Path.Combine(
                Path.GetDirectoryName(path) ?? ".",
                Path.GetFileNameWithoutExtension(path) + "-tray.png");
            using var strip = new Bitmap(144, 48);
            using (var g = Graphics.FromImage(strip))
            {
                g.Clear(Color.FromArgb(0x1F, 0x1F, 0x1F)); // dark taskbar
                var frame = DoorMark.ThemeFrameColor();
                using var closed = DoorMark.RenderTrayIcon(48, DoorMark.TrayState.Closed, 0, frame);
                using var open = DoorMark.RenderTrayIcon(48, DoorMark.TrayState.Open, 3, frame);
                using var error = DoorMark.RenderTrayIcon(48, DoorMark.TrayState.Error, 12, frame);
                g.DrawIcon(closed, new Rectangle(0, 0, 48, 48));
                g.DrawIcon(open, new Rectangle(48, 0, 48, 48));
                g.DrawIcon(error, new Rectangle(96, 0, 48, 48));
            }

            strip.Save(trayPath, System.Drawing.Imaging.ImageFormat.Png);
        }
        finally
        {
            panel.Close();
        }
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool AllowSetForegroundWindow(uint processId);
}

/// <summary>Owns the NotifyIcon for the whole app lifetime; the panel is created on demand.</summary>
internal sealed class TrayContext : ApplicationContext
{
    private readonly NotifyIcon _notifyIcon;
    private readonly PanelForm _panel;
    private bool _disposed;

    public TrayContext()
    {
        _panel = new PanelForm(OnScanFinished);
        _ = _panel.Handle; // realize the window handle so BeginInvoke works from other threads

        var menu = new ContextMenuStrip();
        menu.Items.Add("刷新(&R)", null, (_, _) => _panel.OpenFromTray(rescan: true));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("开机自启动(&S)", null, (_, _) => ToggleStartup());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("退出(&Q)", null, (_, _) => ExitThread());

        _notifyIcon = new NotifyIcon
        {
            Icon = DoorMark.RenderTrayIcon(TrayIconSize(), DoorMark.TrayState.Closed, 0, DoorMark.ThemeFrameColor()),
            Text = "LeftOpen — 查看遗留进程",
            ContextMenuStrip = menu,
            Visible = true,
        };
        _notifyIcon.MouseClick += OnTrayMouseClick;

        Application.ApplicationExit += OnApplicationExit;
    }

    private void OnTrayMouseClick(object? sender, MouseEventArgs e)
    {
        if (e.Button == MouseButtons.Left)
        {
            TogglePanel();
        }
    }

    /// <summary>Tray click toggles the panel, the way a menu bar icon does.</summary>
    public void TogglePanel()
    {
        if (_panel.Visible)
        {
            _panel.HidePanel();
            return;
        }

        OpenPanel();
    }

    /// <summary>Shows the panel, scanning only when the previous scan is stale. Safe from any thread.</summary>
    public void OpenPanel()
    {
        if (_panel.InvokeRequired)
        {
            _panel.BeginInvoke(OpenPanel);
            return;
        }

        _panel.OpenFromTray(rescan: _panel.IsStale);
    }

    private void OnScanFinished(ScanResult result)
    {
        if (_disposed)
        {
            return;
        }

        // Closable ports, the way the original counts them for its menu bar label.
        var closablePorts = result.Activities
            .Where(a => CloseService.DescribeClosability(a, _panel.CurrentUserSid, Environment.ProcessId, out _))
            .Select(a => a.Facts.Listener.Port)
            .Distinct()
            .Count();
        var failed = result.Activities.Count == 0 && result.Limitations.Any(l => l.StartsWith("扫描失败"));
        var state = failed
            ? DoorMark.TrayState.Error
            : closablePorts > 0 ? DoorMark.TrayState.Open : DoorMark.TrayState.Closed;

        // Rebuild the tray icon for the current taskbar theme; dispose the old one.
        var old = _notifyIcon.Icon;
        _notifyIcon.Icon = DoorMark.RenderTrayIcon(TrayIconSize(), state, closablePorts, DoorMark.ThemeFrameColor());
        old?.Dispose();

        _notifyIcon.Text = state switch
        {
            DoorMark.TrayState.Error => "LeftOpen — 扫描失败",
            DoorMark.TrayState.Open => $"LeftOpen — {closablePorts} 个可关闭的端口",
            _ => "LeftOpen — localhost 干净",
        };
    }

    private static int TrayIconSize() => Math.Max(SystemInformation.SmallIconSize.Width, 16);

    private void ToggleStartup()
    {
        const string runKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        try
        {
            using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(runKey, writable: true);
            if (key == null)
            {
                return;
            }

            var value = (string?)key.GetValue("LeftOpen");
            if (string.IsNullOrEmpty(value))
            {
                var exe = Environment.ProcessPath;
                if (exe == null)
                {
                    return;
                }

                key.SetValue("LeftOpen", $"\"{exe}\"");
                MessageBox.Show("已开启开机自启动。", "LeftOpen", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            else
            {
                key.DeleteValue("LeftOpen");
                MessageBox.Show("已关闭开机自启动。", "LeftOpen", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
        }
        catch (Exception ex)
        {
            MessageBox.Show($"切换自启动失败：{ex.Message}", "LeftOpen", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    private void OnApplicationExit(object? sender, EventArgs e) => Dispose();

    protected override void ExitThreadCore()
    {
        Dispose();
        base.ExitThreadCore();
    }

    protected override void Dispose(bool disposing)
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        if (disposing)
        {
            _panel.Dispose();
            _notifyIcon.Visible = false;
            _notifyIcon.Icon?.Dispose();
            _notifyIcon.Dispose();
        }

        base.Dispose(disposing);
    }
}
