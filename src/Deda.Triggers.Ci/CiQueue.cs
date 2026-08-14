using System.Diagnostics.Metrics;

namespace Deda.Triggers.Ci;

public sealed record CiQueueSnapshot(int Queued, int Active, DateTimeOffset ObservedAt)
{
    public int RequiredCapacity => checked(Queued + Active);
}

public static class CiDiagnostics
{
    public const string SourceName = "Deda.Ci";
    public static readonly Meter Meter = new(SourceName);
    private static readonly Counter<long> ApiRequests = Meter.CreateCounter<long>("deda_ci_api_requests_total");
    private static readonly Counter<long> ApiFailures = Meter.CreateCounter<long>("deda_ci_api_failures_total");
    private static readonly Dictionary<string, (string Provider, string Service, CiQueueSnapshot Snapshot)> Snapshots = new(StringComparer.Ordinal);
    private static readonly object Gate = new();
    private static readonly ObservableGauge<int> Queued = Meter.CreateObservableGauge("deda_ci_jobs_queued", () => Observe(x => x.Queued));
    private static readonly ObservableGauge<int> Active = Meter.CreateObservableGauge("deda_ci_jobs_active", () => Observe(x => x.Active));
    private static readonly ObservableGauge<int> Capacity = Meter.CreateObservableGauge("deda_ci_required_capacity", () => Observe(x => x.RequiredCapacity));
    private static readonly ObservableGauge<double> Age = Meter.CreateObservableGauge("deda_ci_observation_age_seconds", () => Observe(x => (DateTimeOffset.UtcNow - x.ObservedAt).TotalSeconds));
    public static void Record(string provider, string service, CiQueueSnapshot snapshot)
    {
        lock (Gate) Snapshots[$"{provider}:{service}"] = (provider, service, snapshot);
        ApiRequests.Add(1, new KeyValuePair<string, object?>("provider", provider));
    }
    public static void Failure(string provider) => ApiFailures.Add(1, new KeyValuePair<string, object?>("provider", provider));
    private static IEnumerable<Measurement<T>> Observe<T>(Func<CiQueueSnapshot, T> value) where T : struct
    {
        lock (Gate)
            return Snapshots.Values.Select(x => new Measurement<T>(value(x.Snapshot), new KeyValuePair<string, object?>("provider", x.Provider), new KeyValuePair<string, object?>("service", x.Service))).ToArray();
    }
}
