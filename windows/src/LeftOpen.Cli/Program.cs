using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using LeftOpen.Core;
using Activity = LeftOpen.Core.Activity;

namespace LeftOpen.Cli;

internal static class Program
{
    private const int EnableVirtualTerminalProcessing = 0x0004;

    private static bool _colorEnabled;

    private static int Main(string[] arguments)
    {
        try
        {
            Console.OutputEncoding = Encoding.UTF8;
            _colorEnabled = !Console.IsOutputRedirected && !arguments.Contains("--no-color") &&
                            Environment.GetEnvironmentVariable("NO_COLOR") == null;
            EnableAnsi();

            return Run(arguments);
        }
        catch (CloseRefusedException ex)
        {
            Console.Error.WriteLine($"LeftOpen refused to close this port: {ex.Message}");
            return 1;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"LeftOpen could not scan this PC: {ex.Message}");
            return 1;
        }
    }

    private static int Run(string[] arguments)
    {
        var args = arguments.Where(arg => arg != "--no-color").ToArray();
        if (args.Contains("-h") || args.Contains("--help"))
        {
            Help();
            return 0;
        }

        if (args.Contains("-v") || args.Contains("--version"))
        {
            Console.WriteLine(typeof(Program).Assembly.GetName().Version?.ToString(3) ?? "0.1.0");
            return 0;
        }

        if (args.Length > 0 && args[0] == "close")
        {
            return RunClose(args[1..]).GetAwaiter().GetResult();
        }

        if (args.Length > 0 && args[0] == "open")
        {
            return RunOpen(args[1..]);
        }

        return RunList(args);
    }

    private static int RunList(string[] args)
    {
        var json = args.Contains("--json");
        var positional = args.Where(arg => arg != "--json").ToArray();
        if (positional.Length > 1 || (positional.Length == 1 && !IsPort(positional[0])))
        {
            Console.Error.WriteLine("Usage: leftopen [port] [--json]");
            return 2;
        }

        var port = positional.Length == 1 ? ParsePort(positional[0]) : null;
        var result = Scanner.ScanActivities();

        if (json)
        {
            var selected = port == null
                ? result.Activities
                : result.Activities.Where(a => a.Facts.Listener.Port == port).ToList();
            Console.WriteLine(JsonSerializer.Serialize(
                new { activities = selected, limitations = result.Limitations },
                JsonOptions));
            return 0;
        }

        if (port != null)
        {
            PrintDetail(port.Value, result.Activities);
        }
        else
        {
            PrintOverview(result.Activities);
        }

        if (result.Limitations.Count > 0)
        {
            Console.WriteLine(Yellow($"Limited evidence: {string.Join(" ", result.Limitations)}"));
        }

        return 0;
    }

    private static int RunOpen(string[] args)
    {
        if (args.Length != 1 || !IsPort(args[0]))
        {
            Console.Error.WriteLine("Usage: leftopen open <port>");
            return 2;
        }

        var port = ParsePort(args[0])!.Value;
        var url = $"http://localhost:{port}/";
        try
        {
            Process.Start(new ProcessStartInfo { FileName = url, UseShellExecute = true });
            Console.WriteLine(Green($"Opened {url} in your browser."));
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"LeftOpen could not open {url}: {ex.Message}");
            return 1;
        }
    }

    private static async Task<int> RunClose(string[] args)
    {
        var dryRun = args.Contains("--dry-run");
        var yes = args.Contains("--yes");
        int? selectedPid = null;
        var positional = new List<string>();

        for (var i = 0; i < args.Length; i++)
        {
            if (args[i] == "--pid")
            {
                if (i + 1 >= args.Length || !int.TryParse(args[i + 1], out var pidValue))
                {
                    Console.Error.WriteLine("Usage: leftopen close <port> [--pid <pid>] [--dry-run] [--yes]");
                    return 2;
                }

                selectedPid = pidValue;
                i++;
            }
            else if (args[i] is "--dry-run" or "--yes")
            {
                // handled above
            }
            else
            {
                positional.Add(args[i]);
            }
        }

        if (positional.Count != 1 || !IsPort(positional[0]))
        {
            Console.Error.WriteLine("Usage: leftopen close <port> [--pid <pid>] [--dry-run] [--yes]");
            return 2;
        }

        var port = ParsePort(positional[0])!.Value;
        var currentSid = WindowsIdentity.GetCurrent().User?.Value;
        var service = new CloseService();

        var plan = await service.PrepareCloseAsync(new CloseOptions(port, selectedPid, currentSid, Environment.ProcessId));

        Console.WriteLine();
        Console.WriteLine($"{Bold($"CLOSE PORT {port}")} · PID {plan.Pid}");
        Console.WriteLine($"Owner:      {plan.Activity.Inference.Label} ({plan.Activity.Inference.Confidence.ToString().ToLowerInvariant()} confidence)");
        Console.WriteLine($"Process:    {plan.Activity.Facts.Process.Command}");
        Console.WriteLine($"Executable: {Ownership.CompactPath(plan.ExecutablePath)}");
        Console.WriteLine($"CWD:        {Ownership.CompactPath(plan.Activity.Facts.Process.Cwd)}");
        Console.WriteLine($"Started:    {plan.StartTime:yyyy-MM-dd HH:mm:ss} (uptime {DescribeDuration(DateTime.UtcNow - plan.StartTime.ToUniversalTime())})");
        if (plan.OtherPorts.Count > 0)
        {
            Console.WriteLine(Yellow($"Warning: the same PID also listens on {string.Join(", ", plan.OtherPorts)}; they may close too."));
        }
        if (plan.PeerPids.Count > 0)
        {
            Console.WriteLine(Yellow($"Other PIDs also listen on this port: {string.Join(", ", plan.PeerPids)}. Only PID {plan.Pid} will be signalled."));
        }

        if (dryRun)
        {
            Console.WriteLine(Green("Dry run: no signal sent."));
            return 0;
        }

        if (!yes)
        {
            if (Console.IsInputRedirected)
            {
                Console.Error.WriteLine("An interactive terminal is required; use --yes only when you intend to close this PID.");
                return 1;
            }

            Console.Write($"Close PID {plan.Pid} listening on port {port}? [y/N] ");
            var answer = Console.ReadLine()?.Trim().ToLowerInvariant();
            if (answer is not ("y" or "yes"))
            {
                Console.WriteLine("Cancelled; no signal sent.");
                return 0;
            }
        }

        Console.WriteLine(Dim("Sending a gentle close (WM_CLOSE / Ctrl+C / Ctrl+Break) and checking the port..."));
        var result = await service.ExecuteCloseAsync(plan);
        if (result.PortFree)
        {
            Console.WriteLine(Green($"Port {port} is now free."));
            return 0;
        }

        if (result.TargetStoppedListening)
        {
            Console.WriteLine(Yellow($"PID {plan.Pid} stopped listening, but port {port} is now held by {string.Join(", ", result.RemainingPids)}."));
            return 1;
        }

        if (!result.SignalsDelivered)
        {
            Console.WriteLine(Yellow(
                $"No gentle close could be delivered to PID {plan.Pid} (it has no reachable window or console), so it was left running. " +
                "No force-kill was attempted."));
            return 1;
        }

        Console.WriteLine(Yellow($"A gentle close was sent, but PID {plan.Pid} still listens on port {port}. No force-kill was attempted."));
        return 1;
    }

    private static void Help()
    {
        Console.WriteLine($"""
            {Bold("LeftOpen")} — See what your tools left running on localhost.

            Usage:
              leftopen               Show all listening activity
              leftopen <port>        Explain who owns a port
              leftopen open <port>   Open a port in your browser
              leftopen close <port>  Gracefully close the process listening on a port
              leftopen --json        Print machine-readable output

            Options:
              --no-color             Disable colours
              --pid <pid>            Select a PID when multiple processes share a port
              --dry-run              Preview a close without signalling anything
              --yes                  Confirm a close without an interactive prompt
              -h, --help             Show this help
              -v, --version          Show the version
            """);
    }

    private static void PrintOverview(IReadOnlyList<Activity> activities)
    {
        var portCount = activities.Select(a => a.Facts.Listener.Port).Distinct().Count();
        var processCount = activities.Select(a => a.Facts.Process.Pid).Distinct().Count();
        var projectCount = activities
            .Where(a => a.Facts.ProjectMarker != null)
            .Select(a => a.Facts.ProjectMarker!.Root)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Count();
        var lanCount = activities
            .Where(a => a.Facts.Listener.Scope == Scope.Lan)
            .Select(a => a.Facts.Listener.Port)
            .Distinct()
            .Count();

        Console.WriteLine();
        Console.WriteLine(Bold("LEFT OPEN"));
        Console.WriteLine(
            $"{Cyan(portCount.ToString())} listening ports · {processCount} processes · " +
            $"{projectCount} projects · {Yellow(lanCount.ToString())} LAN-visible");

        var sections = new (Category Category, string Title)[]
        {
            (Category.Project, "MY PROJECTS"),
            (Category.Application, "APPLICATIONS"),
            (Category.SystemService, "SYSTEM SERVICES"),
            (Category.Unknown, "UNKNOWN"),
        };

        foreach (var (category, title) in sections)
        {
            PrintSection(title, activities.Where(a => a.Inference.Category == category).ToList());
        }

        Console.WriteLine(Dim("\nLOCAL = this PC only · LAN = may be reachable from your local network\n"));
    }

    private static void PrintSection(string title, IReadOnlyList<Activity> activities)
    {
        if (activities.Count == 0)
        {
            return;
        }

        Console.WriteLine();
        Console.WriteLine($"{Bold(title)} {Dim($"({activities.Count})")}");
        Console.WriteLine(Dim($"{Pad("PORT", 8)}{Pad("PID", 9)}{Pad("OWNER", 29)}{Pad("PROCESS", 25)}SCOPE"));

        foreach (var activity in activities)
        {
            var facts = activity.Facts;
            Console.WriteLine(
                $"{Pad(facts.Listener.Port, 8)}{Pad(facts.Process.Pid, 9)}{Pad(Trim(activity.Inference.Label, 27), 29)}" +
                $"{Pad(Trim(facts.Process.Command, 23), 25)}{ScopeLabel(activity)}");
            if (facts.ProjectMarker is { } marker)
            {
                Console.WriteLine(Dim($"         ↳ {Ownership.CompactPath(marker.Root)}"));
            }
        }
    }

    private static void PrintDetail(int port, IReadOnlyList<Activity> activities)
    {
        var matches = activities.Where(a => a.Facts.Listener.Port == port).ToList();
        if (matches.Count == 0)
        {
            Console.WriteLine($"\n{Green("FREE")} Nothing is listening on port {port}.\n");
            return;
        }

        Console.WriteLine($"\n{Bold($"PORT {port}")} · {matches.Count} listener{(matches.Count == 1 ? "" : "s")}");
        for (var index = 0; index < matches.Count; index++)
        {
            var activity = matches[index];
            var facts = activity.Facts;
            if (index > 0)
            {
                Console.WriteLine(Dim(new string('─', 56)));
            }

            var started = facts.Process.StartTime;
            var uptime = started != null
                ? DescribeDuration(DateTime.UtcNow - started.Value.ToUniversalTime())
                : null;

            Console.WriteLine($"Owner:      {activity.Inference.Label}");
            Console.WriteLine($"Type:       {activity.Inference.Category.ToString().ToLowerInvariant()}");
            Console.WriteLine($"Confidence: {activity.Inference.Confidence.ToString().ToLowerInvariant()}");
            Console.WriteLine($"Process:    {facts.Process.Command}");
            Console.WriteLine($"PID:        {facts.Process.Pid}");
            Console.WriteLine($"PPID:       {facts.Process.ParentPid?.ToString() ?? "unknown"}");
            Console.WriteLine($"User:       {facts.Process.OwnerName ?? facts.Process.OwnerSid ?? "unknown"}");
            Console.WriteLine($"Uptime:     {uptime ?? "unknown"}");
            Console.WriteLine($"Scope:      {ScopeLabel(activity)}");
            Console.WriteLine($"Addresses:  {string.Join(", ", facts.Listener.Addresses)}");
            Console.WriteLine($"Executable: {(facts.Process.ExecutablePath != null ? Ownership.CompactPath(facts.Process.ExecutablePath) : "unknown")}");
            Console.WriteLine($"CWD:        {Ownership.CompactPath(facts.Process.Cwd)}");
            if (facts.ProjectMarker is { } marker)
            {
                Console.WriteLine($"Marker:     {Ownership.CompactPath(marker.MarkerPath)}");
            }
            if (facts.InstalledApp is { } app)
            {
                Console.WriteLine($"App path:   {Ownership.CompactPath(app.Path)}");
            }
            if (facts.ParentChain.Count > 0)
            {
                Console.WriteLine($"Parents:    {string.Join(" → ", facts.ParentChain.Select(parent => $"{parent.Command} ({parent.Pid})"))}");
            }
            Console.WriteLine($"Reason:     {activity.Inference.Reason}");
        }

        Console.WriteLine();
    }

    internal static string DescribeDuration(TimeSpan span)
    {
        if (span.TotalMinutes < 1)
        {
            return $"{(int)span.TotalSeconds}s";
        }

        if (span.TotalHours < 1)
        {
            return $"{(int)span.TotalMinutes}m";
        }

        if (span.TotalDays < 1)
        {
            return $"{(int)span.TotalHours}h {(int)span.TotalMinutes % 60}m";
        }

        return $"{(int)span.TotalDays}d {(int)span.TotalHours % 24}h";
    }

    private static string ScopeLabel(Activity activity) =>
        activity.Facts.Listener.Scope == Scope.Local ? Green("LOCAL") : Yellow("LAN");

    private static bool IsPort(string value) => int.TryParse(value, out var port) && port is >= 1 and <= 65535;

    private static int? ParsePort(string value) => IsPort(value) ? int.Parse(value) : null;

    private static string Pad(object value, int width)
    {
        var text = value.ToString() ?? "";
        // Windows dynamic ports (e.g. 54321) regularly overflow the column; keep
        // at least one space after the cell so columns never run together.
        return text.Length >= width ? text + " " : text + new string(' ', width - text.Length);
    }

    private static string Trim(string value, int width) =>
        value.Length <= width ? value : value[..(width - 1)] + "…";

    private static string Paint(int code, string text) => _colorEnabled ? $"\u001b[{code}m{text}\u001b[0m" : text;

    private static string Bold(string text) => Paint(1, text);

    private static string Dim(string text) => Paint(2, text);

    private static string Green(string text) => Paint(32, text);

    private static string Yellow(string text) => Paint(33, text);

    private static string Cyan(string text) => Paint(36, text);

    private static void EnableAnsi()
    {
        if (!_colorEnabled || Console.IsOutputRedirected)
        {
            return;
        }

        var handle = GetStdHandle(StdOutputHandle);
        if (GetConsoleMode(handle, out var mode))
        {
            SetConsoleMode(handle, mode | EnableVirtualTerminalProcessing);
        }
    }

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Converters = { new JsonStringEnumConverter(KebabCaseNamingPolicy.Instance) },
    };

    private sealed class KebabCaseNamingPolicy : JsonNamingPolicy
    {
        public static readonly KebabCaseNamingPolicy Instance = new();

        public override string ConvertName(string name)
        {
            var result = new StringBuilder(name.Length + 4);
            foreach (var c in name)
            {
                if (char.IsUpper(c) && result.Length > 0)
                {
                    result.Append('-');
                }

                result.Append(char.ToLowerInvariant(c));
            }

            return result.ToString();
        }
    }

    private const int StdOutputHandle = -11;

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetStdHandle(int nStdHandle);

    [DllImport("kernel32.dll")]
    private static extern bool GetConsoleMode(IntPtr handle, out uint mode);

    [DllImport("kernel32.dll")]
    private static extern bool SetConsoleMode(IntPtr handle, uint mode);
}
