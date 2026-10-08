using System.Diagnostics;
using System.Runtime.InteropServices;

namespace LeftOpen.Core;

/// <summary>
/// Only posts WM_CLOSE to a window owned by the target PID. Console control events
/// are deliberately unsupported: Ctrl+C cannot target a group, and Ctrl+Break
/// targets a group (including descendants), not a verified individual PID.
/// LeftOpen did not create these processes and cannot prove their group scope.
/// </summary>
public static class ProcessTerminator
{
    public const string NoSafeCloseReason =
        "No reachable window owned by the target PID. Console Ctrl+C / Ctrl+Break " +
        "are disabled because their recipients cannot be restricted to the verified target; " +
        "they could stop other services sharing its console or process group.";

    /// <summary>True only if WM_CLOSE was posted, or the process already exited.</summary>
    public static bool TrySendGentleClose(int pid)
    {
        try
        {
            using var process = Process.GetProcessById(pid);
            if (process.HasExited)
            {
                return true;
            }

            var window = process.MainWindowHandle;
            // A console's visible window belongs to the console host, not the
            // service. Never close that host (or another PID's window).
            if (window == IntPtr.Zero ||
                GetWindowThreadProcessId(window, out var ownerPid) == 0 ||
                ownerPid != (uint)pid)
            {
                return false;
            }

            // Use the exact checked handle and report the native API result.
            return PostMessage(window, 0x0010 /* WM_CLOSE */, IntPtr.Zero, IntPtr.Zero);
        }
        catch (ArgumentException)
        {
            return true; // Target already exited.
        }
        catch (Exception ex) when (ex is InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            return false;
        }
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
}
