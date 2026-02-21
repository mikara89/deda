using System.Collections.Concurrent;
using System.Globalization;
using System.Text;

namespace Deda.Host
{
    public interface IMetricsRegistry
    {
        void IncCounter(string name, double by = 1);
        void SetGauge(string name, double value);
        void ObserveSeconds(string name, double seconds);
        string RenderPrometheus();
    }

    public sealed class MetricsRegistry : IMetricsRegistry
    {
        private readonly ConcurrentDictionary<string, double> _counters = new();
        private readonly ConcurrentDictionary<string, double> _gauges = new();
        private readonly ConcurrentDictionary<string, SummaryState> _summaries = new();

        public void IncCounter(string name, double by = 1)
            => _counters.AddOrUpdate(name, by, (_, v) => v + by);

        public void SetGauge(string name, double value)
            => _gauges.AddOrUpdate(name, value, (_, __) => value);

        public void ObserveSeconds(string name, double seconds)
            => _summaries.AddOrUpdate(name,
                _ => new SummaryState(seconds),
                (_, s) => s.Add(seconds));

        public string RenderPrometheus()
        {
            var sb = new StringBuilder(8_000);

            foreach (var kv in _counters)
                sb.Append(kv.Key).Append(' ').Append(kv.Value.ToString(CultureInfo.InvariantCulture)).Append('\n');

            foreach (var kv in _gauges)
                sb.Append(kv.Key).Append(' ').Append(kv.Value.ToString(CultureInfo.InvariantCulture)).Append('\n');

            // Summary-ish (count + sum). Not full Prom summary/histogram, but useful.
            foreach (var kv in _summaries)
            {
                sb.Append(kv.Key).Append("_count ").Append(kv.Value.Count.ToString(CultureInfo.InvariantCulture)).Append('\n');
                sb.Append(kv.Key).Append("_sum ").Append(kv.Value.Sum.ToString(CultureInfo.InvariantCulture)).Append('\n');
            }

            return sb.ToString();
        }

        private sealed class SummaryState
        {
            public long Count { get; private set; }
            public double Sum { get; private set; }

            public SummaryState(double first)
            {
                Count = 1;
                Sum = first;
            }

            public SummaryState Add(double v)
            {
                Count++;
                Sum += v;
                return this;
            }
        }
    }
}
