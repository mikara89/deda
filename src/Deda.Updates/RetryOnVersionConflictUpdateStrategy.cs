using Deda.Core;

namespace Deda.Updates
{
    /// <summary>
    /// Applies replica updates with retries on Swarm optimistic concurrency conflicts.
    ///
    /// Expected conflict signal from ISwarmServiceClient:
    /// - throws InvalidOperationException with message containing "version conflict"
    ///
    /// Strategy:
    /// - attempt update
    /// - on conflict: reload service (fresh VersionIndex) and retry with backoff + jitter
    /// </summary>
    public sealed class RetryOnVersionConflictUpdateStrategy : IServiceUpdateStrategy
    {
        private readonly RetryOptions _options;
        private readonly IMutationGuard _guard;

        public RetryOnVersionConflictUpdateStrategy(RetryOptions? options = null, IMutationGuard? guard = null)
        {
            _options = options ?? RetryOptions.Default;
            _guard = guard ?? new NoOpMutationGuard();
        }

        public async Task ApplyDesiredReplicasAsync(
            ISwarmServiceClient swarm,
            ServiceRef service,
            int desiredReplicas,
            CancellationToken ct)
        {
            if (swarm is null) throw new ArgumentNullException(nameof(swarm));
            if (service is null) throw new ArgumentNullException(nameof(service));
            if (desiredReplicas < 0) throw new ArgumentOutOfRangeException(nameof(desiredReplicas));

            var current = service;

            for (int attempt = 1; attempt <= _options.MaxAttempts; attempt++)
            {
                ct.ThrowIfCancellationRequested();
                // This must happen inside the retry loop: a version conflict can
                // delay the next mutation long enough for a lease to be lost.
                await _guard.EnsureCanMutateAsync(ct).ConfigureAwait(false);

                try
                {
                    await swarm.UpdateReplicasAsync(
                        current.ServiceId,
                        current.VersionIndex,
                        desiredReplicas,
                        ct
                    ).ConfigureAwait(false);

                    return; // success
                }
                catch (Exception ex) when (IsVersionConflict(ex))
                {
                    if (attempt == _options.MaxAttempts)
                        throw;

                    // Reload fresh VersionIndex (and spec-derived current replicas/labels)
                    current = await swarm.GetServiceAsync(current.ServiceId, ct).ConfigureAwait(false);

                    // Backoff with jitter to reduce thundering herds
                    var delay = ComputeDelay(attempt);
                    await Task.Delay(delay, ct).ConfigureAwait(false);
                }
            }
        }

        private bool IsVersionConflict(Exception ex)
        {
            // We normalize conflicts in DockerSwarmServiceClient into:
            // new InvalidOperationException("version conflict", ex)
            if (ex is InvalidOperationException ioe &&
                (ioe.Message?.Contains("version conflict", StringComparison.OrdinalIgnoreCase) ?? false))
                return true;

            // Be tolerant if someone throws it differently
            if (ex.Message?.Contains("update out of sequence", StringComparison.OrdinalIgnoreCase) ?? false)
                return true;

            return false;
        }

        private TimeSpan ComputeDelay(int attempt)
        {
            // Exponential backoff: base * 2^(attempt-1), clamped
            var baseMs = _options.BaseDelay.TotalMilliseconds;
            var exp = baseMs * Math.Pow(2, attempt - 1);

            var clamped = Math.Min(exp, _options.MaxDelay.TotalMilliseconds);

            // Jitter: +/- JitterPercent
            var jitterRange = clamped * _options.JitterPercent;
            var jitter = (Random.Shared.NextDouble() * 2 - 1) * jitterRange;

            var finalMs = Math.Max(0, clamped + jitter);
            return TimeSpan.FromMilliseconds(finalMs);
        }

        public sealed record RetryOptions(
            int MaxAttempts,
            TimeSpan BaseDelay,
            TimeSpan MaxDelay,
            double JitterPercent)
        {
            public static RetryOptions Default { get; } = new(
                MaxAttempts: 6,
                BaseDelay: TimeSpan.FromMilliseconds(150),
                MaxDelay: TimeSpan.FromSeconds(2),
                JitterPercent: 0.20
            );
        }
    }
}
