using Deda.Core;
using Deda.Updates;

namespace Deda.Controller.Tests;

public sealed class RetryOnVersionConflictUpdateStrategyTests
{
    private static readonly RetryOnVersionConflictUpdateStrategy.RetryOptions NoDelay = new(
        MaxAttempts: 3,
        BaseDelay: TimeSpan.Zero,
        MaxDelay: TimeSpan.Zero,
        JitterPercent: 0);

    [Fact]
    public async Task VersionConflictsReloadFreshVersionAndEventuallySucceed()
    {
        var swarm = new ConflictSwarm(failuresBeforeSuccess: 2);
        var strategy = new RetryOnVersionConflictUpdateStrategy(NoDelay);

        await strategy.ApplyDesiredReplicasAsync(
            swarm,
            Service(version: 1),
            5,
            CancellationToken.None);

        Assert.Equal([1L, 2L, 3L], swarm.UpdateVersions);
        Assert.Equal(2, swarm.GetCalls);
    }

    [Fact]
    public async Task NonConflictFailureIsNotRetried()
    {
        var swarm = new ConflictSwarm(0)
        {
            UpdateException = new HttpRequestException("daemon unavailable"),
        };
        var strategy = new RetryOnVersionConflictUpdateStrategy(NoDelay);

        await Assert.ThrowsAsync<HttpRequestException>(() =>
            strategy.ApplyDesiredReplicasAsync(
                swarm,
                Service(version: 1),
                5,
                CancellationToken.None));

        Assert.Single(swarm.UpdateVersions);
        Assert.Equal(0, swarm.GetCalls);
    }

    [Fact]
    public async Task ExhaustedVersionConflictsPropagate()
    {
        var swarm = new ConflictSwarm(failuresBeforeSuccess: 10);
        var strategy = new RetryOnVersionConflictUpdateStrategy(NoDelay);

        var error = await Assert.ThrowsAsync<InvalidOperationException>(() =>
            strategy.ApplyDesiredReplicasAsync(
                swarm,
                Service(version: 1),
                5,
                CancellationToken.None));

        Assert.Contains("version conflict", error.Message);
        Assert.Equal(3, swarm.UpdateVersions.Count);
        Assert.Equal(2, swarm.GetCalls);
    }

    [Fact]
    public async Task LeadershipLostAfterConflict_PreventsRetryMutation()
    {
        var swarm = new ConflictSwarm(failuresBeforeSuccess: 1);
        var guard = new CountingGuard(allowAttempts: 1);
        var strategy = new RetryOnVersionConflictUpdateStrategy(NoDelay, guard);

        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            strategy.ApplyDesiredReplicasAsync(swarm, Service(version: 1), 5, CancellationToken.None));

        Assert.Single(swarm.UpdateVersions);
        Assert.Equal(2, guard.Calls);
    }

    private static ServiceRef Service(long version) =>
        new("service-1", "worker", 1, new Dictionary<string, string>(), version, SwarmServiceMode.Replicated);

    private sealed class ConflictSwarm : ISwarmServiceClient
    {
        private readonly int _failuresBeforeSuccess;
        private int _updateCalls;

        public ConflictSwarm(int failuresBeforeSuccess)
        {
            _failuresBeforeSuccess = failuresBeforeSuccess;
        }

        public Exception? UpdateException { get; init; }
        public List<long> UpdateVersions { get; } = [];
        public int GetCalls { get; private set; }

        public Task<IReadOnlyList<ServiceRef>> ListServicesAsync(CancellationToken ct) =>
            Task.FromResult<IReadOnlyList<ServiceRef>>([]);

        public Task<ServiceRef> GetServiceAsync(string serviceId, CancellationToken ct)
        {
            GetCalls++;
            return Task.FromResult(Service(GetCalls + 1));
        }

        public Task UpdateReplicasAsync(
            string serviceId,
            long versionIndex,
            int desiredReplicas,
            CancellationToken ct)
        {
            UpdateVersions.Add(versionIndex);
            _updateCalls++;

            if (UpdateException is not null)
                return Task.FromException(UpdateException);
            if (_updateCalls <= _failuresBeforeSuccess)
                return Task.FromException(new InvalidOperationException("version conflict"));

            return Task.CompletedTask;
        }
    }

    private sealed class CountingGuard(int allowAttempts) : IMutationGuard
    {
        public int Calls { get; private set; }
        public Task EnsureCanMutateAsync(CancellationToken ct)
        {
            Calls++;
            if (Calls > allowAttempts) throw new InvalidOperationException("leadership lost");
            return Task.CompletedTask;
        }
    }
}
