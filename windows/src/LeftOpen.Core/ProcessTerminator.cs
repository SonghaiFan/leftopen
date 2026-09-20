using System.Diagnostics;
using System.Runtime.InteropServices;

namespace LeftOpen.Core;

/// <summary>
/// The Windows stand-in for leftopen's SIGTERM-only rule. Windows has no per-process
/// signal, so the gentle ladder is: (1) WM_CLOSE to the process's own window, then
/// (2) console Ctrl+C followed by Ctrl+Break, delivered as if the user pressed the
/// keys in the terminal hosting the process. Ctrl+Break matters because processes
/// started in a new process group (e.g. PowerShell Start-Process) ignore Ctrl+C,
/// while Ctrl+Break always gets through. Force-kill (taskkill /F, Process.Kill) is
/// never used; a process that ignores everything is reported honestly instead.
/// </summary>
public static class ProcessTerminator
{
    private const uint CtrlCEvent = 0;
    private const uint CtrlBreakEvent = 1;
    private const uint AttachParentProcess = unchecked(uint.MaxValue);

    /// <summary>Sends every gentle close signal we have. True when something was actually delivered.</summary>
    public static bool TrySendGentleClose(int pid)
    {
        var delivered = false;

        try
        {
            using var process = Process.GetProcessById(pid);
            if (!process.HasExited && process.MainWindowHandle != 0)
            {
                process.CloseMainWindow();
                delivered = true;
            }
        }
        catch (ArgumentException)
        {
            // Process already exited — nothing to signal, but also nothing left to do.
            return true;
        }
        catch (Exception ex) when (ex is InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            // Exited between enumeration and access, or details unavailable —
            // the console path may still work.
        }

        if (TrySendConsoleCtrl(pid))
        {
            delivered = true;
        }

        return delivered;
    }

    private static bool TrySendConsoleCtrl(int pid)
    {
        var hadConsole = GetConsoleWindow() != IntPtr.Zero;
        if (hadConsole && !FreeConsole())
        {
            return false;
        }

        if (!AttachConsole((uint)pid))
        {
            if (hadConsole)
            {
                AttachConsole(AttachParentProcess);
            }

            return false;
        }

        try
        {
            // A real handler that returns TRUE suppresses the default action for
            // BOTH Ctrl+C and Ctrl+Break (the NULL-handler "ignore mode" only
            // covers Ctrl+C), so the events we generate for that console do not
            // terminate leftopen itself.
            SetConsoleCtrlHandler(KeepAliveHandler, true);
            GenerateConsoleCtrlEvent(CtrlCEvent, 0);
            GenerateConsoleCtrlEvent(CtrlBreakEvent, 0);
            Thread.Sleep(100);
        }
        finally
        {
            FreeConsole();
            SetConsoleCtrlHandler(KeepAliveHandler, false);
            if (hadConsole)
            {
                AttachConsole(AttachParentProcess);
            }
        }

        return true;
    }

    private delegate bool ConsoleCtrlDelegate(uint ctrlType);

    private static readonly ConsoleCtrlDelegate KeepAliveHandler = _ => true;

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetConsoleWindow();

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool FreeConsole();

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AttachConsole(uint processId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetConsoleCtrlHandler(ConsoleCtrlDelegate? handlerRoutine, bool add);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GenerateConsoleCtrlEvent(uint ctrlEvent, uint processGroup);
}
