namespace Deda.Core
{

    // =========================
    // Domain models
    // =========================

    public enum SwarmServiceMode { Unknown, Replicated, Global }

    public sealed record ServiceRef(
        string ServiceId,
        string Name,
        int CurrentReplicas,
        IReadOnlyDictionary<string, string> Labels,
        long VersionIndex,
        SwarmServiceMode Mode
    );

    public enum FailSafeMode { Hold, Min, Max }

    public sealed record ScaleConfig
    {
        public bool Enabled { get; init; }
        public int MinReplicas { get; init; } = 0;
        public int MaxReplicas { get; init; } = 50;

        /// <summary>
        /// Deprecated compatibility property. Per-service polling is not supported and this
        /// value is ignored; DEDA_POLL_SECONDS controls the reconciliation interval.
        /// </summary>
        public int PollSeconds { get; init; } = 5;
        public int CooldownSeconds { get; init; } = 30;
        public int ScaleDownDelaySeconds { get; init; } = 30;

        public int StepUp { get; init; } = 10;
        public int StepDown { get; init; } = 5;

        public double TargetPerReplica { get; init; } = 50;
        public double ActivationThreshold { get; init; } = 5;

        public string TriggerType { get; init; } = "fake";
        public IReadOnlyDictionary<string, string> TriggerConfig { get; init; }
            = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

        public FailSafeMode FailSafe { get; init; } = FailSafeMode.Hold;
    }

    public sealed record TriggerResult(bool Success, double Work, string? Error = null)
    {
        public static TriggerResult Ok(double work) =>
            IsValidWork(work) ? new(true, work) : Fail("invalid_work");

        public static TriggerResult Fail(string error) => new(false, 0, error);

        public static bool IsValidWork(double work) => double.IsFinite(work) && work >= 0;
    }

    public sealed record ScaleDecision(
        string ServiceId,
        string ServiceName,
        int CurrentReplicas,
        int DesiredReplicas,
        double Work,
        string Reason,
        DateTimeOffset TimestampUtc
    );

    // =========================
    // Per-service state
    // =========================
    public sealed record ScaleRecommendation(
        DateTimeOffset TimestampUtc,
        int DesiredReplicas
    );

    public sealed class ServiceScaleState
    {
        private readonly List<ScaleRecommendation> _recommendationHistory = [];

        public int LastAppliedReplicas { get; set; }
        public DateTimeOffset? LastScaleUpUtc { get; set; }
        public DateTimeOffset? LastScaleDownUtc { get; set; }

        public IReadOnlyList<ScaleRecommendation> RecommendationHistory => _recommendationHistory;

        public void AddRecommendation(ScaleRecommendation recommendation) =>
            _recommendationHistory.Add(recommendation);

        public void RemoveRecommendationsOlderThan(DateTimeOffset cutoffUtc) =>
            _recommendationHistory.RemoveAll(recommendation => recommendation.TimestampUtc < cutoffUtc);

        public void ClearRecommendations() => _recommendationHistory.Clear();
    }

    // =========================
    // Ports / interfaces
    // =========================

    public interface ISwarmServiceClient
    {
        Task<IReadOnlyList<ServiceRef>> ListServicesAsync(CancellationToken ct);

        Task<ServiceRef> GetServiceAsync(string serviceId, CancellationToken ct);

        Task UpdateReplicasAsync(string serviceId, long versionIndex, int desiredReplicas, CancellationToken ct);
    }

    public interface IScaleConfigProvider
    {
        ScaleConfig? TryGetConfig(ServiceRef service, out string? error);
    }

    public interface ITriggerAdapter
    {
        string Type { get; }
        Task<TriggerResult> GetWorkAsync(ServiceRef service, ScaleConfig config, CancellationToken ct);
    }

    public interface ITriggerAdapterRegistry
    {
        bool TryResolve(string triggerType, out ITriggerAdapter adapter);
    }

    public interface IScalePolicy
    {
        ScaleDecision Decide(ServiceRef service, ScaleConfig config, TriggerResult trigger, ServiceScaleState state, DateTimeOffset nowUtc);
    }

    public interface IStateStore<TKey, TValue>
        where TKey : notnull
        where TValue : class, new()
    {
        TValue GetOrAdd(TKey key);
        void Remove(TKey key);
    }

    public interface IAutoscalerTelemetry
    {
        void RecordDecision(ScaleDecision decision);
        void RecordError(string serviceName, string stage, Exception ex);
    }

    public interface ILeaderElector
    {
        Task<bool> IsLeaderAsync(CancellationToken ct);
    }

    public interface IServiceUpdateStrategy
    {
        Task ApplyDesiredReplicasAsync(ISwarmServiceClient swarm, ServiceRef service, int desiredReplicas, CancellationToken ct);
    }
}
