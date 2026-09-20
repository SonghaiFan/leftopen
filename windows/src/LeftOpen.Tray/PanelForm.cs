using System.Diagnostics;
using System.Security.Principal;
using LeftOpen.Core;
using Activity = LeftOpen.Core.Activity;

namespace LeftOpen.Tray;

/// <summary>
/// The popup panel anchored above the tray, mirroring leftopen's MenuBarExtra panel:
/// opens on tray click, scans once on open (never polls), grouped rows with real
/// icons, and a two-step confirm before any gentle close.
/// </summary>
internal sealed class PanelForm : Form
{
    internal const int PanelWidth = 392;
    private const int PanelHeight = 480;

    private readonly Action<ScanResult> _onScanFinished;
    private readonly Label _statusLabel;
    private readonly PictureBox _doorGlyph;
    private readonly TextBox _searchBox;
    private readonly Panel _content;
    private readonly Label _footer;
    private readonly Button _refreshButton;
    private readonly System.Windows.Forms.Timer _deferredHide = new() { Interval = 250 };

    private readonly CloseService _closeService = new();
    private ScanResult? _result;
    private DateTime? _scannedAt;
    private bool _scanning;
    private List<GroupRow> _groups = [];
    private Control? _currentView;
    private bool _notClosableExpanded;
    private string _searchText = "";

    public string? CurrentUserSid { get; } = WindowsIdentity.GetCurrent().User?.Value;

    public bool IsStale => _scannedAt == null || DateTime.Now - _scannedAt > TimeSpan.FromSeconds(20);

    public PanelForm(Action<ScanResult> onScanFinished)
    {
        _onScanFinished = onScanFinished;

        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        TopMost = true;
        Size = new Size(PanelWidth, PanelHeight);
        MinimumSize = new Size(PanelWidth, 380);
        MaximumSize = new Size(PanelWidth, 720);
        BackColor = SystemColors.Window;
        AutoScaleMode = AutoScaleMode.Dpi;
        Font = new Font("Segoe UI", 9f);

        _doorGlyph = new PictureBox
        {
            Size = new Size(26, 26),
            SizeMode = PictureBoxSizeMode.Zoom,
            Location = new Point(14, 12),
        };

        _statusLabel = new Label
        {
            AutoSize = false,
            Location = new Point(48, 10),
            Size = new Size(PanelWidth - 140, 30),
            TextAlign = ContentAlignment.MiddleLeft,
            ForeColor = SystemColors.ControlText,
            Text = "LeftOpen",
        };

        _refreshButton = new Button
        {
            Text = "↻",
            Font = new Font("Segoe UI", 11f, FontStyle.Bold),
            FlatStyle = FlatStyle.Flat,
            Size = new Size(36, 30),
            Location = new Point(PanelWidth - 52, 10),
            TabStop = false,
        };
        _refreshButton.FlatAppearance.BorderSize = 0;
        _refreshButton.FlatAppearance.MouseOverBackColor = SystemColors.ControlLight;
        _refreshButton.Click += (_, _) => Scan();

        _searchBox = new TextBox
        {
            Location = new Point(14, 46),
            Size = new Size(PanelWidth - 30, 24),
            PlaceholderText = "筛选端口、进程、项目…",
        };
        _searchBox.TextChanged += (_, _) =>
        {
            _searchText = _searchBox.Text.Trim();
            if (_result != null && _currentView is not null && _currentView.Name == "listView")
            {
                ShowListView();
            }
        };

        _content = new Panel
        {
            Location = new Point(0, 78),
            Size = new Size(PanelWidth, PanelHeight - 110),
            AutoScroll = true,
            BackColor = SystemColors.Window,
        };

        _footer = new Label
        {
            Dock = DockStyle.Bottom,
            Height = 28,
            TextAlign = ContentAlignment.MiddleRight,
            ForeColor = SystemColors.GrayText,
            Padding = new Padding(0, 6, 14, 0),
            Text = "尚未扫描",
        };

        Controls.Add(_content);
        Controls.Add(_footer);
        Controls.Add(_searchBox);
        Controls.Add(_refreshButton);
        Controls.Add(_statusLabel);
        Controls.Add(_doorGlyph);

        Resize += (_, _) =>
        {
            _content.Size = new Size(Width, Height - 110);
            _refreshButton.Location = new Point(Width - 52, 10);
            _statusLabel.Width = Width - 140;
            _searchBox.Width = Width - 30;
        };

        Deactivate += OnDeactivated;
        _deferredHide.Tick += (_, _) =>
        {
            _deferredHide.Stop();
            if (!IsActiveView())
            {
                Hide();
            }
        };

        ShowView(new Label
        {
            Name = "idle",
            Text = "点击 ↻ 扫描 localhost。",
            Dock = DockStyle.Fill,
            TextAlign = ContentAlignment.TopCenter,
            Padding = new Padding(0, 16, 0, 0),
            ForeColor = SystemColors.GrayText,
        });
    }

