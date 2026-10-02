using System.Diagnostics;

namespace LeftOpen.Core;

public sealed record CloseOptions(int Port, int? Pid, string? CurrentUserSid, int CurrentPid);

public sealed record ClosePlan(
    int Port,
    int Pid,
    string OwnerSid,
    string ExecutablePath,
    DateTime StartTime,
    Activity Activity,
    IReadOnlyList<int> OtherPorts,
    IReadOnlyList<int> PeerPids);

public sealed record CloseResult(
    bool TargetStoppedListening,
    bool PortFree,
    IReadOnlyList<int> RemainingPids,
    bool SignalsDelivered = true);

public sealed class CloseRefusedException(string message) : Exception(message);

/// <summary>
/// Leftopen's three-stage close, ported to Windows: prepare a plan from a snapshot,
/// re-verify identity (PID still on the port, no new peers, same owner SID, same
/// executable, same start time — guarding against PID reuse) immediately before
/// signalling, then send the gentle close and poll for the port to be released.
/// Refusals throw <see cref="CloseRefusedException"/> and never signal anything;
/// a stubborn process is reported honestly rather than force-killed.
/// </summary>
public sealed class CloseService
{
    private readonly Func<ScanResult> _scan;
    private readonly Func<IReadOnlyList<Listener>> _listeners;
    private readonly Func<int, DateTime?> _startTime;
    private readonly Func<int, bool> _signal;
    private readonly Func<int, Task> _wait;

    public CloseService(
        Func<ScanResult>? scan = null,
        Func<IReadOnlyList<Listener>>? listeners = null,
        Func<int, DateTime?>? startTime = null,
        Func<int, bool>? signal = null,
        Func<int, Task>? wait = null)
    {
        _scan = scan ?? Scanner.ScanActivities;
        _listeners = listeners ?? Scanner.ScanListeners;
        _startTime = startTime ?? ProcessTable.QueryStartTime;
        _signal = signal ?? ProcessTerminator.TrySendGentleClose;
        _wait = wait ?? (ms => Task.Delay(ms));
    }

    /// <summary>
    /// Non-throwing variant of the protection rules, so the panel can decide which
    /// rows are closable and why, using the exact same policy as SelectCloseTarget.
    /// </summary>
    public static bool DescribeClosability(Activity activity, string? currentUserSid, int currentPid, out string? reason)
    {
        var target = activity.Facts.Process;
        reason = null;

        if (target.Pid <= 4 || target.Pid == currentPid)
        {
            reason = "PID is a system process or LeftOpen itself.";
            return false;
        }

        if (target.OwnerSid == null)
        {
            reason = "Owner could not be verified (elevated or protected process).";
            return false;
        }

        if (!string.Equals(target.OwnerSid, currentUserSid, StringComparison.Ordinal))
        {
            reason = "Belongs to another user or SYSTEM.";
            return false;
        }

        if (string.IsNullOrEmpty(target.ExecutablePath))
        {
            reason = "Executable path could not be verified.";
            return false;
        }

        if (Ownership.IsSystemExecutable(target.ExecutablePath))
        {
            reason = "Runs from an operating-system executable location.";
            return false;
        }

        if (activity.Facts.ProjectMarker == null &&
            activity.Facts.InstalledApp is { DirectProcess: true } app &&
            !Ownership.IsRuntimeHost(target.ExecutablePath))
        {
            reason = $"Is the installed application \"{app.Name}\"; closing it could disrupt the app.";
            return false;
        }

        return true;
    }

