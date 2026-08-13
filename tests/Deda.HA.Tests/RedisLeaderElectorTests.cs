using Deda.HA;

using Microsoft.Extensions.Logging.Abstractions;

namespace Deda.HA.Tests;

public sealed class RedisLeaderElectorTests
{
    private static readonly RedisLeaderOptions FirstOptions = new(
        "deda:test:leader",
        "first",
        TimeSpan.FromSeconds(1),
        TimeSpan.FromMilliseconds(20));

    [Fact]
    public async Task TwoReplicasElectOneLeaderAndStandbyTakesOverAfterRelease()
    {
        var store = new InMemoryLeaseStore();
        var first = Create(store, FirstOptions);
        var second = Create(store, FirstOptions with { InstanceId = "second" });

        await first.StartAsync(CancellationToken.None);
        Assert.True(await first.IsLeaderAsync(CancellationToken.None));

        await second.StartAsync(CancellationToken.None);
        Assert.False(await second.IsLeaderAsync(CancellationToken.None));

        await first.StopAsync(CancellationToken.None);
        await WaitUntilAsync(() => second.IsLeaderAsync(CancellationToken.None));
        Assert.True(await second.IsLeaderAsync(CancellationToken.None));

        await second.StopAsync(CancellationToken.None);
    }

    [Fact]
    public async Task StoreFailureFailsClosedInsteadOfClaimingLeadership()
    {
        var elector = Create(new ThrowingLeaseStore(), FirstOptions);

        await elector.StartAsync(CancellationToken.None);

        Assert.False(await elector.IsLeaderAsync(CancellationToken.None));
        await elector.StopAsync(CancellationToken.None);
    }

    [Theory]
    [InlineData(0, 1)]
    [InlineData(10, 10)]
    [InlineData(10, 11)]
    public void OptionsRejectInvalidRenewalIntervals(int leaseMilliseconds, int renewMilliseconds)
    {
        var options = FirstOptions with
        {
            LeaseDuration = TimeSpan.FromMilliseconds(leaseMilliseconds),
            RenewInterval = TimeSpan.FromMilliseconds(renewMilliseconds),
        };

        Assert.ThrowsAny<ArgumentOutOfRangeException>(options.Validate);
    }

    private static RedisLeaderElector Create(ILeaderLeaseStore store, RedisLeaderOptions options) =>
        new(store, options, NullLogger<RedisLeaderElector>.Instance);

    private static async Task WaitUntilAsync(Func<Task<bool>> condition)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
        while (!await condition())
            await Task.Delay(10, timeout.Token);
    }

    private sealed class InMemoryLeaseStore : ILeaderLeaseStore
    {
        private readonly object _gate = new();
        private string? _owner;

        public Task<bool> TryAcquireOrRenewAsync(
            string key,
            string owner,
            TimeSpan leaseDuration,
            CancellationToken ct)
        {
            lock (_gate)
            {
                if (_owner is null || _owner == owner)
                {
                    _owner = owner;
                    return Task.FromResult(true);
                }

                return Task.FromResult(false);
            }
        }

        public Task ReleaseAsync(string key, string owner, CancellationToken ct)
        {
            lock (_gate)
            {
                if (_owner == owner)
                    _owner = null;
            }
            return Task.CompletedTask;
        }
    }

    private sealed class ThrowingLeaseStore : ILeaderLeaseStore
    {
        public Task<bool> TryAcquireOrRenewAsync(
            string key,
            string owner,
            TimeSpan leaseDuration,
            CancellationToken ct) => throw new IOException("redis unavailable");

        public Task ReleaseAsync(string key, string owner, CancellationToken ct) => Task.CompletedTask;
    }
}
