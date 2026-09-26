using LeftOpen.Core;

namespace LeftOpen.Core.Tests;

public class OwnershipTests
{
    private static readonly IReadOnlyList<string> AppRoots = ["C:\\Program Files", "C:\\Users\\dev\\AppData\\Local\\Programs"];

    private static ActivityFacts Facts(
        int pid = 100,
        int? parentPid = null,
        string? exe = null,
        ProjectMarkerFact? marker = null,
        InstalledAppFact? app = null,
        string[]? addresses = null,
        IReadOnlyList<ProcessFact>? parents = null)
    {
        var process = new ActivityProcessFact(pid, parentPid, "cmd", exe, null, null, "S-1-5-21-x", "DEV\\dev", null);
        return new ActivityFacts(
            new ListenerFact(3000, addresses ?? ["127.0.0.1"], Scope.Local),
            process,
            parents ?? [],
            marker,
            app);
    }

    [Fact]
    public void Infer_ProjectWinsOverEverything()
    {
        var marker = new ProjectMarkerFact("myapp", "C:\\dev\\myapp", "git", "C:\\dev\\myapp\\.git");
        var app = new InstalledAppFact("node", "C:\\Program Files\\nodejs", 100, true);
        var facts = Facts(marker: marker, app: app);

        var inference = Ownership.Infer(facts);

        Assert.Equal(Category.Project, inference.Category);
        Assert.Equal(Confidence.High, inference.Confidence);
        Assert.Equal("myapp", inference.Label);
        Assert.Contains("git", inference.Reason);
    }

    [Fact]
    public void Infer_DirectAppIsHighConfidence()
    {
        var app = new InstalledAppFact("Spotify", "C:\\Program Files\\Spotify", 100, true);
        var inference = Ownership.Infer(Facts(app: app));

        Assert.Equal(Category.Application, inference.Category);
        Assert.Equal(Confidence.High, inference.Confidence);
        Assert.Equal("Spotify", inference.Label);
    }

    [Fact]
    public void Infer_AncestorAppIsMediumConfidence()
    {
        var app = new InstalledAppFact("Code", "C:\\Users\\dev\\AppData\\Local\\Programs\\Microsoft VS Code", 99, false);
        var inference = Ownership.Infer(Facts(app: app));

        Assert.Equal(Category.Application, inference.Category);
        Assert.Equal(Confidence.Medium, inference.Confidence);
        Assert.Contains("99", inference.Reason);
    }

    [Fact]
    public void Infer_SystemExecutable_IsSystemService()
    {
        var exe = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "svchost.exe");
        var inference = Ownership.Infer(Facts(exe: exe));

        Assert.Equal(Category.SystemService, inference.Category);
        Assert.Equal(Confidence.High, inference.Confidence);
        Assert.Equal("svchost.exe", inference.Label);
    }

    [Fact]
    public void Infer_NoEvidence_IsUnknown()
    {
        var inference = Ownership.Infer(Facts(exe: "C:\\tools\\some-server.exe"));

        Assert.Equal(Category.Unknown, inference.Category);
        Assert.Equal(Confidence.None, inference.Confidence);
    }

    [Theory]
    [InlineData("127.0.0.1", Scope.Local)]
    [InlineData("::1", Scope.Local)]
    [InlineData("localhost", Scope.Local)]
    [InlineData("0.0.0.0", Scope.Lan)]
    [InlineData("192.168.1.5", Scope.Lan)]
    public void ListenerScope_ClassifiesAddresses(string address, Scope expected)
    {
        Assert.Equal(expected, Ownership.ListenerScope([address]));
    }

    [Fact]
    public void ListenerScope_AllLoopbackIsLocal_AnyOtherIsLan()
    {
        Assert.Equal(Scope.Local, Ownership.ListenerScope(["127.0.0.1", "::1"]));
        Assert.Equal(Scope.Lan, Ownership.ListenerScope(["127.0.0.1", "0.0.0.0"]));
    }

    [Theory]
    [InlineData("C:\\Program Files\\nodejs\\node.exe", true)]
    [InlineData("C:\\Program Files\\Python312\\python.exe", true)]
    [InlineData("C:\\Program Files\\Spotify\\Spotify.exe", false)]
    [InlineData(null, false)]
    public void IsRuntimeHost_IdentifiesSharedRuntimes(string? exe, bool expected)
    {
        Assert.Equal(expected, Ownership.IsRuntimeHost(exe));
    }

    [Fact]
    public void InstalledAppFromPath_DetectsAppInsideProvidedRoots()
    {
        var app = Ownership.InstalledAppFromPath("C:\\Program Files\\Spotify\\Spotify.exe", 42, true, AppRoots);

        Assert.NotNull(app);
        Assert.Equal("Spotify", app!.Name);
        Assert.True(app.DirectProcess);
        Assert.Equal(42, app.SourcePid);
    }

    [Fact]
    public void InstalledAppFromPath_IgnoresPathsOutsideAppRoots()
    {
        Assert.Null(Ownership.InstalledAppFromPath("C:\\dev\\myapp\\server.exe", 42, true, AppRoots));
        Assert.Null(Ownership.InstalledAppFromPath("relative\\path.exe", 42, true, AppRoots));
        Assert.Null(Ownership.InstalledAppFromPath(null, 42, true, AppRoots));
    }

    [Fact]
    public void ParentChainFor_WalksUpAndStopsOnCycle()
    {
        // a(1) ← b(2) ← a(1): a cycle must terminate, not hang.
        var table = new Dictionary<int, ProcessFact>
        {
            [1] = new ProcessFact(1, 2, "a", null, null, null),
            [2] = new ProcessFact(2, 1, "b", null, null, null),
        };

        var chain = Ownership.ParentChainFor(table[1], table);

        Assert.True(chain.Count <= 2);
    }

    [Fact]
    public void ParentChainFor_RespectsDepthLimit()
    {
        var table = new Dictionary<int, ProcessFact>();
        for (var pid = 1; pid <= 30; pid++)
        {
            table[pid] = new ProcessFact(pid, pid + 1, $"p{pid}", null, null, null);
        }
        table[31] = new ProcessFact(31, null, "root", null, null, null);

        var chain = Ownership.ParentChainFor(table[1], table);

        Assert.Equal(16, chain.Count);
    }

    [Fact]
    public void ParentChainFor_MissingParentStopsChain()
    {
        var table = new Dictionary<int, ProcessFact>
        {
            [1] = new ProcessFact(1, 999, "a", null, null, null), // parent not in table
        };

        var chain = Ownership.ParentChainFor(table[1], table);

        Assert.Empty(chain);
    }
}