    /// <summary>Opens the panel near the tray icon; scans on open, like MenuBarExtra.</summary>
    public void OpenFromTray(bool rescan)
    {
        var area = Screen.FromPoint(Cursor.Position).WorkingArea;
        Location = new Point(area.Right - Width - 12, area.Bottom - Height - 12);

        Show();
        Activate();
        if (rescan)
        {
            Scan();
        }
    }

    private void OnDeactivated(object? sender, EventArgs e)
    {
        // During confirm/progress views we must not vanish while a sub-dialog has focus.
        if (_currentView is { Name: "confirmView" or "progressView" })
        {
            return;
        }

        _deferredHide.Stop();
        _deferredHide.Start();
    }

    private bool IsActiveView() => _currentView is { Name: "confirmView" or "progressView" } || ContainsFocus || Focused;

    public void Scan()
    {
        if (_scanning)
        {
            return;
        }

        _scanning = true;
        _refreshButton.Enabled = false;
        ShowView(new Label
        {
            Name = "scanningView",
            Text = "正在扫描此电脑…",
            Dock = DockStyle.Fill,
            TextAlign = ContentAlignment.TopCenter,
            Padding = new Padding(0, 16, 0, 0),
            ForeColor = SystemColors.GrayText,
        });

        Task.Run(() =>
        {
            ScanResult result;
            try
            {
                result = Scanner.ScanActivities();
            }
            catch (Exception ex)
            {
                result = new ScanResult([], [$"扫描失败：{ex.Message}"]);
            }

            BeginInvoke(() =>
            {
                _scanning = false;
                _refreshButton.Enabled = true;
                _result = result;
                _scannedAt = DateTime.Now;
                _footer.Text = $"扫描于 {DateTime.Now:HH:mm:ss}";
                _groups = BuildGroups(result);
                UpdateHeader();
                _onScanFinished(result);
                ShowListView();
            });
        });
    }

    private void UpdateHeader()
    {
        var result = _result;
        if (result == null)
        {
            return;
        }

        var closable = _groups.Count(g => g.Closable);
        var ports = result.Activities.Select(a => a.Facts.Listener.Port).Distinct().Count();
        var lan = result.Activities.Where(a => a.Facts.Listener.Scope == Scope.Lan)
            .Select(a => a.Facts.Listener.Port).Distinct().Count();
        _statusLabel.Text = $"{closable} 可关闭 · {ports} 监听 · {lan} LAN";
        _doorGlyph.Image = RenderDoorGlyph(closable > 0);
    }

    private Image RenderDoorGlyph(bool open)
    {
        var bitmap = new Bitmap(26, 26);
        using var g = Graphics.FromImage(bitmap);
        g.Clear(Color.Transparent);
        DoorIcon.Paint(g, new Rectangle(0, 0, 26, 26), open, SystemColors.ControlText);
        return bitmap;
    }

    // ---- grouping -----------------------------------------------------------

    internal sealed record GroupRow(
        int Pid,
        string Label,
        Category Category,
        string Command,
        IReadOnlyList<Activity> Activities,
        IReadOnlyList<int> Ports,
        bool AnyLan,
        bool Closable,
        string? RefusalReason,
        DateTime? StartTime,
        string? ExecutablePath,
        string? ProjectRoot);

