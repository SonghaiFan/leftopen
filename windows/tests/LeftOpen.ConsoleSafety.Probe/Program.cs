using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using LeftOpen.Core;

// Runs separately from testhost: console attachment/handlers are process-global.
internal static class Program
{
    private delegate bool Handler(uint kind);
    private static Handler? _handler; // Root the native callback for the process lifetime.
    private static string Exe => Environment.ProcessPath!;

    private static int Main(string[] args)
    {
        if (!OperatingSystem.IsWindows())
        {
            Console.Error.WriteLine("Requires real Windows; no test was run.");
            return 2;
        }
        if (args.Length > 0 && args[0] == "worker")
            return Worker(args[1], args[2], args.Length > 3);

        var dir = Path.Combine(Path.GetTempPath(), "leftopen-console-" + Guid.NewGuid());
        Directory.CreateDirectory(dir);
        Console.WriteLine("Probe markers: " + dir);
        var children = new List<Process>();
        try
        {
            FreeConsole(); // Never test a broadcast in the user's original console.
            Require(AllocConsole(), "AllocConsole");
            _handler = _ => true;
            Require(SetConsoleCtrlHandler(_handler, true), "host handler");
            children.Add(Spawn(dir, "shared", false, false));
            children.Add(Spawn(dir, "group", true, true));
            WaitFor(() => new[] { "shared", "group", "descendant" }
                .All(name => File.Exists(Path.Combine(dir, name + ".ready"))));
            var descendantPid = int.Parse(File.ReadAllText(Path.Combine(dir, "descendant.ready")));
            children.Add(Process.GetProcessById(descendantPid));
            var expected = children.Select(p => (uint)p.Id).Append((uint)Environment.ProcessId).ToHashSet();
            var members = new uint[16];
            var count = GetConsoleProcessList(members, (uint)members.Length);
            Require(count == expected.Count && members.Take((int)count).ToHashSet().SetEquals(expected),
                "Dedicated console contains only the four controlled probe processes");

            foreach (var child in children)
                Require(!ProcessTerminator.TrySendGentleClose(child.Id), "console close must be refused");
            Thread.Sleep(300);
            Require(!Directory.EnumerateFiles(dir, "*.event").Any(), "refusal delivers no events");
            Require(children.All(p => !p.HasExited), "all services survive refusal");

            // Handlers enable Ctrl+C explicitly, even in CREATE_NEW_PROCESS_GROUP.
            Require(GenerateConsoleCtrlEvent(0, 0), "Ctrl+C broadcast");
            WaitFor(() => children.All(p => Event(dir, p.Id, 0)));
            Require(GenerateConsoleCtrlEvent(1, 0), "Ctrl+Break broadcast");
            WaitFor(() => children.All(p => Event(dir, p.Id, 1)));
            Console.WriteLine("PASS: both broadcasts reach all three controlled recipients.");
            ClearEvents(dir);

            Require(GenerateConsoleCtrlEvent(0, (uint)children[1].Id), "Ctrl+C nonzero group call");
            Thread.Sleep(500);
            Require(!Directory.EnumerateFiles(dir, "*.event").Any(), "Ctrl+C does not target a group");
            Require(GenerateConsoleCtrlEvent(1, (uint)children[1].Id), "Ctrl+Break group call");
            WaitFor(() => Event(dir, children[1].Id, 1) && Event(dir, descendantPid, 1));
            Thread.Sleep(300);
            Require(!Event(dir, children[0].Id, 1), "other group does not receive targeted break");
            Console.WriteLine("PASS: targeted Ctrl+Break also reaches the group's descendant, not just the root PID.");
            ClearEvents(dir);
            foreach (var child in children)
                Require(!ProcessTerminator.TrySendGentleClose(child.Id), "close still refused after group events");
            Thread.Sleep(300);
            Require(!Directory.EnumerateFiles(dir, "*.event").Any() && children.All(p => !p.HasExited),
                "production path leaves every controlled service running without events");
            Console.WriteLine("PASS: production console closes refused; target, sibling and group descendant remain alive.");
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex);
            return 1;
        }
        finally
        {
            File.WriteAllText(Path.Combine(dir, "stop"), "stop");
            foreach (var child in children)
            {
                if (!child.WaitForExit(5000))
                    Console.Error.WriteLine($"Probe PID {child.Id} did not exit promptly; it has a 30s timeout.");
                child.Dispose();
            }
            FreeConsole();
            // Keep temporary marker files for diagnosis.
        }
    }

    private static int Worker(string dir, string name, bool spawnDescendant)
    {
        _handler = kind =>
        {
            if (kind is 0 or 1)
            {
                try { File.WriteAllText(Path.Combine(dir, $"{Environment.ProcessId}.{kind}.event"), "received"); }
                catch { /* Host timeout will fail the test if logging fails. */ }
            }
            return true;
        };
        Require(SetConsoleCtrlHandler(null, false), "enable Ctrl+C");
        Require(SetConsoleCtrlHandler(_handler, true), "worker handler");
        using var descendant = spawnDescendant ? Spawn(dir, "descendant", false, false) : null;
        File.WriteAllText(Path.Combine(dir, name + ".ready"), Environment.ProcessId.ToString());
        var timeout = Stopwatch.StartNew();
        while (!File.Exists(Path.Combine(dir, "stop")) && timeout.Elapsed < TimeSpan.FromSeconds(30))
            Thread.Sleep(50);
        descendant?.WaitForExit(5000);
        return 0;
    }

    private static Process Spawn(string dir, string name, bool newGroup, bool descendant)
    {
        var info = new StartupInfo { cb = Marshal.SizeOf<StartupInfo>() };
        var command = new StringBuilder($"\"{Exe}\" worker \"{dir}\" {name}" + (descendant ? " parent" : ""));
        Require(CreateProcess(Exe, command, IntPtr.Zero, IntPtr.Zero, false,
            newGroup ? 0x00000200u : 0u, IntPtr.Zero, null, ref info, out var process), "CreateProcess");
        try { return Process.GetProcessById((int)process.pid); }
        finally { CloseHandle(process.thread); CloseHandle(process.process); }
    }

    private static bool Event(string dir, int pid, uint kind) => File.Exists(Path.Combine(dir, $"{pid}.{kind}.event"));
    private static void ClearEvents(string dir)
    {
        foreach (var file in Directory.EnumerateFiles(dir, "*.event")) File.Delete(file);
    }
    private static void WaitFor(Func<bool> condition)
    {
        var timeout = Stopwatch.StartNew();
        while (!condition())
        {
            if (timeout.Elapsed > TimeSpan.FromSeconds(5)) throw new Exception("Probe timed out waiting for ready/event files.");
            Thread.Sleep(25);
        }
    }
    private static void Require(bool success, string message)
    {
        if (!success) throw new Exception(message + $" failed (last error {Marshal.GetLastWin32Error()}).");
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct StartupInfo
    {
        public int cb;
        public string? reserved, desktop, title;
        public uint x, y, width, height, xChars, yChars, fill, flags;
        public ushort show, reservedBytes;
        public IntPtr reservedPtr, input, output, error;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInfo { public IntPtr process, thread; public uint pid, tid; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateProcess(string app, StringBuilder command, IntPtr pa, IntPtr ta,
        bool inherit, uint flags, IntPtr environment, string? cwd, ref StartupInfo startup, out ProcessInfo process);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")] private static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool AllocConsole();
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetConsoleCtrlHandler(Handler? handler, bool add);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GenerateConsoleCtrlEvent(uint kind, uint group);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern uint GetConsoleProcessList(uint[] processes, uint length);
}
