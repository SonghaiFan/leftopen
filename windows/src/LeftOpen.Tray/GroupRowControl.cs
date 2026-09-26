using System.Diagnostics;
using LeftOpen.Core;

namespace LeftOpen.Tray;

/// <summary>
/// One row in the panel list: port badge + process icon + owner label + sub-line,
/// with the LAN badge on the right, a hover-revealed × button, and a right-click
/// menu (open in browser / copy / close), mirroring leftopen's GroupRowItem.
/// </summary>
internal sealed class GroupRowControl : Panel
{
    private readonly PanelForm.GroupRow _group;
    private readonly Action<PanelForm.GroupRow> _openDetail;
    private readonly Action<PanelForm.GroupRow> _requestClose;
    private readonly Button _closeButton;
    private readonly PictureBox _icon;
    private bool _iconLoaded;

    public GroupRowControl(
        PanelForm.GroupRow group,
        Action<PanelForm.GroupRow> openDetail,
        Action<PanelForm.GroupRow> requestClose)
    {
        _group = group;
        _openDetail = openDetail;
        _requestClose = requestClose;

        // Right-hand columns anchor to the row's own width, which is the panel width
        // minus the flow panel's vertical scrollbar and the row margins.
        const int rowWidth = PanelForm.PanelWidth - 48;
        Height = 54;
        Width = rowWidth;
        Margin = new Padding(14, 2, 14, 2);
        BackColor = SystemColors.Window;
        Cursor = Cursors.Hand;

        // Expose the row to accessibility tools (and screen readers) as a button.
        AccessibleRole = AccessibleRole.PushButton;
        AccessibleName = $"端口 {string.Join(", ", group.Ports)} · {group.Label} · PID {group.Pid}";
        AccessibleDescription = group.Closable ? "打开详情" : $"不可关闭：{group.RefusalReason}";

        // Layout — main line: icon | owner | LAN | ✕
        //          sub line:  port +N · command · pid | uptime
        // The icon leads the row so it sits on the same line as the process name,
        // and the owner label gets the width it needs for long project names.
        _icon = new PictureBox
        {
            Size = new Size(24, 24),
            Location = new Point(10, 4),
            SizeMode = PictureBoxSizeMode.CenterImage,
        };

        var label = new Label
        {
            Text = TrimLabel(group.Label),
            AutoSize = false,
            Size = new Size(rowWidth - 136, 18),
            Location = new Point(44, 6),
            Font = new Font("Segoe UI", 9.5f, FontStyle.Bold),
            ForeColor = SystemColors.ControlText,
        };

        var port = new Label
        {
            Text = group.Ports[0].ToString(),
            AutoSize = false,
            Size = new Size(66, 18),
            Location = new Point(44, 25),
            Font = new Font("Consolas", 10.5f, FontStyle.Bold),
            ForeColor = SystemColors.ControlText,
            TextAlign = ContentAlignment.MiddleLeft,
        };

        var sub = new Label
        {
            Text = $"· {TrimCommand(group.Command)} · {group.Pid}",
            AutoSize = false,
            Size = new Size(rowWidth - 216, 16),
            Location = new Point(116, 27),
            ForeColor = SystemColors.GrayText,
        };

        var uptime = new Label
        {
            Text = group.StartTime != null ? DescribeDuration(DateTime.Now - group.StartTime.Value) : "—",
            AutoSize = false,
            Size = new Size(88, 16),
            Location = new Point(rowWidth - 96, 27),
            ForeColor = SystemColors.GrayText,
            TextAlign = ContentAlignment.MiddleRight,
        };

        if (group.Ports.Count > 1)
        {
            var more = new Label
            {
                Text = $"+{group.Ports.Count - 1}",
                AutoSize = false,
                Size = new Size(28, 15),
                Location = new Point(112, 26),
                Font = new Font("Segoe UI", 8f, FontStyle.Bold),
                BackColor = SystemColors.ControlLight,
                ForeColor = SystemColors.GrayText,
                TextAlign = ContentAlignment.MiddleCenter,
            };
            Controls.Add(more);
        }

        if (group.AnyLan)
        {
            var lan = new Label
            {
                Text = "LAN",
                AutoSize = false,
                Size = new Size(34, 16),
                Location = new Point(rowWidth - 84, 8),
                BackColor = Color.FromArgb(255, 235, 205),
                ForeColor = Color.FromArgb(150, 100, 20),
                Font = new Font("Segoe UI", 7.5f, FontStyle.Bold),
                TextAlign = ContentAlignment.MiddleCenter,
            };
            Controls.Add(lan);
        }

        _closeButton = new Button
        {
            Text = "✕",
            AccessibleName = $"关闭 {group.Label} (PID {group.Pid})",
            Font = new Font("Segoe UI", 10f, FontStyle.Bold),
            FlatStyle = FlatStyle.Flat,
            Size = new Size(32, 32),
            Location = new Point(rowWidth - 44, 4),
            ForeColor = Color.FromArgb(190, 60, 50),
            Visible = false,
            TabStop = false,
        };
        _closeButton.FlatAppearance.BorderSize = 0;
        _closeButton.FlatAppearance.MouseOverBackColor = Color.FromArgb(250, 228, 226);
        if (group.Closable)
        {
            _closeButton.Click += (_, _) => _requestClose(_group);
            Controls.Add(_closeButton);
        }

        Controls.Add(port);
        Controls.Add(_icon);
        Controls.Add(label);
        Controls.Add(sub);
        Controls.Add(uptime);

        MouseEnter += (_, _) => { BackColor = SystemColors.ControlLightLight; if (_group.Closable) _closeButton.Visible = true; };
        MouseLeave += OnMouseLeaveRow;
        foreach (Control child in Controls)
        {
            child.MouseEnter += (_, _) => { BackColor = SystemColors.ControlLightLight; if (_group.Closable) _closeButton.Visible = true; };
        }

        Click += (_, _) => _openDetail(_group);
        label.Click += (_, _) => _openDetail(_group);
        sub.Click += (_, _) => _openDetail(_group);
        _icon.Click += (_, _) => _openDetail(_group);
        MouseClick += OnRowMouseClick;
        label.MouseClick += OnRowMouseClick;

        // Icon loading touches the filesystem and possibly the running server; do it
        // off the hot path so the panel renders instantly.
        _ = Task.Run(() =>
        {
            var image = AppIcons.Resolve(group.ExecutablePath, group.ProjectRoot, group.Ports[0], group.Category, group.Command, 24);
            BeginInvoke(() =>
            {
                if (!IsDisposed)
                {
                    _icon.Image = image;
                }
                else
                {
                    image.Dispose();
                }
            });
        });
    }

