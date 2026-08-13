using Deda.Core;
using Microsoft.Extensions.Logging;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Diagnostics.Metrics;

namespace Deda.Observability
{
    public static class DedaDiagnostics
    {
        public const string SourceName = "Deda.Autoscaler";
        public static readonly ActivitySource Activities = new(SourceName);
        public static readonly Meter Meter = new(SourceName);
    }

    public sealed class OpenTelemetryAutoscalerTelemetry : IAutoscalerTelemetry
    {
        private static readonly Counter<long> Reconciles = DedaDiagnostics.Meter.CreateCounter<long>("deda_reconcile_total");
        private static readonly Counter<long> ReconcileFailures = DedaDiagnostics.Meter.CreateCounter<long>("deda_reconcile_failures_total");
        internal static readonly Histogram<double> ReconcileDuration = DedaDiagnostics.Meter.CreateHistogram<double>("deda_reconcile_duration_seconds", "s");
        internal static readonly Counter<long> TriggerRequests = DedaDiagnostics.Meter.CreateCounter<long>("deda_trigger_requests_total");
        private static readonly Counter<long> TriggerFailures = DedaDiagnostics.Meter.CreateCounter<long>("deda_trigger_failures_total");
        internal static readonly Histogram<double> TriggerDuration = DedaDiagnostics.Meter.CreateHistogram<double>("deda_trigger_duration_seconds", "s");
        private static readonly Counter<long> ScaleDecisions = DedaDiagnostics.Meter.CreateCounter<long>("deda_scale_decisions_total");
        internal static readonly Counter<long> ScaleEvents = DedaDiagnostics.Meter.CreateCounter<long>("deda_scale_events_total");
        private static readonly ConcurrentDictionary<TriggerMetricKey, double> TriggerValues = new();
        private static readonly ConcurrentDictionary<string, int> CurrentReplicaValues = new(StringComparer.Ordinal);
        private static readonly ConcurrentDictionary<string, int> DesiredReplicaValues = new(StringComparer.Ordinal);
        internal static readonly ObservableGauge<double> TriggerValue = DedaDiagnostics.Meter.CreateObservableGauge(
            "deda_trigger_value",
            ObserveTriggerValues);
        internal static readonly ObservableGauge<int> CurrentReplicas = DedaDiagnostics.Meter.CreateObservableGauge(
            "deda_current_replicas",
            ObserveCurrentReplicas);
        internal static readonly ObservableGauge<int> DesiredReplicas = DedaDiagnostics.Meter.CreateObservableGauge(
            "deda_desired_replicas",
            ObserveDesiredReplicas);

        private readonly ILogger<OpenTelemetryAutoscalerTelemetry> _logger;

        public OpenTelemetryAutoscalerTelemetry(ILogger<OpenTelemetryAutoscalerTelemetry> logger)
        {
            _logger = logger;
        }

        public IDisposable? StartOperation(string operation, string? serviceName = null, string? triggerType = null)
        {
            var activity = DedaDiagnostics.Activities.StartActivity(operation, ActivityKind.Internal);
            activity?.SetTag("service.name", serviceName);
            activity?.SetTag("deda.trigger.type", triggerType);
            return activity;
        }

        public void RecordReconcile(TimeSpan duration, bool success)
        {
            var result = success ? "success" : "failure";
            Reconciles.Add(1, new KeyValuePair<string, object?>("result", result));
            ReconcileDuration.Record(duration.TotalSeconds, new KeyValuePair<string, object?>("result", result));
            if (!success)
                ReconcileFailures.Add(1);
        }

        public void RecordTrigger(string serviceName, string triggerType, TimeSpan duration, TriggerResult result)
        {
            var tags = new TagList
            {
                { "service", serviceName },
                { "trigger", triggerType },
                { "result", result.Success ? "success" : "failure" },
            };
            TriggerRequests.Add(1, tags);
            TriggerDuration.Record(duration.TotalSeconds, tags);
            if (result.Success)
                TriggerValues[new TriggerMetricKey(serviceName, triggerType)] = result.Work;
            else
            {
                TriggerValues.TryRemove(new TriggerMetricKey(serviceName, triggerType), out _);
                TriggerFailures.Add(1, tags);
            }
        }

        public void RecordDecision(ScaleDecision decision)
        {
            var direction = decision.DesiredReplicas.CompareTo(decision.CurrentReplicas) switch
            {
                > 0 => "up",
                < 0 => "down",
                _ => "hold",
            };
            var tags = new TagList
            {
                { "service", decision.ServiceName },
                { "direction", direction },
            };
            ScaleDecisions.Add(1, tags);
            if (direction != "hold")
                ScaleEvents.Add(1, tags);
            CurrentReplicaValues[decision.ServiceName] = decision.CurrentReplicas;
            DesiredReplicaValues[decision.ServiceName] = decision.DesiredReplicas;

            _logger.LogInformation(
                "Scale decision for {ServiceName}: work={Work} replicas={CurrentReplicas}->{DesiredReplicas} direction={Direction} reason={Reason}",
                decision.ServiceName,
                decision.Work,
                decision.CurrentReplicas,
                decision.DesiredReplicas,
                direction,
                decision.Reason);
        }

        public void RecordError(string serviceName, string stage, Exception ex)
        {
            Activity.Current?.SetStatus(ActivityStatusCode.Error, ex.Message);
            Activity.Current?.AddException(ex);
            _logger.LogError(ex, "Autoscaler error for {ServiceName} during {Stage}", serviceName, stage);
        }

        private static IEnumerable<Measurement<double>> ObserveTriggerValues()
        {
            foreach (var entry in TriggerValues)
            {
                yield return new Measurement<double>(entry.Value,
                    new KeyValuePair<string, object?>("service", entry.Key.ServiceName),
                    new KeyValuePair<string, object?>("trigger", entry.Key.TriggerType));
            }
        }

        private static IEnumerable<Measurement<int>> ObserveCurrentReplicas() =>
            ObserveReplicaValues(CurrentReplicaValues);

        private static IEnumerable<Measurement<int>> ObserveDesiredReplicas() =>
            ObserveReplicaValues(DesiredReplicaValues);

        private static IEnumerable<Measurement<int>> ObserveReplicaValues(
            ConcurrentDictionary<string, int> values)
        {
            foreach (var entry in values)
            {
                yield return new Measurement<int>(entry.Value,
                    new KeyValuePair<string, object?>("service", entry.Key));
            }
        }

        private readonly record struct TriggerMetricKey(string ServiceName, string TriggerType);
    }
}
