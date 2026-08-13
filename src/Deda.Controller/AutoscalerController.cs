using Deda.Core;

using System.Diagnostics;

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
            HostOptions hostOptions,
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
            _hostOptions = hostOptions;
        }

        public async Task ReconcileOnceAsync(CancellationToken ct)
        {
            if (_leader is not null)
            {
                if (!await _leader.IsLeaderAsync(ct).ConfigureAwait(false))
                    return;
            }

            var now = DateTimeOffset.UtcNow;

            IReadOnlyList<ServiceRef> services;
            using (_telemetry.StartOperation("discover services"))
            {
                services = await _swarm.ListServicesAsync(ct).ConfigureAwait(false);
            }

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
                    using var serviceOperation = _telemetry.StartOperation("service evaluation", svc.Name);

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
                    {
                        _telemetry.RecordError(
                            svc.Name,
                            "trigger",
                            new InvalidOperationException($"Unknown trigger type '{cfg.TriggerType}'."));
                        continue;
                    }

                    var state = _stateStore.GetOrAdd(svc.ServiceId);

                    TriggerResult trigger;
                    var triggerStarted = Stopwatch.GetTimestamp();
                    using (_telemetry.StartOperation("trigger", svc.Name, cfg.TriggerType))
                    {
                        trigger = await adapter.GetWorkAsync(svc, cfg, ct).ConfigureAwait(false);
                    }
                    _telemetry.RecordTrigger(
                        svc.Name,
                        cfg.TriggerType,
                        Stopwatch.GetElapsedTime(triggerStarted),
                        trigger);

                    ScaleDecision decision;
                    using (_telemetry.StartOperation("scale decision", svc.Name, cfg.TriggerType))
                    {
                        decision = _policy.Decide(svc, cfg, trigger, state, now);
                    }
                    _telemetry.RecordDecision(decision);

                    if (decision.DesiredReplicas != decision.CurrentReplicas)
                    {
                        // Re-check immediately before the mutating call. The Redis
                        // heartbeat can revoke leadership during a long trigger request.
                        if (_leader is not null &&
                            !await _leader.IsLeaderAsync(ct).ConfigureAwait(false))
                            return;

                        using (_telemetry.StartOperation("update replicas", svc.Name, cfg.TriggerType))
                        {
                            await _updates.ApplyDesiredReplicasAsync(_swarm, svc, decision.DesiredReplicas, ct)
                                .ConfigureAwait(false);
                        }

                        if (decision.DesiredReplicas > decision.CurrentReplicas)
                            state.LastScaleUpUtc = now;
                        else
                            state.LastScaleDownUtc = now;

                        state.LastAppliedReplicas = decision.DesiredReplicas;
                    }
                }
                catch (OperationCanceledException) when (ct.IsCancellationRequested)
                {
                    throw;
                }
                catch (LeaderElectionUnavailableException)
                {
                    // Infrastructure failure must reach the reconciliation runner so
                    // readiness becomes unhealthy. False leadership is normal standby.
                    throw;
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
