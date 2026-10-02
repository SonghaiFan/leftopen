namespace LeftOpen.Core;

public enum Category
{
    Project,
    Application,
    SystemService,
    Unknown,
}

public enum Confidence
{
    High,
    Medium,
    None,
}

public enum Scope
{
    Local,
    Lan,
}

/// <summary>A single process listening on a single TCP port, with all bound addresses.</summary>
public sealed record Listener(
    int Pid,
    string Command,
    string? OwnerSid,
    string? OwnerName,
    int Port,
    IReadOnlyList<string> Addresses);

/// <summary>Process-table evidence for one PID, independent of any listener.</summary>
public sealed record ProcessFact(
    int Pid,
    int? ParentPid,
    string Command,
    string? ExecutablePath,
    string? CommandLine,
    DateTime? StartTime)
{
    public static ProcessFact Unknown(int pid) => new(pid, null, "unknown", null, null, null);
}

/// <summary>A detected project root that a process's working directory lives inside.</summary>
public sealed record ProjectMarkerFact(
    string Name,
    string Root,
    string Source,
    string MarkerPath);

/// <summary>An installed Windows application (Program Files / WindowsApps / per-user Programs).</summary>
public sealed record InstalledAppFact(
    string Name,
    string Path,
    int SourcePid,
    bool DirectProcess);

public sealed record ListenerFact(
    int Port,
    IReadOnlyList<string> Addresses,
    Scope Scope);

public sealed record ActivityProcessFact(
    int Pid,
    int? ParentPid,
    string Command,
    string? ExecutablePath,
    string? CommandLine,
    DateTime? StartTime,
    string? OwnerSid,
    string? OwnerName,
    string? Cwd);

public sealed record ActivityFacts(
    ListenerFact Listener,
    ActivityProcessFact Process,
    IReadOnlyList<ProcessFact> ParentChain,
    ProjectMarkerFact? ProjectMarker,
    InstalledAppFact? InstalledApp);

public sealed record OwnerInference(
    string Label,
    Category Category,
    Confidence Confidence,
    string Reason);

public sealed record Activity(
    ActivityFacts Facts,
    OwnerInference Inference);

public sealed record ScanResult(
    IReadOnlyList<Activity> Activities,
    IReadOnlyList<string> Limitations);
