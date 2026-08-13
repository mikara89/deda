using Deda.Core;

using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

using StackExchange.Redis;

namespace Deda.HA;

public sealed record RedisLeaderOptions(
    string LockKey,
    string InstanceId,
    TimeSpan LeaseDuration,
    TimeSpan RenewInterval)
{
    public void Validate()
    {
        if (string.IsNullOrWhiteSpace(LockKey))
            throw new ArgumentException("The leader lock key is required.", nameof(LockKey));
        if (string.IsNullOrWhiteSpace(InstanceId))
            throw new ArgumentException("The leader instance ID is required.", nameof(InstanceId));
        if (LeaseDuration <= TimeSpan.Zero)
            throw new ArgumentOutOfRangeException(nameof(LeaseDuration));
        if (RenewInterval <= TimeSpan.Zero || RenewInterval >= LeaseDuration)
            throw new ArgumentOutOfRangeException(nameof(RenewInterval), "Renewal must be positive and shorter than the lease.");
    }
}

public interface ILeaderLeaseStore
{
    Task<bool> TryAcquireOrRenewAsync(
        string key,
        string owner,
        TimeSpan leaseDuration,
        CancellationToken ct);

    Task ReleaseAsync(string key, string owner, CancellationToken ct);
}

public sealed class RedisLeaderLeaseStore(IConnectionMultiplexer connection) : ILeaderLeaseStore
{
    private const string AcquireOrRenewScript = """
        if redis.call('GET', KEYS[1]) == ARGV[1] then
            return redis.call('PEXPIRE', KEYS[1], ARGV[2])
        end
        if redis.call('SET', KEYS[1], ARGV[1], 'PX', ARGV[2], 'NX') then
            return 1
        end
        return 0
        """;

    private const string ReleaseScript = """
        if redis.call('GET', KEYS[1]) == ARGV[1] then
            return redis.call('DEL', KEYS[1])
        end
        return 0
        """;

    public async Task<bool> TryAcquireOrRenewAsync(
        string key,
        string owner,
        TimeSpan leaseDuration,
        CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        var result = await connection.GetDatabase().ScriptEvaluateAsync(
            AcquireOrRenewScript,
            [(RedisKey)key],
            [(RedisValue)owner, (RedisValue)(long)leaseDuration.TotalMilliseconds])
            .ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        return (long)result == 1;
    }

    public async Task ReleaseAsync(string key, string owner, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        await connection.GetDatabase().ScriptEvaluateAsync(
            ReleaseScript,
            [(RedisKey)key],
            [(RedisValue)owner]).ConfigureAwait(false);
    }
}

public sealed class RedisLeaderElector : BackgroundService, ILeaderElector
{
    private readonly ILeaderLeaseStore _store;
    private readonly RedisLeaderOptions _options;
    private readonly ILogger<RedisLeaderElector> _logger;
    private bool _isLeader;

    public RedisLeaderElector(
        ILeaderLeaseStore store,
        RedisLeaderOptions options,
        ILogger<RedisLeaderElector> logger)
    {
        options.Validate();
        _store = store;
        _options = options;
        _logger = logger;
    }

    public Task<bool> IsLeaderAsync(CancellationToken ct) => RefreshLeadershipAsync(ct);

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        try
        {
            while (!stoppingToken.IsCancellationRequested)
            {
                try
                {
                    await RefreshLeadershipAsync(stoppingToken).ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
                {
                    break;
                }
                catch (Exception ex)
                {
                    SetLeadership(false);
                    _logger.LogError(ex, "Redis leader lease refresh failed; this instance is standing by.");
                }
                await Task.Delay(_options.RenewInterval, stoppingToken).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
        {
        }
        finally
        {
            if (Volatile.Read(ref _isLeader))
            {
                try
                {
                    await _store.ReleaseAsync(
                        _options.LockKey,
                        _options.InstanceId,
                        CancellationToken.None).ConfigureAwait(false);
                }
                catch (Exception ex)
                {
                    _logger.LogWarning(ex, "Could not release the Redis leader lease during shutdown; TTL expiry will recover it.");
                }
            }
            SetLeadership(false);
        }
    }

    private async Task<bool> RefreshLeadershipAsync(CancellationToken ct)
    {
        try
        {
            var acquired = await _store.TryAcquireOrRenewAsync(
                _options.LockKey,
                _options.InstanceId,
                _options.LeaseDuration,
                ct).ConfigureAwait(false);
            SetLeadership(acquired);
            return acquired;
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception ex)
        {
            SetLeadership(false);
            throw new LeaderElectionUnavailableException(
                "Redis leader lease refresh failed; leadership is unavailable.",
                ex);
        }
    }

    private void SetLeadership(bool value)
    {
        var previous = Volatile.Read(ref _isLeader);
        Volatile.Write(ref _isLeader, value);
        if (previous == value)
            return;

        if (value)
            _logger.LogInformation("Acquired DEDA leader lease as {InstanceId}.", _options.InstanceId);
        else
            _logger.LogWarning("Lost DEDA leader lease; replica updates are disabled until leadership is reacquired.");
    }
}
