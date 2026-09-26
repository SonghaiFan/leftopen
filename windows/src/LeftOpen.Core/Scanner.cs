namespace LeftOpen.Core;

/// <summary>
/// Orchestrates one on-demand scan: TCP listeners → process facts (WMI) → working
/// directories (PEB) → project markers, then assembles explainable activities.
/// Nothing here polls or caches — each call is a fresh snapshot, matching leftopen's
/// "scan only when the panel opens" philosophy.
/// </summary>
public static class Scanner
{
    public static IReadOnlyList<Listener> ScanListeners()
    {
        var rows = TcpTable.GetListeners();
        var commandByPid = new Dictionary<int, string>();
        var sidByPid = new Dictionary<int, (string? Sid, string? Name)>();
        var byKey = new Dictionary<(int Pid, int Port), Listener>();

        foreach (var row in rows.OrderBy(row => row.Port).ThenBy(row => row.Pid))
        {
            if (!commandByPid.TryGetValue(row.Pid, out var command))
            {
                command = ResolveCommand(row.Pid);
                commandByPid[row.Pid] = command;
            }

            if (!sidByPid.TryGetValue(row.Pid, out var owner))
            {
                owner = ResolveOwner(row.Pid);
                sidByPid[row.Pid] = owner;
            }

            var key = (row.Pid, row.Port);
            if (byKey.TryGetValue(key, out var existing))
            {
                if (!existing.Addresses.Contains(row.Address))
                {
                    byKey[key] = existing with { Addresses = [.. existing.Addresses, row.Address] };
                }

                continue;
            }

            byKey[key] = new Listener(
                row.Pid,
                command,
                owner.Sid,
                owner.Name,
                row.Port,
                [row.Address]);
        }

        return byKey.Values
            .OrderBy(listener => listener.Port)
            .ThenBy(listener => listener.Pid)
            .ToList();
    }

    public static ScanResult ScanActivities()
    {
        var listeners = ScanListeners();
        var limitations = new List<string>();

        var table = ProcessTable.Snapshot(out var tableLimitation);
        if (tableLimitation != null)
        {
            limitations.Add(tableLimitation);
        }

        var cwdByPid = new Dictionary<int, string?>();
        var unreadablePids = new List<int>();
        foreach (var pid in listeners.Select(listener => listener.Pid).Distinct())
        {
            var cwd = ProcessCwdReader.TryReadCwd(pid);
            if (cwd == null)
            {
                unreadablePids.Add(pid);
            }

            cwdByPid[pid] = cwd;
        }

        if (unreadablePids.Count > 0)
        {
            limitations.Add(
                $"Working directories could not be read for {unreadablePids.Count} PID(s) ({string.Join(", ", unreadablePids)}); " +
                "project ownership for them is unavailable.");
        }

        var projectByCwd = new Dictionary<string, ProjectMarkerFact?>(StringComparer.OrdinalIgnoreCase);
        foreach (var cwd in cwdByPid.Values.Where(value => !string.IsNullOrEmpty(value)).Distinct(StringComparer.OrdinalIgnoreCase))
        {
            projectByCwd[cwd!] = ProjectDetector.FindProject(cwd);
        }

        var activities = new List<Activity>();
        foreach (var listener in listeners)
        {
            table.TryGetValue(listener.Pid, out var tableFact);
            var process = new ProcessFact(
                listener.Pid,
                tableFact?.ParentPid,
                tableFact?.Command ?? listener.Command,
                tableFact?.ExecutablePath,
                tableFact?.CommandLine,
                tableFact?.StartTime);

            var cwd = cwdByPid.GetValueOrDefault(listener.Pid);
            var parentChain = Ownership.ParentChainFor(process, table);
            var projectMarker = cwd != null ? projectByCwd.GetValueOrDefault(cwd) : null;

            var parent = parentChain.FirstOrDefault();
            var installedApp = Ownership.InstalledAppFromPath(process.ExecutablePath, process.Pid, true)
                ?? Ownership.InstalledAppFromPath(parent?.ExecutablePath, parent?.Pid ?? process.Pid, false);

            var activityProcess = new ActivityProcessFact(
                process.Pid,
                process.ParentPid,
                process.Command,
                process.ExecutablePath,
                process.CommandLine,
                process.StartTime,
                listener.OwnerSid,
                listener.OwnerName,
                cwd);

            var facts = new ActivityFacts(
                new ListenerFact(listener.Port, listener.Addresses, Ownership.ListenerScope(listener.Addresses)),
                activityProcess,
                parentChain,
                projectMarker,
                installedApp);

            activities.Add(new Activity(facts, Ownership.Infer(facts)));
        }

        return new ScanResult(activities, limitations);
    }

    private static string ResolveCommand(int pid)
    {
        try
        {
            using var process = System.Diagnostics.Process.GetProcessById(pid);
            return string.IsNullOrEmpty(process.ProcessName) ? "unknown" : process.ProcessName;
        }
        catch
        {
            return "unknown";
        }
    }

    private static (string? Sid, string? Name) ResolveOwner(int pid)
    {
        var sid = ProcessIdentity.GetOwnerSid(pid);
        return (sid, ProcessIdentity.ResolveOwnerName(sid));
    }
}
