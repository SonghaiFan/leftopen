using LeftOpen.Core;

namespace LeftOpen.Core.Tests;

public class ProjectDetectorTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "leftopen-tests-" + Guid.NewGuid().ToString("N"));

    private ProjectDetector.RejectionContext Context(string home) => new(
        home,
        [Path.Combine(_root, "Windows"), Path.Combine(_root, "Program Files")],
        [Path.Combine(home, "AppData", "Local"), Path.Combine(home, "AppData", "Roaming")]);

    private string Dir(params string[] segments)
    {
        var path = Path.Combine(new[] { _root }.Concat(segments).ToArray());
        Directory.CreateDirectory(path);
        return path;
    }

    private static string File(string dir, string name, string contents = "")
    {
        var path = Path.Combine(dir, name);
        System.IO.File.WriteAllText(path, contents);
        return path;
    }

    [Fact]
    public void FindProject_WalksUpToGitMarker()
    {
        var project = Dir("code", "myapp");
        var deep = Dir("code", "myapp", "src");
        File(project, ".git");
        File(deep, "main.py");

        var home = Dir("home");
        var marker = ProjectDetector.FindProject(deep, Context(home));

        Assert.NotNull(marker);
        Assert.Equal("myapp", marker!.Name);
        Assert.Equal("git", marker.Source);
        Assert.Equal(Path.Combine(project, ".git"), marker.MarkerPath);
    }

    [Fact]
    public void FindProject_PrefersPackageName_OverDirectoryName()
    {
        var project = Dir("code", "ugly-folder-name");
        File(project, "package.json", """{ "name": "pretty-app", "version": "1.0.0" }""");

        var home = Dir("home");
        var marker = ProjectDetector.FindProject(project, Context(home));

        Assert.NotNull(marker);
        Assert.Equal("pretty-app", marker!.Name);
        Assert.Equal("package.json", marker.Source);
    }

    [Fact]
    public void FindProject_PrefersPyprojectName()
    {
        var project = Dir("code", "pyapp");
        File(project, "pyproject.toml", """
            [tool.poetry]
            name = "wrong-place"

            [project]
            name = "real-name"
            version = "0.1.0"
            """);

        var home = Dir("home");
        var marker = ProjectDetector.FindProject(project, Context(home));

        Assert.NotNull(marker);
        Assert.Equal("real-name", marker!.Name);
        Assert.Equal(Path.GetFullPath(project), Path.GetFullPath(marker.Root));
    }

    [Fact]
    public void FindProject_RejectsNodeModules_AndAcceptsOuterMarker()
    {
        var project = Dir("code", "web");
        File(project, ".git");
        var nested = Dir("code", "web", "node_modules", "vite");
        File(nested, "package.json", """{ "name": "vite" }""");

        var home = Dir("home");
        var marker = ProjectDetector.FindProject(nested, Context(home));

        Assert.NotNull(marker);
        Assert.Equal(Path.GetFullPath(project), Path.GetFullPath(marker!.Root));
    }

    [Theory]
    [InlineData("AppData", "Local", "npm-cache", "pkg", true)]  // user app-data tree
    [InlineData("AppData", "Roaming", "npm", "x", true)]         // npm globals
    [InlineData(".cargo", "registry", "src", "x", true)]         // hidden per-user tool tree
    [InlineData("work", "cache", "item", "x", true)]             // cache segment
    [InlineData("Program Files", "SomeApp", "data", "x", false)] // os-managed tree
    public void FindProject_RejectsManagedTrees(string a, string b, string c, string d, bool underHome)
    {
        var home = Dir("home");
        var cwd = underHome ? Dir("home", a, b, c, d) : Dir(a, b, c, d);
        File(cwd, ".git");

        var marker = ProjectDetector.FindProject(cwd, Context(home));

        // The immediate .git is rejected; nothing above it qualifies, so no project.
        Assert.Null(marker);
    }

    [Fact]
    public void FindProject_RejectsHomeRootMarker()
    {
        var home = Dir("home");
        File(home, ".git");
        var cwd = Dir("home", "scratch");
        // The walk-up from scratch sees home's .git but home itself must be rejected.
        var marker = ProjectDetector.FindProject(cwd, Context(home));

        Assert.Null(marker);
    }

    [Fact]
    public void FindProject_CwdOutsideRootIsRejected()
    {
        var project = Dir("code", "marked");
        File(project, ".git");
        var elsewhere = Dir("code", "unmarked");

        var home = Dir("home");
        var marker = ProjectDetector.FindProject(elsewhere, Context(home));

        Assert.Null(marker);
    }

    [Fact]
    public void FindProject_EmptyCwd_ReturnsNull()
    {
        var home = Dir("home");
        Assert.Null(ProjectDetector.FindProject(null, Context(home)));
        Assert.Null(ProjectDetector.FindProject("", Context(home)));
    }

    public void Dispose()
    {
        try
        {
            Directory.Delete(_root, recursive: true);
        }
        catch
        {
            // temp cleanup is best-effort
        }
    }
}
