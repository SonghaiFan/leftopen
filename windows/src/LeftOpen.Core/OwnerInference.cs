using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;

namespace LeftOpen.Core;

/// <summary>
/// Turns collected facts into an owner inference — project > installed application >
/// system service > unknown — with a confidence and a human-readable reason, mirroring
/// leftopen's inferOwner.
/// </summary>
public static class Ownership
{
    /// <summary>
    /// Shared language runtimes that live in Program Files but are not applications
    /// themselves (Windows puts node/python/etc. there, unlike macOS homebrew paths).
    /// Closing them does not "disrupt an app", so they stay eligible for gentle close.
    /// </summary>
    private static readonly HashSet<string> RuntimeHostNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "node", "deno", "bun", "npm",
        "python", "pythonw", "python3", "py",
        "dotnet", "java", "javaw", "ruby", "php", "perl",
        "go", "air", "cargo", "watchexec", "gradle",
    };

    public static bool IsRuntimeHost(string? executablePath) =>
        !string.IsNullOrEmpty(executablePath) &&
        RuntimeHostNames.Contains(Path.GetFileNameWithoutExtension(executablePath));

    public static string[] DefaultAppRoots()
    {
        var roots = new List<string>();
        Add(roots, Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles));
        Add(roots, Environment.GetEnvironmentVariable("ProgramFiles(x86)"));
        Add(roots, Environment.GetEnvironmentVariable("ProgramW6432"));
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (!string.IsNullOrEmpty(local))
        {
            roots.Add(Path.Combine(local, "Programs"));
            roots.Add(Path.Combine(local, "Microsoft", "WindowsApps"));
        }

        return roots.ToArray();
    }

    public static string DefaultSystemRoot() => Environment.GetFolderPath(Environment.SpecialFolder.Windows);

    /// <summary>Detects an installed application from an executable path (equivalent of a macOS .app bundle).</summary>
    public static InstalledAppFact? InstalledAppFromPath(
        string? executablePath,
        int sourcePid,
        bool directProcess,
        IReadOnlyList<string>? appRoots = null)
    {
        if (string.IsNullOrEmpty(executablePath) || !Path.IsPathRooted(executablePath))
        {
            return null;
        }

        var roots = appRoots ?? DefaultAppRoots();
        var match = roots.FirstOrDefault(root => ProjectDetector.IsWithin(executablePath, root));
        if (match == null)
        {
            return null;
        }

        return new InstalledAppFact(AppDisplayName(executablePath), match, sourcePid, directProcess);
    }

    private static string AppDisplayName(string executablePath)
    {
        try
        {
            var info = FileVersionInfo.GetVersionInfo(executablePath);
            var description = info.FileDescription?.Trim();
            if (!string.IsNullOrEmpty(description))
            {
                return description;
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or COMException)
        {
        }

        return Path.GetFileNameWithoutExtension(executablePath);
    }

    public static bool IsSystemExecutable(string? executablePath, string? systemRoot = null)
    {
        if (string.IsNullOrEmpty(executablePath))
        {
            return false;
        }

        var root = systemRoot ?? DefaultSystemRoot();
        return !string.IsNullOrEmpty(root) && ProjectDetector.IsWithin(executablePath, root);
    }

    public static Scope ListenerScope(IReadOnlyList<string> addresses)
    {
        var loopback = addresses.All(address =>
        {
            var normalized = address.Trim('[', ']').ToLowerInvariant();
            return normalized is "127.0.0.1" or "::1" or "localhost";
        });
        return loopback ? Scope.Local : Scope.Lan;
    }

    public static IReadOnlyList<ProcessFact> ParentChainFor(ProcessFact process, IReadOnlyDictionary<int, ProcessFact> table)
    {
        var chain = new List<ProcessFact>();
        var seen = new HashSet<int> { process.Pid };
        var parentPid = process.ParentPid;

        while (parentPid is > 0 && !seen.Contains(parentPid.Value) && chain.Count < 16)
        {
            if (!table.TryGetValue(parentPid.Value, out var parent))
            {
                break;
            }

            seen.Add(parentPid.Value);
            chain.Add(parent);
            parentPid = parent.ParentPid;
        }

        return chain;
    }

    public static OwnerInference Infer(ActivityFacts facts)
    {
        if (facts.ProjectMarker is { } marker)
        {
            return new(
                marker.Name,
                Category.Project,
                Confidence.High,
                $"CWD is within a project root containing {marker.Source} at {marker.MarkerPath}.");
        }

        if (facts.InstalledApp is { } app)
        {
            return new(
                app.Name,
                Category.Application,
                app.DirectProcess ? Confidence.High : Confidence.Medium,
                app.DirectProcess
                    ? $"The executable is inside {app.Path}."
                    : $"Direct parent PID {app.SourcePid} runs inside {app.Path}.");
        }

        if (IsSystemExecutable(facts.Process.ExecutablePath))
        {
            return new(
                Path.GetFileName(facts.Process.ExecutablePath!),
                Category.SystemService,
                Confidence.High,
                $"The executable path {facts.Process.ExecutablePath} is in an operating-system-managed executable location.");
        }

        return new(
            "Unknown",
            Category.Unknown,
            Confidence.None,
            "No accepted project marker, installed application, or operating-system executable path established an owner.");
    }

    public static string CompactPath(string? inputPath)
    {
        if (string.IsNullOrEmpty(inputPath))
        {
            return "—";
        }

        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var full = Path.GetFullPath(inputPath);
        return full.StartsWith(home + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)
            ? "~" + full[home.Length..]
            : full;
    }

    private static void Add(List<string> roots, string? path)
    {
        if (!string.IsNullOrEmpty(path))
        {
            roots.Add(path);
        }
    }
}
