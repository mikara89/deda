using Deda.Core;
using Microsoft.Extensions.Logging;
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
        private static readonly Histogram<double> ReconcileDuration = DedaDiagnostics.Meter.CreateHistogram<double>("deda_reconcile_duration_seconds", "s");
        private static readonly Counter<long> TriggerRequests = DedaDiagnostics.Meter.CreateCounter<long>("deda_trigger_requests_total");
        private static readonly Counter<long> TriggerFailures = DedaDiagnostics.Meter.CreateCounter<long>("deda_trigger_failures_total");
        private static readonly Histogram<double> TriggerDuration = DedaDiagnostics.Meter.CreateHistogram<double>("deda_trigger_duration_seconds", "s");
        private static readonly Histogram<double> TriggerValue = DedaDiagnostics.Meter.CreateHistogram<double>("deda_trigger_value");
        private static readonly Counter<long> ScaleDecisions = DedaDiagnostics.Meter.CreateCounter<long>("deda_scale_decisions_total");
        private static readonly Counter<long> ScaleEvents = DedaDiagnostics.Meter.CreateCounter<long>("deda_scale_events_total");
        private static readonly Histogram<int> CurrentReplicas = DedaDiagnostics.Meter.CreateHistogram<int>("deda_current_replicas");
        private static readonly Histogram<int> DesiredReplicas = DedaDiagnostics.Meter.CreateHistogram<int>("deda_desired_replicas");

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
                TriggerValue.Record(result.Work, tags);
            else
                TriggerFailures.Add(1, tags);
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
            CurrentReplicas.Record(decision.CurrentReplicas, tags);
            DesiredReplicas.Record(decision.DesiredReplicas, tags);

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
    }
}
