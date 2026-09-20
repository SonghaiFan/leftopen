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
    static void Main()
    {
        using var singleInstance = new Mutex(true, @"Local\LeftOpenApp.SingleInstance", out var isFirst);
        if (!isFirst)
        {
            // Already running: ask that instance to open its panel (so a shortcut or
            // a second launch brings the panel up instead of doing nothing).
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
            Icon = DoorIcon.Closed(32),
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
            OpenPanel();
        }
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

        var closable = result.Activities
            .Select(a => a.Facts.Process.Pid)
            .Distinct()
            .Count(pid => result.Activities.Any(a =>
                a.Facts.Process.Pid == pid &&
                CloseService.DescribeClosability(a, _panel.CurrentUserSid, Environment.ProcessId, out _)));

        // Rebuild the tray icon for the current taskbar theme; dispose the old one.
        var old = _notifyIcon.Icon;
        _notifyIcon.Icon = closable > 0 ? DoorIcon.Open(32) : DoorIcon.Closed(32);
        old?.Dispose();
        _notifyIcon.Text = closable > 0
            ? $"LeftOpen — {closable} 个可关闭的进程"
            : "LeftOpen — localhost 干净";
    }

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
