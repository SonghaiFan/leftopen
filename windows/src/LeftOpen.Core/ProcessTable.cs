using System.Diagnostics;
using System.Management;
using System.Runtime.InteropServices;

namespace LeftOpen.Core;

/// <summary>
/// Collects the full process table in one WMI query (pid, parent pid, executable path,
/// command line, start time) — the Windows stand-in for leftopen's <c>ps</c> pass.
/// </summary>
public static class ProcessTable
{
    public static IReadOnlyDictionary<int, ProcessFact> Snapshot(out string? limitation)
    {
        try
        {
            var table = new Dictionary<int, ProcessFact>();
            using var searcher = new ManagementObjectSearcher(
                "SELECT ProcessId, ParentProcessId, Name, ExecutablePath, CommandLine, CreationDate FROM Win32_Process");
            foreach (var mo in searcher.Get().Cast<ManagementObject>())
            {
                var pid = Convert.ToInt32(mo["ProcessId"]);
                if (pid <= 0)
                {
                    continue;
                }

                var parentPid = Convert.ToInt32(mo["ParentProcessId"]);
                var name = mo["Name"]?.ToString() ?? "unknown";
                var executablePath = mo["ExecutablePath"]?.ToString();
                var commandLine = mo["CommandLine"]?.ToString();
                var startTime = ParseCreationDate(mo["CreationDate"]?.ToString());

                table[pid] = new ProcessFact(
                    pid,
                    parentPid > 0 ? parentPid : null,
                    name,
                    executablePath,
                    commandLine,
                    startTime);
            }

            limitation = null;
            return table;
        }
        catch (Exception ex) when (ex is ManagementException or COMException or UnauthorizedAccessException)
        {
            limitation = "The process table was unavailable, so parent-process evidence could not be collected.";
            return new Dictionary<int, ProcessFact>();
        }
    }

    /// <summary>Reads the authoritative start time for one PID straight from the OS (WMI snapshot may be stale).</summary>
    public static DateTime? QueryStartTime(int pid)
    {
        try
        {
            using var process = Process.GetProcessById(pid);
            return process.StartTime;
        }
        catch
        {
            return null;
        }
    }

    private static DateTime? ParseCreationDate(string? dmtf)
    {
        if (string.IsNullOrEmpty(dmtf))
        {
            return null;
        }

        try
        {
            return ManagementDateTimeConverter.ToDateTime(dmtf);
        }
        catch
        {
            return null;
        }
    }
}