    public (Activity Activity, IReadOnlyList<int> OtherPorts, IReadOnlyList<int> PeerPids) SelectCloseTarget(
        IReadOnlyList<Activity> activities,
        CloseOptions options)
    {
        var matches = activities.Where(activity => activity.Facts.Listener.Port == options.Port).ToList();
        if (matches.Count == 0)
        {
            throw new CloseRefusedException($"Nothing is listening on port {options.Port}.");
        }

        var pids = matches.Select(activity => activity.Facts.Process.Pid).Distinct().ToList();
        if (options.Pid == null && pids.Count > 1)
        {
            throw new CloseRefusedException($"Port {options.Port} has multiple owning PIDs ({string.Join(", ", pids)}); specify --pid.");
        }

        var pid = options.Pid ?? pids[0];
        var activity = matches.FirstOrDefault(candidate => candidate.Facts.Process.Pid == pid);
        if (activity == null)
        {
            throw new CloseRefusedException($"PID {pid} is not listening on port {options.Port}.");
        }

        var target = activity.Facts.Process;
        if (pid <= 4 || pid == options.CurrentPid)
        {
            throw new CloseRefusedException($"PID {pid} is protected.");
        }

        if (target.OwnerSid == null)
        {
            throw new CloseRefusedException($"PID {pid} has no verified owner SID; refusing to close it.");
        }

        if (options.CurrentUserSid == null)
        {
            throw new CloseRefusedException("LeftOpen cannot verify the current user's SID on this system.");
        }

        if (!string.Equals(target.OwnerSid, options.CurrentUserSid, StringComparison.Ordinal))
        {
            throw new CloseRefusedException($"PID {pid} belongs to another user or SYSTEM; refusing to close it.");
        }

        if (string.IsNullOrEmpty(target.ExecutablePath))
        {
            throw new CloseRefusedException($"PID {pid} has no verified executable path; refusing to close it.");
        }

        if (Ownership.IsSystemExecutable(target.ExecutablePath))
        {
            throw new CloseRefusedException($"PID {pid} runs from an operating-system executable location; refusing to close it.");
        }

        if (activity.Facts.ProjectMarker == null &&
            activity.Facts.InstalledApp is { DirectProcess: true } app &&
            !Ownership.IsRuntimeHost(target.ExecutablePath))
        {
            throw new CloseRefusedException(
                $"PID {pid} is the installed application \"{app.Name}\" ({app.Path}); closing it could disrupt the app.");
        }

        var otherPorts = activities
            .Where(candidate => candidate.Facts.Process.Pid == pid && candidate.Facts.Listener.Port != options.Port)
            .Select(candidate => candidate.Facts.Listener.Port)
            .Distinct()
            .OrderBy(port => port)
            .ToList();

        return (activity, otherPorts, pids.Where(candidate => candidate != pid).ToList());
    }

    public async Task<ClosePlan> PrepareCloseAsync(CloseOptions options)
    {
        var snapshot = await Task.Run(_scan);
        var (activity, otherPorts, peerPids) = SelectCloseTarget(snapshot.Activities, options);
        var target = activity.Facts.Process;

        var startTime = _startTime(target.Pid);
        if (startTime == null)
        {
            throw new CloseRefusedException($"PID {target.Pid} has no verified start time; refusing to close it.");
        }

        return new ClosePlan(
            options.Port,
            target.Pid,
            target.OwnerSid!,
            target.ExecutablePath!,
            startTime.Value,
            activity,
            otherPorts,
            peerPids);
    }

    public void VerifyCloseTarget(ClosePlan plan, IReadOnlyList<Activity> activities, DateTime? startTime)
    {
        var matches = activities.Where(activity => activity.Facts.Listener.Port == plan.Port).ToList();
        var matching = matches.FirstOrDefault(activity => activity.Facts.Process.Pid == plan.Pid);
        if (matching == null)
        {
            throw new CloseRefusedException($"PID {plan.Pid} no longer listens on port {plan.Port}; nothing was signalled.");
        }

        var freshPeers = matches
            .Select(activity => activity.Facts.Process.Pid)
            .Where(pid => pid != plan.Pid)
            .Distinct()
            .ToList();
        if (freshPeers.Any(pid => !plan.PeerPids.Contains(pid)))
        {
            throw new CloseRefusedException($"Port {plan.Port} acquired a new owning PID; nothing was signalled.");
        }

        var target = matching.Facts.Process;
        if (startTime == null ||
            startTime.Value != plan.StartTime ||
            !string.Equals(target.OwnerSid, plan.OwnerSid, StringComparison.Ordinal) ||
            !string.Equals(target.ExecutablePath, plan.ExecutablePath, StringComparison.OrdinalIgnoreCase))
        {
            throw new CloseRefusedException($"PID {plan.Pid} changed identity since the preview; nothing was signalled.");
        }

        if (Ownership.IsSystemExecutable(target.ExecutablePath) ||
            (matching.Facts.ProjectMarker == null &&
             matching.Facts.InstalledApp is { DirectProcess: true } freshApp &&
             !Ownership.IsRuntimeHost(target.ExecutablePath)))
        {
            throw new CloseRefusedException($"PID {plan.Pid} is now a protected process; nothing was signalled.");
        }
    }

    public async Task<CloseResult> ExecuteCloseAsync(ClosePlan plan)
    {
        var fresh = await Task.Run(_scan);
        var startTime = _startTime(plan.Pid);
        VerifyCloseTarget(plan, fresh.Activities, startTime);

        var delivered = _signal(plan.Pid);

        var latest = new List<Listener>();
        for (var attempt = 0; attempt < 10; attempt++)
        {
            await _wait(500);
            latest = _listeners().Where(listener => listener.Port == plan.Port).ToList();
            if (latest.All(listener => listener.Pid != plan.Pid))
            {
                break;
            }
        }

        var remainingPids = latest.Select(listener => listener.Pid).Distinct().ToList();
        return new CloseResult(
            TargetStoppedListening: !remainingPids.Contains(plan.Pid),
            PortFree: remainingPids.Count == 0,
            RemainingPids: remainingPids,
            SignalsDelivered: delivered);
    }
}