    private static List<GroupRow> BuildGroups(ScanResult result)
    {
        var currentSid = WindowsIdentity.GetCurrent().User?.Value;
        var currentPid = Environment.ProcessId;

        return result.Activities
            .GroupBy(a => a.Facts.Process.Pid)
            .Select(pids =>
            {
                var activities = pids.OrderBy(a => a.Facts.Listener.Port).ToList();
                var first = activities[0];
                var process = first.Facts.Process;
                var closable = CloseService.DescribeClosability(first, currentSid, currentPid, out var refusal);
                return new GroupRow(
                    process.Pid,
                    first.Inference.Label,
                    first.Inference.Category,
                    process.Command,
                    activities,
                    activities.Select(a => a.Facts.Listener.Port).Distinct().ToList(),
                    activities.Any(a => a.Facts.Listener.Scope == Scope.Lan),
                    closable,
                    refusal,
                    process.StartTime,
                    process.ExecutablePath,
                    first.Facts.ProjectMarker?.Root);
            })
            .OrderBy(g => g.Category == Category.Project ? 0 : 1)
            .ThenBy(g => g.Ports[0])
            .ToList();
    }

    // ---- views --------------------------------------------------------------

    private void ShowView(Control view)
    {
        if (_currentView != null)
        {
            _content.Controls.Remove(_currentView);
            _currentView.Dispose();
        }

        _currentView = view;
        _content.Controls.Add(view);
        view.Dock = DockStyle.Fill;
        _content.AutoScrollPosition = Point.Empty;
    }

    private void ShowListView()
    {
        var view = new Panel { Name = "listView", AutoScroll = false, BackColor = SystemColors.Window };
        var flow = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.TopDown,
            WrapContents = false,
            AutoScroll = true,
        };

        var text = _searchText;
        var filtered = _groups.Where(g => Matches(g, text)).ToList();
        if (filtered.Count == 0 && _groups.Count > 0)
        {
            flow.Controls.Add(new Label
            {
                Text = "没有匹配的监听进程。",
                AutoSize = true,
                Margin = new Padding(16, 12, 16, 0),
                ForeColor = SystemColors.GrayText,
            });
        }

        foreach (var section in Sections(filtered))
        {
            if (section.Groups.Count == 0)
            {
                continue;
            }

            flow.Controls.Add(new Label
            {
                Text = section.Title,
                AutoSize = true,
                Margin = new Padding(16, 14, 16, 4),
                ForeColor = SystemColors.GrayText,
                Font = new Font("Segoe UI", 8.5f, FontStyle.Bold),
            });

            if (section.Collapsed)
            {
                var toggle = new LinkLabel
                {
                    Text = _notClosableExpanded ? "收起 ▴" : $"展开 {section.Groups.Count} 项 ▾",
                    AutoSize = true,
                    Margin = new Padding(24, 2, 16, 4),
                };
                toggle.LinkClicked += (_, _) =>
                {
                    _notClosableExpanded = !_notClosableExpanded;
                    ShowListView();
                };
                if (!_notClosableExpanded)
                {
                    flow.Controls.Add(toggle);
                    continue;
                }
            }

            foreach (var group in section.Groups)
            {
                flow.Controls.Add(new GroupRowControl(group, ShowDetail, CloseWithConfirm));
            }
        }

        if (_result is { Limitations.Count: > 0 })
        {
            flow.Controls.Add(new Label
            {
                Text = "⚠ " + string.Join("  ", _result.Limitations),
                AutoSize = true,
                MaximumSize = new Size(PanelWidth - 40, 0),
                Margin = new Padding(16, 12, 16, 0),
                ForeColor = Color.FromArgb(150, 110, 20),
            });
        }

