using Deda.Core;

namespace Deda.Controller
{

    public sealed record HostOptions(
        int PollSeconds,
        int MaxServicesPerCycle,
        bool JitterEnabled);
    public sealed class AutoscalerController
    {
        private readonly ISwarmServiceClient _swarm;
        private readonly IScaleConfigProvider _configProvider;
        private readonly ITriggerAdapterRegistry _triggers;
        private readonly IScalePolicy _policy;
        private readonly IStateStore<string, ServiceScaleState> _stateStore;
        private readonly IAutoscalerTelemetry _telemetry;
        private readonly IServiceUpdateStrategy _updates;
        private readonly ILeaderElector? _leader;
        private readonly HostOptions _hostOptions;

        public AutoscalerController(
            ISwarmServiceClient swarm,
            IScaleConfigProvider configProvider,
            ITriggerAdapterRegistry triggers,
            IScalePolicy policy,
            IStateStore<string, ServiceScaleState> stateStore,
            IAutoscalerTelemetry telemetry,
            IServiceUpdateStrategy updates,
            HostOptions HostOptions,
            ILeaderElector? leader = null)
        {
            _swarm = swarm;
            _configProvider = configProvider;
            _triggers = triggers;
            _policy = policy;
            _stateStore = stateStore;
            _telemetry = telemetry;
            _updates = updates;
            _leader = leader;
            _hostOptions = HostOptions;
        }

        public async Task ReconcileOnceAsync(CancellationToken ct)
        {
            if (_leader is not null)
            {
                if (!await _leader.IsLeaderAsync(ct).ConfigureAwait(false))
                    return;
            }

            var now = DateTimeOffset.UtcNow;

            var services = await _swarm.ListServicesAsync(ct).ConfigureAwait(false);

            var list = services;

            // Stable order by hash(serviceId) so jitter is consistent
            if (_hostOptions.JitterEnabled)
            {
                list = list.OrderBy(s => StableHash(s.ServiceId)).ToList();
            }

            // Cap per cycle (prevents long cycles when you hit 100 services)
            if (_hostOptions.MaxServicesPerCycle > 0 && list.Count > _hostOptions.MaxServicesPerCycle)
            {
                // Round-robin page selection based on time bucket
                var bucket = (int)(DateTimeOffset.UtcNow.ToUnixTimeSeconds() / _hostOptions.PollSeconds);
                var start = (bucket * _hostOptions.MaxServicesPerCycle) % list.Count;
                list = TakeWrap(list, start, _hostOptions.MaxServicesPerCycle);
            }

            foreach (var svc in list)
            {
                ct.ThrowIfCancellationRequested();

                try
                {
                    if (svc.Mode == SwarmServiceMode.Global)
                        continue;

                    var cfg = _configProvider.TryGetConfig(svc, out var cfgError);
                    if (cfg is null)
                    {
                        if (!string.IsNullOrWhiteSpace(cfgError))
                            _telemetry.RecordError(svc.Name, "config", new InvalidOperationException(cfgError));
                        continue;
                    }

                    if (!_triggers.TryResolve(cfg.TriggerType, out var adapter))
                        continue;

                    var state = _stateStore.GetOrAdd(svc.ServiceId);

                    var trigger = await adapter.GetWorkAsync(svc, cfg, ct).ConfigureAwait(false);

                    var decision = _policy.Decide(svc, cfg, trigger, state, now);
                    _telemetry.RecordDecision(decision);

                    if (decision.DesiredReplicas != decision.CurrentReplicas)
                    {
                        await _updates.ApplyDesiredReplicasAsync(_swarm, svc, decision.DesiredReplicas, ct)
                            .ConfigureAwait(false);

                        if (decision.DesiredReplicas > decision.CurrentReplicas)
                            state.LastScaleUpUtc = now;
                        else
                            state.LastScaleDownUtc = now;

                        state.LastAppliedReplicas = decision.DesiredReplicas;
                    }
                }
                catch (Exception ex)
                {
                    _telemetry.RecordError(svc.Name, "reconcile", ex);
                }
            }
        }

        private static int StableHash(string s)
        {
            unchecked
            {
                int h = 23;
                foreach (var c in s)
                    h = (h * 31) + c;
                return h;
            }
        }

        private static List<ServiceRef> TakeWrap(IReadOnlyList<ServiceRef> list, int start, int count)
        {
            var res = new List<ServiceRef>(count);
            for (int i = 0; i < count; i++)
                res.Add(list[(start + i) % list.Count]);
            return res;
        }
    }
}
