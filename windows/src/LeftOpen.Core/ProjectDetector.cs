using System.Text.Json;
using System.Text.RegularExpressions;

namespace LeftOpen.Core;

/// <summary>
/// Detects the project a working directory belongs to by walking up until a marker
/// (.git / package.json / pyproject.toml / Cargo.toml / go.mod) is found in a
/// directory that passes the rejection rules — a faithful port of leftopen's
/// findProject + projectPathRejectionReason, adapted to Windows tree layouts.
/// </summary>
public static partial class ProjectDetector
{
    private static readonly (string Marker, string Source)[] Markers =
    [
        (".git", "git"),
        ("package.json", "package.json"),
        ("pyproject.toml", "pyproject.toml"),
        ("Cargo.toml", "Cargo.toml"),
        ("go.mod", "go.mod"),
    ];

    public sealed record RejectionContext(
        string Home,
        IReadOnlyList<string> OsManagedRoots,
        IReadOnlyList<string> UserManagedRoots);

    public static RejectionContext DefaultContext()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var osManaged = new List<string>();
        var userManaged = new List<string>();

        AddIfPresent(osManaged, Environment.GetFolderPath(Environment.SpecialFolder.Windows));
        AddIfPresent(osManaged, Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles));
        AddIfPresent(osManaged, Environment.GetEnvironmentVariable("ProgramFiles(x86)"));
        AddIfPresent(osManaged, Environment.GetEnvironmentVariable("ProgramW6432"));
        AddIfPresent(osManaged, Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData));

        // Per-user install and cache trees: npm globals, per-user app installs, etc.
        AddIfPresent(userManaged, Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData));
        AddIfPresent(userManaged, Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData));

        return new RejectionContext(home, osManaged, userManaged);
    }

    public static ProjectMarkerFact? FindProject(string? cwd, RejectionContext? context = null)
    {
        context ??= DefaultContext();

        if (string.IsNullOrEmpty(cwd))
        {
            return null;
        }

        // PEB-derived cwd strings carry a trailing separator; drop it so name
        // fallbacks and marker paths stay clean.
        var directory = Path.GetFullPath(cwd)
            .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        while (true)
        {
            foreach (var (marker, source) in Markers)
            {
                var markerPath = Path.Combine(directory, marker);
                if (!File.Exists(markerPath) && !Directory.Exists(markerPath))
                {
                    continue;
                }

                if (ProjectPathRejectionReason(directory, cwd, context) != null)
                {
                    continue;
                }

                var name = source switch
                {
                    "package.json" => PackageName(directory) ?? Path.GetFileName(directory),
                    "pyproject.toml" => PyprojectName(directory) ?? Path.GetFileName(directory),
                    _ => Path.GetFileName(directory),
                };

                if (string.IsNullOrEmpty(name))
                {
                    name = directory;
                }

                return new ProjectMarkerFact(name, directory, source, markerPath);
            }

            var parent = Path.GetDirectoryName(directory.TrimEnd(Path.DirectorySeparatorChar));
            if (string.IsNullOrEmpty(parent) || string.Equals(parent, directory, StringComparison.OrdinalIgnoreCase))
            {
                return null;
            }

            directory = parent;
        }
    }

    /// <summary>Returns why a candidate marker root must be ignored, or null when it is acceptable.</summary>
    public static string? ProjectPathRejectionReason(string root, string cwd, RejectionContext context)
    {
        var resolvedRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var resolvedCwd = Path.GetFullPath(cwd);
        var segments = SplitSegments(resolvedRoot);

        if (context.OsManagedRoots.Any(managed => IsWithin(resolvedRoot, managed)))
        {
            return "the marker is inside an installed or operating-system-managed tree";
        }

        if (context.UserManagedRoots.Any(managed => IsWithin(resolvedRoot, managed)))
        {
            return "the marker is inside a per-user application-data tree used for installs and caches";
        }

        var home = Path.GetFullPath(context.Home).TrimEnd(Path.DirectorySeparatorChar);
        if (IsWithin(resolvedRoot, home))
        {
            if (string.Equals(resolvedRoot, home, StringComparison.OrdinalIgnoreCase))
            {
                return "the marker root is the user home rather than a specific project directory";
            }

            var relative = Path.GetRelativePath(home, resolvedRoot);
            var firstSegment = SplitSegments(relative).FirstOrDefault();
            if (firstSegment != null && firstSegment.StartsWith('.'))
            {
                return "the marker is inside a hidden per-user tool-data tree";
            }
        }

        if (segments.Any(segment => segment.Equals("node_modules", StringComparison.OrdinalIgnoreCase)))
        {
            return "the marker is inside a dependency tree";
        }

        if (segments.Any(segment =>
                segment.Equals("cache", StringComparison.OrdinalIgnoreCase) ||
                segment.Equals("caches", StringComparison.OrdinalIgnoreCase) ||
                segment.Equals(".cache", StringComparison.OrdinalIgnoreCase)))
        {
            return "the marker is inside a cache tree";
        }

        if (!IsWithin(resolvedCwd, resolvedRoot))
        {
            return "the working directory is not inside the marker root";
        }

        return null;
    }

    public static bool IsWithin(string candidate, string parent)
    {
        var relative = Path.GetRelativePath(
            parent.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
            candidate.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
        return relative == "." || (!relative.StartsWith("..") && !Path.IsPathRooted(relative));
    }

    internal static string? PackageName(string directory)
    {
        try
        {
            using var document = JsonDocument.Parse(File.ReadAllText(Path.Combine(directory, "package.json")));
            if (document.RootElement.ValueKind == JsonValueKind.Object &&
                document.RootElement.TryGetProperty("name", out var name) &&
                name.ValueKind == JsonValueKind.String)
            {
                var value = name.GetString()?.Trim();
                return string.IsNullOrEmpty(value) ? null : value;
            }
        }
        catch (Exception ex) when (ex is JsonException or IOException or UnauthorizedAccessException)
        {
        }

        return null;
    }

    internal static string? PyprojectName(string directory)
    {
        try
        {
            var contents = File.ReadAllText(Path.Combine(directory, "pyproject.toml"));
            return PyprojectProjectNameRegex().Match(contents) is { Success: true } match
                ? match.Groups["name"].Value.Trim()
                : null;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    private static void AddIfPresent(List<string> roots, string? path)
    {
        if (!string.IsNullOrEmpty(path))
        {
            roots.Add(path);
        }
    }

    private static List<string> SplitSegments(string path)
    {
        // Accept both separators and keep drive letters out of the segment list.
        return path.Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries)
            .Where(segment => !segment.EndsWith(':'))
            .ToList();
    }

    [GeneratedRegex(@"\[project\][^\[]*?^\s*name\s*=\s*[""'](?<name>[^""']+)[""']", RegexOptions.Multiline | RegexOptions.ExplicitCapture)]
    private static partial Regex PyprojectProjectNameRegex();
}