        view.Controls.Add(flow);
        ShowView(view);
    }

    private IEnumerable<(string Title, List<GroupRow> Groups, bool Collapsed)> Sections(List<GroupRow> groups)
    {
        yield return ("我的项目", groups.Where(g => g.Category == Category.Project && g.Closable).ToList(), false);
        yield return ("其他进程", groups.Where(g => g.Category != Category.Project && g.Closable).ToList(), false);
        yield return ("不可关闭（系统或应用）", groups.Where(g => !g.Closable).ToList(), true);
    }

    private static bool Matches(GroupRow g, string text)
    {
        if (text.Length == 0)
        {
            return true;
        }

        return g.Ports.Any(p => p.ToString().Contains(text, StringComparison.OrdinalIgnoreCase)) ||
               g.Pid.ToString().Contains(text, StringComparison.OrdinalIgnoreCase) ||
               g.Label.Contains(text, StringComparison.OrdinalIgnoreCase) ||
               g.Command.Contains(text, StringComparison.OrdinalIgnoreCase) ||
               (g.ProjectRoot?.Contains(text, StringComparison.OrdinalIgnoreCase) ?? false);
    }

    private void ShowDetail(GroupRow group)
    {
        var view = new Panel { Name = "detailView", AutoScroll = true };
        var flow = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.TopDown,
            WrapContents = false,
            AutoScroll = true,
        };

        var back = new LinkLabel { Text = "‹ 返回", AutoSize = true, Margin = new Padding(16, 12, 16, 6) };
        back.LinkClicked += (_, _) => ShowListView();
        flow.Controls.Add(back);

        var facts = group.Activities[0].Facts;
        var inference = group.Activities[0].Inference;
        var uptime = group.StartTime != null ? DescribeDuration(DateTime.Now - group.StartTime.Value) : "未知";

        flow.Controls.Add(new Label
        {
            Text = group.Label,
            AutoSize = true,
            Margin = new Padding(16, 2, 16, 2),
            Font = new Font("Segoe UI", 13f, FontStyle.Bold),
        });
        flow.Controls.Add(new Label
        {
            Text = $"{CategoryTitle(inference.Category)} · {ConfidenceText(inference.Confidence)} · 运行 {uptime}",
            AutoSize = true,
            Margin = new Padding(16, 0, 16, 10),
            ForeColor = SystemColors.GrayText,
        });

        foreach (var activity in group.Activities)
        {
            var f = activity.Facts;
            flow.Controls.Add(new Label
            {
                Text = $"端口 {f.Listener.Port}   {(f.Listener.Scope == Scope.Local ? "仅本机" : "局域网可见")}   {string.Join(", ", f.Listener.Addresses)}",
                AutoSize = true,
                Margin = new Padding(16, 2, 16, 2),
                Font = new Font("Consolas", 10f, FontStyle.Bold),
            });
        }

        flow.Controls.Add(new Label
        {
            Text = InferenceBlock(facts, inference.Reason),
            AutoSize = true,
            MaximumSize = new Size(PanelWidth - 40, 0),
            Margin = new Padding(16, 10, 16, 10),
            ForeColor = SystemColors.ControlText,
        });

        if (group.Closable)
        {
            var close = new Button
            {
                Text = $"关闭进程 (PID {group.Pid})…",
                AutoSize = true,
                FlatStyle = FlatStyle.Flat,
                Margin = new Padding(16, 4, 16, 8),
            };
            close.FlatAppearance.BorderColor = Color.FromArgb(190, 60, 50);
            close.ForeColor = Color.FromArgb(190, 60, 50);
            close.Click += (_, _) => CloseWithConfirm(group);
            flow.Controls.Add(close);
        }
        else if (group.RefusalReason != null)
        {
            flow.Controls.Add(new Label
            {
                Text = "⨯ 无法关闭：" + group.RefusalReason,
                AutoSize = true,
                MaximumSize = new Size(PanelWidth - 40, 0),
                Margin = new Padding(16, 4, 16, 8),
                ForeColor = SystemColors.GrayText,
            });
        }

        view.Controls.Add(flow);
        ShowView(view);
    }

    private static string InferenceBlock(ActivityFacts facts, string reason) =>
        $"""
        进程      {facts.Process.Command} (PID {facts.Process.Pid}, PPID {facts.Process.ParentPid?.ToString() ?? "未知"})
        用户      {facts.Process.OwnerName ?? facts.Process.OwnerSid ?? "未知"}
        可执行    {Ownership.CompactPath(facts.Process.ExecutablePath)}
        工作目录  {Ownership.CompactPath(facts.Process.Cwd)}
        项目标记  {(facts.ProjectMarker != null ? $"{facts.ProjectMarker.Source} — {Ownership.CompactPath(facts.ProjectMarker.MarkerPath)}" : "无")}
        依据      {reason}
        """;

    private void CloseWithConfirm(GroupRow group)
    {
        var view = new Panel { Name = "confirmView" };
        var flow = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.TopDown,
            WrapContents = false,
            AutoScroll = true,
        };

        var facts = group.Activities[0].Facts;
        var uptime = group.StartTime != null ? DescribeDuration(DateTime.Now - group.StartTime.Value) : "未知";

        flow.Controls.Add(new Label
        {
            Text = $"关闭 PID {group.Pid}？",
            AutoSize = true,
            Margin = new Padding(16, 14, 16, 4),
            Font = new Font("Segoe UI", 13f, FontStyle.Bold),
        });
        flow.Controls.Add(new Label
        {
            Text = $"{group.Label} · {facts.Process.Command} · 运行 {uptime}",
            AutoSize = true,
            Margin = new Padding(16, 0, 16, 10),
            ForeColor = SystemColors.GrayText,
        });
        flow.Controls.Add(new Label
        {
            Text = $"可执行文件\n{Ownership.CompactPath(facts.Process.ExecutablePath)}\n\n端口\n{string.Join("、", group.Ports)}",
            AutoSize = true,
            MaximumSize = new Size(PanelWidth - 40, 0),
            Margin = new Padding(16, 0, 16, 10),
        });

        if (group.Ports.Count > 1)
        {
            flow.Controls.Add(new Label
            {
                Text = $"⚠ 该进程还监听其他端口（{string.Join("、", group.Ports.Skip(1))}），关闭后它们可能一起释放。",
                AutoSize = true,
                MaximumSize = new Size(PanelWidth - 40, 0),
                Margin = new Padding(16, 0, 16, 4),
                ForeColor = Color.FromArgb(150, 110, 20),
            });
        }

        flow.Controls.Add(new Label
        {
            Text = "将发送温和关闭（等同在该进程的终端里按 Ctrl+C），绝不使用强杀；若它不响应，会如实告诉你。",
            AutoSize = true,
            MaximumSize = new Size(PanelWidth - 40, 0),
            Margin = new Padding(16, 4, 16, 12),
            ForeColor = SystemColors.GrayText,
        });

        var cancel = new Button { Text = "取消", AutoSize = true, FlatStyle = FlatStyle.Flat, Margin = new Padding(16, 0, 8, 0) };
        cancel.Click += (_, _) => ShowListView();

        var confirm = new Button
        {
            Text = "关闭",
            AutoSize = true,
            FlatStyle = FlatStyle.Flat,
            ForeColor = Color.White,
            BackColor = Color.FromArgb(200, 60, 50),
            Margin = new Padding(8, 0, 16, 0),
        };
        confirm.Click += async (_, _) => await ExecuteClose(group);

        var buttons = new FlowLayoutPanel { AutoSize = true, Margin = new Padding(12, 0, 0, 0) };
        buttons.Controls.Add(cancel);
        buttons.Controls.Add(confirm);
        flow.Controls.Add(buttons);

        view.Controls.Add(flow);
        ShowView(view);
    }

    private async Task ExecuteClose(GroupRow group)
    {
        var view = new Panel { Name = "progressView" };
        var label = new Label
        {
            Text = "正在发送温和关闭并检查端口…",
            Dock = DockStyle.Fill,
            TextAlign = ContentAlignment.TopCenter,
            Padding = new Padding(0, 20, 0, 0),
            ForeColor = SystemColors.GrayText,
        };
        view.Controls.Add(label);
        ShowView(view);

        try
        {
            var plan = await _closeService.PrepareCloseAsync(
                new CloseOptions(group.Ports[0], group.Pid, CurrentUserSid, Environment.ProcessId));
            var result = await _closeService.ExecuteCloseAsync(plan);

            if (result.PortFree)
            {
                label.Text = "端口已释放 ✓";
            }
            else if (result.TargetStoppedListening)
            {
                label.Text = $"PID {group.Pid} 已停止监听，但端口被 {string.Join(", ", result.RemainingPids)} 接管。";
            }
            else if (!result.SignalsDelivered)
            {
                label.Text = $"无法向 PID {group.Pid} 送达温和关闭（无可达的窗口或控制台），进程未受影响，未强杀。";
            }
            else
            {
                label.Text = $"已发送温和关闭，但 PID {group.Pid} 仍在监听。未强杀。";
            }
        }
        catch (CloseRefusedException ex)
        {
            label.Text = "已拒绝关闭：" + ex.Message;
        }
        catch (Exception ex)
        {
            label.Text = "关闭失败：" + ex.Message;
        }

        await Task.Delay(1200);
        Scan();
    }

    private static string CategoryTitle(Category category) => category switch
    {
        Category.Project => "我的项目",
        Category.Application => "应用",
        Category.SystemService => "系统服务",
        _ => "未知",
    };

    private static string ConfidenceText(Confidence confidence) => confidence switch
    {
        Confidence.High => "高置信",
        Confidence.Medium => "中置信",
        _ => "无置信",
    };

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
            return $"{(int)span.TotalHours}小时{(int)span.TotalMinutes % 60}分";
        }

        return $"{(int)span.TotalDays}天{(int)span.TotalHours % 24}小时";
    }
}
