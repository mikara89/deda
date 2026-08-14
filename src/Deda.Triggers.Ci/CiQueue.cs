using Deda.Core;
using System.Collections.Concurrent;
using System.Diagnostics.Metrics;

namespace Deda.Triggers.Ci;

public sealed record CiQueueSnapshot(int Queued, int Active, DateTimeOffset ObservedAt)
{
    public int RequiredCapacity => checked(Queued + Active);
}

/// <summary>Coalesces provider polling per effective service configuration.</summary>
public sealed class CiObservationCache
{
    private readonly ConcurrentDictionary<string, Entry> _entries = new(StringComparer.Ordinal);

    public async Task<CiQueueSnapshot> GetAsync(string provider, ServiceRef service, ScaleConfig config, Func<CancellationToken, Task<CiQueueSnapshot>> fetch, CancellationToken cancellationToken)
    {
        var refresh = RefreshInterval(config);
        var key = CacheKey(provider, service, config);
        var entry = _entries.GetOrAdd(key, _ => new Entry());
        await entry.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (entry.Snapshot is { } snapshot && DateTimeOffset.UtcNow - snapshot.ObservedAt < refresh)
                return snapshot;

            snapshot = await fetch(cancellationToken).ConfigureAwait(false);
            entry.Snapshot = snapshot;
            CiDiagnostics.RecordObservation(provider);
            return snapshot;
        }
        finally { entry.Gate.Release(); }
    }

    private static TimeSpan RefreshInterval(ScaleConfig config)
    {
        if (!config.TriggerConfig.TryGetValue("refreshSeconds", out var raw) || string.IsNullOrWhiteSpace(raw)) return TimeSpan.FromSeconds(15);
        if (!int.TryParse(raw, out var seconds) || seconds is < 1 or > 3600)
            throw new InvalidOperationException($"{config.TriggerType} trigger.refreshSeconds must be an integer between 1 and 3600.");
        return TimeSpan.FromSeconds(seconds);
    }

    private static string CacheKey(string provider, ServiceRef service, ScaleConfig config) =>
        string.Concat(provider, "|", service.ServiceId, "|", string.Join("|", config.TriggerConfig.OrderBy(x => x.Key, StringComparer.OrdinalIgnoreCase).Select(x => $"{x.Key}={x.Value}")));

    private sealed class Entry
    {
        public SemaphoreSlim Gate { get; } = new(1, 1);
        public CiQueueSnapshot? Snapshot { get; set; }
    }
}

public sealed class CiTelemetryLifecycle : IServiceLifecycleObserver
{
    public void RemoveService(string serviceId, string serviceName) => CiDiagnostics.RemoveService(serviceName);
}

public static class CiDiagnostics
{
    public const string SourceName = "Deda.Ci";
    public static readonly Meter Meter = new(SourceName);
    private static readonly Counter<long> ApiRequests = Meter.CreateCounter<long>("deda_ci_api_requests_total");
    private static readonly Counter<long> ApiFailures = Meter.CreateCounter<long>("deda_ci_api_failures_total");
    private static readonly Counter<long> Observations = Meter.CreateCounter<long>("deda_ci_observations_total");
    private static readonly ConcurrentDictionary<string, (string Provider, string Service, CiQueueSnapshot Snapshot)> Snapshots = new(StringComparer.Ordinal);
    private static readonly ObservableGauge<int> Queued = Meter.CreateObservableGauge("deda_ci_jobs_queued", () => Observe(x => x.Queued));
    private static readonly ObservableGauge<int> Active = Meter.CreateObservableGauge("deda_ci_jobs_active", () => Observe(x => x.Active));
    private static readonly ObservableGauge<int> Capacity = Meter.CreateObservableGauge("deda_ci_required_capacity", () => Observe(x => x.RequiredCapacity));
    private static readonly ObservableGauge<double> Age = Meter.CreateObservableGauge("deda_ci_observation_age_seconds", () => Observe(x => (DateTimeOffset.UtcNow - x.ObservedAt).TotalSeconds));

    public static void Record(string provider, string service, CiQueueSnapshot snapshot) => Snapshots[$"{provider}:{service}"] = (provider, service, snapshot);
    public static void RecordObservation(string provider) => Observations.Add(1, new KeyValuePair<string, object?>("provider", provider));
    public static void RecordApiRequest(string provider) => ApiRequests.Add(1, new KeyValuePair<string, object?>("provider", provider));
    public static void Failure(string provider) => ApiFailures.Add(1, new KeyValuePair<string, object?>("provider", provider));
    public static void RemoveService(string service) =>
        Snapshots.Where(entry => string.Equals(entry.Value.Service, service, StringComparison.Ordinal)).ToList().ForEach(entry => Snapshots.TryRemove(entry.Key, out _));

    private static IEnumerable<Measurement<T>> Observe<T>(Func<CiQueueSnapshot, T> value) where T : struct =>
        Snapshots.Values.Select(x => new Measurement<T>(value(x.Snapshot), new KeyValuePair<string, object?>("provider", x.Provider), new KeyValuePair<string, object?>("service", x.Service))).ToArray();
}
