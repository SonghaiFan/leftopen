using LeftOpen.Core;

namespace LeftOpen.Core.Tests;

public class CloseServiceTests
{
    private const string CurrentSid = "S-1-5-21-current";
    private static readonly DateTime Started = new(2026, 1, 1, 12, 0, 0, DateTimeKind.Local);

    private static Activity Activity(
        int pid,
        int port,
        string? exe = "C:\\dev\\myapp\\server.exe",
        string? sid = CurrentSid,
        ProjectMarkerFact? marker = null,
        InstalledAppFact? app = null)
    {
        var process = new ActivityProcessFact(pid, 900, "server", exe, null, Started, sid, "DEV\\dev", marker != null ? "C:\\dev\\myapp" : null);
        var facts = new ActivityFacts(
            new ListenerFact(port, ["127.0.0.1"], Scope.Local),
            process,
            [],
            marker,
            app);
        return new Activity(facts, new OwnerInference("x", Category.Unknown, Confidence.None, "test"));
    }

    private static Listener ListenerFor(int pid, int port) =>
        new(pid, "server", CurrentSid, "DEV\\dev", port, ["127.0.0.1"]);

    /// <summary>Wires a CloseService with in-memory scan/listener state and counters.</summary>
    private sealed class Harness
    {
        public List<Activity> Snapshot { get; set; } = [];

        /// <summary>What the TCP listener poll reports (only called after each wait).</summary>
        public Func<IReadOnlyList<Listener>> Listeners { get; set; } = () => [];

        public DateTime? StartTime { get; set; } = Started;

        public int Signalled { get; private set; }

        public bool SignalResult { get; set; } = true;

        public int Waits { get; private set; }

        public CloseService Service() => new(
            scan: () => new ScanResult(Snapshot, []),
            listeners: Listeners,
            startTime: _ => StartTime,
            signal: _ =>
            {
                Signalled++;
                return SignalResult;
            },
            wait: _ =>
            {
                Waits++;
                return Task.CompletedTask;
            });
    }

    private static CloseService RigidService() => new(
        scan: () => new ScanResult([], []),
        listeners: () => [],
        startTime: _ => Started,
        signal: _ => throw new InvalidOperationException("must not signal"),
        wait: _ => Task.CompletedTask);
    [Fact]
    public void SelectCloseTarget_NoListener_Throws()
    {
        var ex = Assert.Throws<CloseRefusedException>(
            () => RigidService().SelectCloseTarget([], new CloseOptions(3000, null, CurrentSid, 555)));
        Assert.Contains("Nothing is listening", ex.Message);
    }

    [Fact]
    public void SelectCloseTarget_MultiplePidsRequireExplicitPid()
    {
        var activities = new[] { Activity(100, 3000), Activity(101, 3000) };
        var ex = Assert.Throws<CloseRefusedException>(
            () => RigidService().SelectCloseTarget(activities, new CloseOptions(3000, null, CurrentSid, 555)));
        Assert.Contains("multiple owning PIDs", ex.Message);
    }

    [Fact]
    public void SelectCloseTarget_ProtectedPidsAreRefused()
    {
        Assert.Throws<CloseRefusedException>(() =>
            RigidService().SelectCloseTarget([Activity(4, 3000)], new CloseOptions(3000, null, CurrentSid, 555)));
        Assert.Throws<CloseRefusedException>(() =>
            RigidService().SelectCloseTarget([Activity(555, 3000)], new CloseOptions(3000, null, CurrentSid, 555)));
    }

    [Theory]
    [InlineData(null, "no verified owner SID")]
    [InlineData("S-1-5-21-someone-else", "belongs to another user")]
    public void SelectCloseTarget_OwnerVerification(string? sid, string expectedFragment)
    {
        var ex = Assert.Throws<CloseRefusedException>(
            () => RigidService().SelectCloseTarget([Activity(100, 3000, sid: sid)], new CloseOptions(3000, null, CurrentSid, 555)));
        Assert.Contains(expectedFragment, ex.Message);
    }

    [Fact]
    public void SelectCloseTarget_MissingExePathRefused()
    {
        var ex = Assert.Throws<CloseRefusedException>(
            () => RigidService().SelectCloseTarget([Activity(100, 3000, exe: null)], new CloseOptions(3000, null, CurrentSid, 555)));
        Assert.Contains("no verified executable path", ex.Message);
    }

