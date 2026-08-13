using Deda.Core;
using System.Diagnostics;

namespace Deda.Controller
{
    public sealed record ReconcileLoopOptions(
        TimeSpan PollInterval,
        TimeSpan MaxFailureBackoff,
        TimeSpan? CycleTimeout = null);

    public sealed class ResilientReconcileRunner
    {
        private readonly AutoscalerController _controller;
        private readonly IReconciliationHealth _health;
        private readonly IAutoscalerTelemetry _telemetry;
        private readonly ReconcileLoopOptions _options;
        private readonly TimeProvider _timeProvider;
        private int _consecutiveFailures;

        public ResilientReconcileRunner(
            AutoscalerController controller,
            IReconciliationHealth health,
            IAutoscalerTelemetry telemetry,
            ReconcileLoopOptions options,
            TimeProvider timeProvider)
        {
            _controller = controller;
            _health = health;
            _telemetry = telemetry;
            _options = options;
            _timeProvider = timeProvider;
        }

        public async Task<TimeSpan> RunOnceAsync(CancellationToken ct)
        {
            _health.RecordAttempt(_timeProvider.GetUtcNow());
            var started = Stopwatch.GetTimestamp();
            using var operation = _telemetry.StartOperation("reconcile");

            try
            {
                using var cycleCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
                if (_options.CycleTimeout is { } timeout)
                    cycleCts.CancelAfter(timeout);
                await _controller.ReconcileOnceAsync(cycleCts?.Token ?? ct).ConfigureAwait(false);
                _consecutiveFailures = 0;
                _health.RecordSuccess(_timeProvider.GetUtcNow());
                _telemetry.RecordReconcile(Stopwatch.GetElapsedTime(started), success: true);
                return NormalizeDelay(_options.PollInterval);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                throw;
            }
            catch (Exception ex)
            {
                _consecutiveFailures++;
                _health.RecordFailure(_timeProvider.GetUtcNow(), ex);
                _telemetry.RecordError("controller", "reconcile_loop", ex);
                _telemetry.RecordReconcile(Stopwatch.GetElapsedTime(started), success: false);
                return CalculateFailureBackoff();
            }
        }

        private TimeSpan CalculateFailureBackoff()
        {
            var poll = NormalizeDelay(_options.PollInterval);
            var maximum = NormalizeDelay(_options.MaxFailureBackoff);
            var exponent = Math.Min(_consecutiveFailures - 1, 30);
            var seconds = poll.TotalSeconds * Math.Pow(2, exponent);
            return TimeSpan.FromSeconds(Math.Min(seconds, maximum.TotalSeconds));
        }

        private static TimeSpan NormalizeDelay(TimeSpan delay) =>
            delay > TimeSpan.Zero ? delay : TimeSpan.FromSeconds(1);
    }
}
