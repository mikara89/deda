using Deda.Controller;
using Deda.Core;

namespace Deda.Controller.Tests;

public sealed class AutoscalerControllerTests
{
    private static readonly DateTimeOffset Now = new(2026, 8, 13, 12, 0, 0, TimeSpan.Zero);

    [Fact]
    public async Task Runner_DockerFailureStaysAliveMarksUnreadyAndUsesBoundedBackoff()
    {
        var fixture = new Fixture();
        var health = new ReconciliationHealthState();
        var time = new MutableTimeProvider(Now);
        var runner = new ResilientReconcileRunner(
            fixture.Controller,
            health,
            fixture.Telemetry,
            new ReconcileLoopOptions(TimeSpan.FromSeconds(10), TimeSpan.FromSeconds(25)),
            time);
        fixture.Swarm.ListException = new IOException("docker unavailable");

        var firstDelay = await runner.RunOnceAsync(CancellationToken.None);
        time.Advance(TimeSpan.FromSeconds(10));
        var secondDelay = await runner.RunOnceAsync(CancellationToken.None);
        time.Advance(TimeSpan.FromSeconds(20));
        var thirdDelay = await runner.RunOnceAsync(CancellationToken.None);

        var failed = health.Snapshot();
        Assert.False(failed.IsReady);
        Assert.Equal(Now.AddSeconds(30), failed.LastAttemptUtc);
        Assert.Equal(Now.AddSeconds(30), failed.LastFailureUtc);
        Assert.Contains("docker unavailable", failed.LastError);
        Assert.Equal(TimeSpan.FromSeconds(10), firstDelay);
        Assert.Equal(TimeSpan.FromSeconds(20), secondDelay);
        Assert.Equal(TimeSpan.FromSeconds(25), thirdDelay);
        Assert.Equal(3, fixture.Telemetry.Errors.Count);
    }

    [Fact]
    public async Task Runner_RecoversReadinessAndResetsBackoffAfterSuccessfulReconcile()
    {
        var fixture = new Fixture();
        var health = new ReconciliationHealthState();
        var time = new MutableTimeProvider(Now);
        var runner = new ResilientReconcileRunner(
            fixture.Controller,
            health,
            fixture.Telemetry,
            new ReconcileLoopOptions(TimeSpan.FromSeconds(10), TimeSpan.FromSeconds(60)),
            time);
        fixture.Swarm.ListException = new IOException("manager restarting");

        await runner.RunOnceAsync(CancellationToken.None);
        time.Advance(TimeSpan.FromSeconds(10));
        await runner.RunOnceAsync(CancellationToken.None);

        fixture.Swarm.ListException = null;
        time.Advance(TimeSpan.FromSeconds(20));
        var recoveredDelay = await runner.RunOnceAsync(CancellationToken.None);

        var recovered = health.Snapshot();
        Assert.True(recovered.IsReady);
        Assert.Equal(Now.AddSeconds(30), recovered.LastSuccessfulUtc);
        Assert.Null(recovered.LastError);
        Assert.Equal(TimeSpan.FromSeconds(10), recoveredDelay);

        fixture.Swarm.ListException = new IOException("failed again");
        var nextFailureDelay = await runner.RunOnceAsync(CancellationToken.None);
        Assert.Equal(TimeSpan.FromSeconds(10), nextFailureDelay);
    }

    [Fact]
    public async Task Runner_CancellationPropagatesWithoutRecordingFailure()
    {
        var fixture = new Fixture();
        var health = new ReconciliationHealthState();
        var runner = new ResilientReconcileRunner(
            fixture.Controller,
            health,
            fixture.Telemetry,
            new ReconcileLoopOptions(TimeSpan.FromSeconds(10), TimeSpan.FromSeconds(60)),
            new MutableTimeProvider(Now));
        using var cts = new CancellationTokenSource();
        cts.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => runner.RunOnceAsync(cts.Token));