    [Fact]
    public void SelectCloseTarget_SystemExecutableRefused()
    {
        var exe = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "svchost.exe");
        var ex = Assert.Throws<CloseRefusedException>(
            () => RigidService().SelectCloseTarget([Activity(100, 3000, exe: exe)], new CloseOptions(3000, null, CurrentSid, 555)));
        Assert.Contains("operating-system", ex.Message);
    }

    [Fact]
    public void SelectCloseTarget_InstalledAppWithoutProjectRefused()
    {
        var app = new InstalledAppFact("Spotify", "C:\\Program Files\\Spotify", 100, true);
        var ex = Assert.Throws<CloseRefusedException>(
            () => RigidService().SelectCloseTarget(
                [Activity(100, 3000, exe: "C:\\Program Files\\Spotify\\Spotify.exe", app: app)],
                new CloseOptions(3000, null, CurrentSid, 555)));
        Assert.Contains("installed application", ex.Message);
    }

    [Fact]
    public void SelectCloseTarget_RuntimeHostInProgramFilesIsAllowed()
    {
        var app = new InstalledAppFact("node", "C:\\Program Files\\nodejs", 100, true);

        var (activity, otherPorts, peerPids) = RigidService().SelectCloseTarget(
            [Activity(100, 3000, exe: "C:\\Program Files\\nodejs\\node.exe", app: app)],
            new CloseOptions(3000, null, CurrentSid, 555));

        Assert.Equal(100, activity.Facts.Process.Pid);
        Assert.Empty(otherPorts);
        Assert.Empty(peerPids);
    }

    [Fact]
    public void SelectCloseTarget_NodeInsideProjectIsAllowed_EvenThoughNodeLivesInProgramFiles()
    {
        var app = new InstalledAppFact("node", "C:\\Program Files\\nodejs", 100, true);
        var marker = new ProjectMarkerFact("myapp", "C:\\dev\\myapp", "git", "C:\\dev\\myapp\\.git");

        var (activity, _, _) = RigidService().SelectCloseTarget(
            [Activity(100, 3000, exe: "C:\\Program Files\\nodejs\\node.exe", marker: marker, app: app)],
            new CloseOptions(3000, null, CurrentSid, 555));

        Assert.Equal(100, activity.Facts.Process.Pid);
    }

    [Fact]
    public void SelectCloseTarget_ReportsOtherPortsAndPeers()
    {
        var activities = new[] { Activity(100, 3000), Activity(100, 3001), Activity(101, 3000) };

        var (_, otherPorts, peerPids) = RigidService().SelectCloseTarget(
            activities, new CloseOptions(3000, 100, CurrentSid, 555));

        Assert.Equal([3001], otherPorts);
        Assert.Equal([101], peerPids);
    }

    [Fact]
    public async Task PrepareCloseAsync_RequiresVerifiedStartTime()
    {
        var harness = new Harness
        {
            Snapshot = [Activity(100, 3000)],
            StartTime = null,
        };

        var ex = await Assert.ThrowsAsync<CloseRefusedException>(
            () => harness.Service().PrepareCloseAsync(new CloseOptions(3000, null, CurrentSid, 555)));
        Assert.Contains("start time", ex.Message);
    }

    [Fact]
    public void VerifyCloseTarget_PidGoneFromPort_Refuses()
    {
        var plan = new ClosePlan(3000, 100, CurrentSid, "C:\\dev\\myapp\\server.exe", Started,
            Activity(100, 3000), [], []);

        var ex = Assert.Throws<CloseRefusedException>(
            () => RigidService().VerifyCloseTarget(plan, [], Started));
        Assert.Contains("no longer listens", ex.Message);
    }

    [Fact]
    public void VerifyCloseTarget_NewPeerPid_Refuses()
    {
        var plan = new ClosePlan(3000, 100, CurrentSid, "C:\\dev\\myapp\\server.exe", Started,
            Activity(100, 3000), [], []);

        var activities = new[] { Activity(100, 3000), Activity(101, 3000) };
        var ex = Assert.Throws<CloseRefusedException>(
            () => RigidService().VerifyCloseTarget(plan, activities, Started));
        Assert.Contains("new owning PID", ex.Message);
    }

    [Fact]
    public void VerifyCloseTarget_IdentityChange_Refuses()
    {
        var plan = new ClosePlan(3000, 100, CurrentSid, "C:\\dev\\myapp\\server.exe", Started,
            Activity(100, 3000), [], []);

        var changedTime = Started.AddMinutes(3);
        var ex = Assert.Throws<CloseRefusedException>(
            () => RigidService().VerifyCloseTarget(plan, [Activity(100, 3000)], changedTime));
        Assert.Contains("changed identity", ex.Message);

        // Same PID, different owner SID (PID reuse): also refused.
        var exSid = Assert.Throws<CloseRefusedException>(
            () => RigidService().VerifyCloseTarget(plan, [Activity(100, 3000, sid: "S-1-5-21-other")], Started));
        Assert.Contains("changed identity", exSid.Message);
    }

    [Fact]
    public async Task ExecuteCloseAsync_HappyPath_SignalsOnceAndPortFrees()
    {
        var harness = new Harness
        {
            Snapshot = [Activity(100, 3000)],
            Listeners = () => [],
        };
        var service = harness.Service();
        var plan = await service.PrepareCloseAsync(new CloseOptions(3000, null, CurrentSid, 555));

        var result = await service.ExecuteCloseAsync(plan);

        Assert.Equal(1, harness.Signalled);
        Assert.True(result.TargetStoppedListening);
        Assert.True(result.PortFree);
        Assert.Empty(result.RemainingPids);
        Assert.Equal(1, harness.Waits);
    }

    [Fact]
    public async Task ExecuteCloseAsync_StubbornProcess_ReportsHonestlyWithoutForce()
    {
        var harness = new Harness
        {
            Snapshot = [Activity(100, 3000)],
            Listeners = () => [ListenerFor(100, 3000)],
        };
        var service = harness.Service();
        var plan = await service.PrepareCloseAsync(new CloseOptions(3000, null, CurrentSid, 555));

        var result = await service.ExecuteCloseAsync(plan);

        Assert.Equal(1, harness.Signalled);
        Assert.False(result.TargetStoppedListening);
        Assert.False(result.PortFree);
        Assert.Equal([100], result.RemainingPids);
        Assert.Equal(10, harness.Waits); // polled the full window, never escalated to force
    }

    [Fact]
    public async Task ExecuteCloseAsync_VerificationFailure_SignalsNothing()
    {
        var harness = new Harness { Snapshot = [Activity(100, 3000)] };
        var service = harness.Service();
        var plan = await service.PrepareCloseAsync(new CloseOptions(3000, null, CurrentSid, 555));

        // The PID disappears between preview and execution.
        harness.Snapshot = [];

        await Assert.ThrowsAsync<CloseRefusedException>(() => service.ExecuteCloseAsync(plan));
        Assert.Equal(0, harness.Signalled);
        Assert.Equal(0, harness.Waits);
    }

    [Fact]
    public async Task ExecuteCloseAsync_NoDeliveryPath_ReportsHonestly()
    {
        var harness = new Harness
        {
            Snapshot = [Activity(100, 3000)],
            Listeners = () => [ListenerFor(100, 3000)],
            SignalResult = false,
        };
        var service = harness.Service();
        var plan = await service.PrepareCloseAsync(new CloseOptions(3000, null, CurrentSid, 555));

        var result = await service.ExecuteCloseAsync(plan);

        Assert.False(result.SignalsDelivered);
        Assert.False(result.TargetStoppedListening);
        Assert.Equal([100], result.RemainingPids);
    }

    [Fact]
    public async Task ExecuteCloseAsync_PortTakenOverByPeer_ReportsRemainingPid()
    {
        var harness = new Harness
        {
            Snapshot = [Activity(100, 3000)],
            Listeners = () => [ListenerFor(101, 3000)],
        };
        var service = harness.Service();
        var plan = await service.PrepareCloseAsync(new CloseOptions(3000, null, CurrentSid, 555));

        // Target PID 100 exits, but PID 101 immediately claims the port.
        var result = await service.ExecuteCloseAsync(plan);

        Assert.True(result.TargetStoppedListening);
        Assert.False(result.PortFree);
        Assert.Equal([101], result.RemainingPids);
    }
}