    private void OnMouseLeaveRow(object? sender, EventArgs e)
    {
        if (ClientRectangle.Contains(PointToClient(MousePosition)))
        {
            return;
        }

        BackColor = SystemColors.Window;
        _closeButton.Visible = false;
    }

    private void OnRowMouseClick(object? sender, MouseEventArgs e)
    {
        if (e.Button != MouseButtons.Right)
        {
            return;
        }

        var menu = new ContextMenuStrip();
        menu.Items.Add($"在浏览器打开 :{ _group.Ports[0]}", null, (_, _) => OpenInBrowser(_group.Ports[0]));
        menu.Items.Add($"复制端口 {_group.Ports[0]}", null, (_, _) => CopyToClipboard(_group.Ports[0].ToString()));
        menu.Items.Add($"复制 PID {_group.Pid}", null, (_, _) => CopyToClipboard(_group.Pid.ToString()));
        if (_group.Closable)
        {
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add($"关闭进程 (PID {_group.Pid})…", null, (_, _) => _requestClose(_group));
        }

        menu.Show(this, e.Location);
    }

    private static void OpenInBrowser(int port)
    {
        try
        {
            Process.Start(new ProcessStartInfo { FileName = $"http://localhost:{port}/", UseShellExecute = true });
        }
        catch
        {
            // Browser launch failures are not worth interrupting the panel for.
        }
    }

    private static void CopyToClipboard(string text) => Clipboard.SetText(text);

    private static string TrimLabel(string label) => label.Length <= 40 ? label : label[..39] + "…";

    private static string TrimCommand(string command) => command.Length <= 28 ? command : command[..27] + "…";

    private static string DescribeDuration(TimeSpan span)
    {
        if (span.TotalMinutes < 1)
        {
            return $"{(int)span.TotalSeconds}秒";
        }

        if (span.TotalHours < 1)
        {
            return $"{(int)span.TotalMinutes}分钟";
        }

        if (span.TotalDays < 1)
        {
            return $"{(int)span.TotalHours}小时";
        }

        return $"{(int)span.TotalDays}天";
    }
}