        Assert.Null(health.Snapshot().LastFailureUtc);
        Assert.Empty(fixture.Telemetry.Errors);
    }

    [Fact]
    public async Task Runner_StandbyIsReadyWhileLeaderStoreFailureIsUnready()
    {
        var standbyHealth = new ReconciliationHealthState();
        var standbyFixture = new Fixture(leader: new FakeLeaderElector(false));
        var standbyRunner = new ResilientReconcileRunner(
            standbyFixture.Controller,
            standbyHealth,
            standbyFixture.Telemetry,
            new ReconcileLoopOptions(TimeSpan.FromSeconds(10), TimeSpan.FromSeconds(60)),
            new MutableTimeProvider(Now));

        var standbyDelay = await standbyRunner.RunOnceAsync(CancellationToken.None);

        Assert.True(standbyHealth.Snapshot().IsReady);
        Assert.Equal(TimeSpan.FromSeconds(10), standbyDelay);
        Assert.Equal(0, standbyFixture.Swarm.ListCallCount);

        var unavailableHealth = new ReconciliationHealthState();
        var unavailableFixture = new Fixture(leader: new UnavailableLeaderElector());
        var unavailableRunner = new ResilientReconcileRunner(
            unavailableFixture.Controller,
            unavailableHealth,
            unavailableFixture.Telemetry,
            new ReconcileLoopOptions(TimeSpan.FromSeconds(10), TimeSpan.FromSeconds(60)),
            new MutableTimeProvider(Now));

        var unavailableDelay = await unavailableRunner.RunOnceAsync(CancellationToken.None);

        var unavailable = unavailableHealth.Snapshot();
        Assert.False(unavailable.IsReady);
        Assert.Contains(nameof(LeaderElectionUnavailableException), unavailable.LastError);
        Assert.Equal(TimeSpan.FromSeconds(10), unavailableDelay);
        Assert.Equal(0, unavailableFixture.Swarm.ListCallCount);
    }

    [Fact]
    public async Task Reconcile_InvalidServiceConfigurationIsReportedClearly()
    {
        var fixture = new Fixture();
        fixture.Swarm.Services = [Service("invalid")];
        fixture.Config.Config = null;
        fixture.Config.Error = "min > max";

        await fixture.Controller.ReconcileOnceAsync(CancellationToken.None);

        var error = Assert.Single(fixture.Telemetry.Errors);
        Assert.Equal(("invalid", "config"), (error.ServiceName, error.Stage));
        Assert.Contains("min > max", error.Exception.Message);
    }

    [Fact]
    public async Task Reconcile_UnknownTriggerTypeIsReportedClearly()
    {
        var fixture = new Fixture();
        fixture.Swarm.Services = [Service("unknown-trigger")];
        fixture.Config.Config = ValidConfig() with { TriggerType = "mystery" };

        await fixture.Controller.ReconcileOnceAsync(CancellationToken.None);

        var error = Assert.Single(fixture.Telemetry.Errors);
        Assert.Equal(("unknown-trigger", "trigger"), (error.ServiceName, error.Stage));
        Assert.Contains("mystery", error.Exception.Message);
    }

    [Fact]
    public async Task Reconcile_AdapterCancellationIsNotSwallowedAsServiceError()
    {
        var fixture = new Fixture();
        fixture.Swarm.Services = [Service("cancelled")];
        using var cts = new CancellationTokenSource();
        fixture.Registry.Adapter = new FakeAdapter((_, _, ct) =>
        {
            cts.Cancel();
            ct.ThrowIfCancellationRequested();
            return Task.FromResult(TriggerResult.Ok(0));
        });

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => fixture.Controller.ReconcileOnceAsync(cts.Token));

        Assert.Empty(fixture.Telemetry.Errors);
    }

    [Fact]
    public async Task Reconcile_SuccessfulDecisionAppliesReplicaUpdateAndRecordsState()
    {
        var fixture = new Fixture();
        var service = Service("worker", replicas: 1);
        fixture.Swarm.Services = [service];
        fixture.Registry.Adapter = new FakeAdapter(
            (_, _, _) => Task.FromResult(TriggerResult.Ok(30)));
        fixture.Policy.DesiredReplicas = 3;

        await fixture.Controller.ReconcileOnceAsync(CancellationToken.None);

        var update = Assert.Single(fixture.Updates.Updates);
        Assert.Equal((service.ServiceId, 3), update);
        var state = fixture.StateStore.GetOrAdd(service.ServiceId);
        Assert.Equal(3, state.LastAppliedReplicas);
        Assert.NotNull(state.LastScaleUpUtc);
        Assert.Single(fixture.Telemetry.Decisions);
    }

    [Fact]
    public async Task Reconcile_StandbyDoesNotDiscoverServicesOrApplyReplicaUpdates()
    {
        var fixture = new Fixture(leader: new FakeLeaderElector(false));
        fixture.Swarm.Services = [Service("worker")];
        fixture.Policy.DesiredReplicas = 3;

        await fixture.Controller.ReconcileOnceAsync(CancellationToken.None);

        Assert.Equal(0, fixture.Swarm.ListCallCount);
        Assert.Empty(fixture.Updates.Updates);
    }

    [Fact]
    public async Task Reconcile_LostLeadershipBeforeMutationPreventsReplicaUpdate()
    {
        var leader = new FakeLeaderElector(true, false);
        var fixture = new Fixture(leader: leader);
        fixture.Swarm.Services = [Service("worker")];
        fixture.Registry.Adapter = new FakeAdapter(
            (_, _, _) => Task.FromResult(TriggerResult.Ok(30)));
        fixture.Policy.DesiredReplicas = 3;

        await fixture.Controller.ReconcileOnceAsync(CancellationToken.None);

        Assert.Equal(2, leader.CallCount);
        Assert.Empty(fixture.Updates.Updates);
    }

    [Fact]
    public async Task Reconcile_LeaderStoreFailureBeforeMutationPropagates()
    {
        var fixture = new Fixture(leader: new UnavailableBeforeMutationElector());
        fixture.Swarm.Services = [Service("worker")];
        fixture.Registry.Adapter = new FakeAdapter(
            (_, _, _) => Task.FromResult(TriggerResult.Ok(30)));
        fixture.Policy.DesiredReplicas = 3;

        await Assert.ThrowsAsync<LeaderElectionUnavailableException>(
            () => fixture.Controller.ReconcileOnceAsync(CancellationToken.None));

        Assert.Empty(fixture.Updates.Updates);
    }

    [Fact]
    public async Task Reconcile_GlobalServicesAreIgnored()
    {
        var fixture = new Fixture();
        var adapter = new FakeAdapter((_, _, _) => Task.FromResult(TriggerResult.Ok(0)));
        fixture.Registry.Adapter = adapter;
        fixture.Swarm.Services =
        [
            Service("global") with { Mode = SwarmServiceMode.Global },
            Service("replicated"),
        ];

        await fixture.Controller.ReconcileOnceAsync(CancellationToken.None);

        Assert.Equal(1, adapter.CallCount);
        Assert.Single(fixture.Telemetry.Decisions);
        Assert.Equal("replicated", fixture.Telemetry.Decisions[0].ServiceName);
    }

    [Fact]
    public async Task Reconcile_MaxServicesPerCycleLimitsProcessedPage()
    {
        var fixture = new Fixture(new HostOptions(10, 2, false));
        fixture.Registry.Adapter = new FakeAdapter(
            (_, _, _) => Task.FromResult(TriggerResult.Ok(0)));
        fixture.Swarm.Services = Enumerable.Range(1, 5)
            .Select(index => Service($"service-{index}"))
            .ToList();

        await fixture.Controller.ReconcileOnceAsync(CancellationToken.None);

        Assert.Equal(2, fixture.Telemetry.Decisions.Count);
    }

    private static ServiceRef Service(string name, int replicas = 1) =>
        new($"id-{name}", name, replicas, new Dictionary<string, string>(), 1, SwarmServiceMode.Replicated);

    private static ScaleConfig ValidConfig() => new()
    {
        Enabled = true,
        MinReplicas = 0,
        MaxReplicas = 20,
        TriggerType = "fake",
    };

    private sealed class Fixture
    {
        public FakeSwarm Swarm { get; } = new();
        public FakeConfigProvider Config { get; } = new();
        public FakeRegistry Registry { get; } = new();
        public FakePolicy Policy { get; } = new();
        public FakeStateStore StateStore { get; } = new();
        public RecordingTelemetry Telemetry { get; } = new();
        public RecordingUpdateStrategy Updates { get; } = new();
        public AutoscalerController Controller { get; }

        public Fixture(HostOptions? hostOptions = null, ILeaderElector? leader = null)
        {
            Controller = new AutoscalerController(
                Swarm,
                Config,
                Registry,
                Policy,
                StateStore,
                Telemetry,
                Updates,
                hostOptions ?? new HostOptions(10, 0, false),
                leader);
        }
    }

    private sealed class FakeLeaderElector(params bool[] results) : ILeaderElector
    {
        private int _index;
        public int CallCount => _index;

        public Task<bool> IsLeaderAsync(CancellationToken ct)
        {
            var index = Interlocked.Increment(ref _index) - 1;
            return Task.FromResult(results[Math.Min(index, results.Length - 1)]);
        }
    }

    private sealed class UnavailableLeaderElector : ILeaderElector
    {
        public Task<bool> IsLeaderAsync(CancellationToken ct) =>
            Task.FromException<bool>(new LeaderElectionUnavailableException(
                "Redis unavailable.",
                new IOException("connection refused")));
    }

    private sealed class UnavailableBeforeMutationElector : ILeaderElector
    {
        private int _callCount;

        public Task<bool> IsLeaderAsync(CancellationToken ct)
        {
            if (Interlocked.Increment(ref _callCount) == 1)
                return Task.FromResult(true);

            return Task.FromException<bool>(new LeaderElectionUnavailableException(
                "Redis unavailable.",
                new IOException("connection refused")));
        }
    }

    private sealed class FakeSwarm : ISwarmServiceClient
    {
        public IReadOnlyList<ServiceRef> Services { get; set; } = [];
        public Exception? ListException { get; set; }
        public int ListCallCount { get; private set; }

        public Task<IReadOnlyList<ServiceRef>> ListServicesAsync(CancellationToken ct)
        {
            ListCallCount++;
            ct.ThrowIfCancellationRequested();
            return ListException is null
                ? Task.FromResult(Services)
                : Task.FromException<IReadOnlyList<ServiceRef>>(ListException);
        }

        public Task<ServiceRef> GetServiceAsync(string serviceId, CancellationToken ct) =>
            Task.FromResult(Services.Single(service => service.ServiceId == serviceId));

        public Task UpdateReplicasAsync(
            string serviceId,
            long versionIndex,
            int desiredReplicas,
            CancellationToken ct) => Task.CompletedTask;
    }

    private sealed class FakeConfigProvider : IScaleConfigProvider
    {
        public ScaleConfig? Config { get; set; } = ValidConfig();
        public string? Error { get; set; }

        public ScaleConfig? TryGetConfig(ServiceRef service, out string? error)
        {
            error = Error;
            return Config;
        }
    }

    private sealed class FakeRegistry : ITriggerAdapterRegistry
    {
        public ITriggerAdapter? Adapter { get; set; }

        public bool TryResolve(string triggerType, out ITriggerAdapter adapter)
        {
            adapter = Adapter!;
            return Adapter is not null && string.Equals(Adapter.Type, triggerType, StringComparison.OrdinalIgnoreCase);
        }
    }

    private sealed class FakeAdapter : ITriggerAdapter
    {
        private readonly Func<ServiceRef, ScaleConfig, CancellationToken, Task<TriggerResult>> _handler;

        public FakeAdapter(Func<ServiceRef, ScaleConfig, CancellationToken, Task<TriggerResult>> handler)
        {
            _handler = handler;
        }

        public string Type => "fake";

        public int CallCount { get; private set; }

        public Task<TriggerResult> GetWorkAsync(
            ServiceRef service,
            ScaleConfig config,
            CancellationToken ct)
        {
            CallCount++;
            return _handler(service, config, ct);
        }
    }

    private sealed class FakePolicy : IScalePolicy
    {
        public int? DesiredReplicas { get; set; }

        public ScaleDecision Decide(
            ServiceRef service,
            ScaleConfig config,
            TriggerResult trigger,
            ServiceScaleState state,
            DateTimeOffset nowUtc) =>
            new(
                service.ServiceId,
                service.Name,
                service.CurrentReplicas,
                DesiredReplicas ?? service.CurrentReplicas,
                trigger.Work,
                "test",
                nowUtc);
    }

    private sealed class FakeStateStore : IStateStore<string, ServiceScaleState>
    {
        private readonly Dictionary<string, ServiceScaleState> _states = [];

        public ServiceScaleState GetOrAdd(string key)
        {
            if (!_states.TryGetValue(key, out var state))
            {
                state = new ServiceScaleState();
                _states[key] = state;
            }

            return state;
        }

        public void Remove(string key) => _states.Remove(key);
    }

    private sealed class RecordingTelemetry : IAutoscalerTelemetry
    {
        public List<ScaleDecision> Decisions { get; } = [];
        public List<(string ServiceName, string Stage, Exception Exception)> Errors { get; } = [];

        public void RecordDecision(ScaleDecision decision) => Decisions.Add(decision);

        public void RecordError(string serviceName, string stage, Exception ex) =>
            Errors.Add((serviceName, stage, ex));
    }

    private sealed class RecordingUpdateStrategy : IServiceUpdateStrategy
    {
        public List<(string ServiceId, int DesiredReplicas)> Updates { get; } = [];

        public Task ApplyDesiredReplicasAsync(
            ISwarmServiceClient swarm,
            ServiceRef service,
            int desiredReplicas,
            CancellationToken ct)
        {
            Updates.Add((service.ServiceId, desiredReplicas));
            return Task.CompletedTask;
        }
    }

    private sealed class MutableTimeProvider : TimeProvider
    {
        private DateTimeOffset _utcNow;

        public MutableTimeProvider(DateTimeOffset utcNow)
        {
            _utcNow = utcNow;
        }

        public override DateTimeOffset GetUtcNow() => _utcNow;

        public void Advance(TimeSpan duration) => _utcNow += duration;
    }
}
