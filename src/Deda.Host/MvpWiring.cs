using Deda.Core;
using System.Collections.Concurrent;

namespace Deda.Host
{
    public sealed class InMemoryStateStoreMvp : IStateStore<string, ServiceScaleState>
    {
        private readonly ConcurrentDictionary<string, ServiceScaleState> _dict = new();
        public ServiceScaleState GetOrAdd(string key) => _dict.GetOrAdd(key, _ => new ServiceScaleState());
        public void Remove(string key) => _dict.TryRemove(key, out _);
    }

    public sealed class ConsoleTelemetryMvp : IAutoscalerTelemetry
    {
        private readonly IMetricsRegistry _metrics;
        private readonly DedaHostOptions _opts;

        public ConsoleTelemetryMvp(IMetricsRegistry metrics, DedaHostOptions opts)
        {
            _metrics = metrics;
            _opts = opts;
        }

        public void RecordDecision(ScaleDecision d)
        {
            if (_opts.LogDecisions)
                Console.WriteLine($"[{d.TimestampUtc:HH:mm:ss}] {d.ServiceName} work={d.Work:0.##} {d.CurrentReplicas}->{d.DesiredReplicas} | {d.Reason}");

            var trigger = ExtractTriggerType(d.Reason);

            // Counters
            _metrics.IncCounter("deda_scale_decisions_total", 1);
            if (d.DesiredReplicas > d.CurrentReplicas)
                _metrics.IncCounter($"deda_scale_events_total{{service=\"{San(d.ServiceName)}\",direction=\"up\"}}", 1);
            else if (d.DesiredReplicas < d.CurrentReplicas)
                _metrics.IncCounter($"deda_scale_events_total{{service=\"{San(d.ServiceName)}\",direction=\"down\"}}", 1);

            // Gauges
            _metrics.SetGauge($"deda_current_replicas{{service=\"{San(d.ServiceName)}\"}}", d.CurrentReplicas);
            _metrics.SetGauge($"deda_desired_replicas{{service=\"{San(d.ServiceName)}\"}}", d.DesiredReplicas);
            _metrics.SetGauge($"deda_trigger_value{{service=\"{San(d.ServiceName)}\",trigger=\"{San(trigger)}\"}}", d.Work);
        }

        public void RecordError(string serviceName, string stage, Exception ex)
        {
            Console.WriteLine($"ERROR {serviceName} stage={stage}: {ex.GetType().Name}: {ex.Message}");
            _metrics.IncCounter($"deda_errors_total{{service=\"{San(serviceName)}\",stage=\"{San(stage)}\"}}", 1);
        }

        private static string ExtractTriggerType(string reason)
        {
            // expects "... trig=rabbitmq" or "... trig=prometheus"
            const string key = "trig=";
            if (string.IsNullOrWhiteSpace(reason)) return "unknown";

            var idx = reason.IndexOf(key, StringComparison.OrdinalIgnoreCase);
            if (idx < 0) return "unknown";

            var rest = reason.Substring(idx + key.Length).Trim();
            if (rest.Length == 0) return "unknown";

            var end = rest.IndexOfAny(new[] { ' ', '|', ',', ';' });
            return end >= 0 ? rest.Substring(0, end) : rest;
        }

        private static string San(string s)
            => (s ?? string.Empty).Replace("\\", "\\\\").Replace("\"", "\\\"");
    }
}
