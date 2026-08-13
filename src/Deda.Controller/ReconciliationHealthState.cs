using Deda.Core;

namespace Deda.Controller
{
    public sealed class ReconciliationHealthState : IReconciliationHealth
    {
        private readonly TimeProvider _timeProvider;
        private readonly TimeSpan? _maxSuccessAge;
        private readonly object _gate = new();
        private ReconciliationHealthSnapshot _snapshot = new(null, null, null, null);

        public ReconciliationHealthState(TimeProvider? timeProvider = null, TimeSpan? maxSuccessAge = null)
        {
            _timeProvider = timeProvider ?? TimeProvider.System;
            _maxSuccessAge = maxSuccessAge;
        }

        public ReconciliationHealthSnapshot Snapshot()
        {
            lock (_gate)
            {
                var fresh = _maxSuccessAge is null || (_snapshot.LastSuccessfulUtc is { } success && _timeProvider.GetUtcNow() - success <= _maxSuccessAge.Value);
                return _snapshot with { IsReady = _snapshot.IsReady && fresh };
            }
        }

        public void RecordAttempt(DateTimeOffset timestampUtc)
        {
            lock (_gate)
            {
                _snapshot = _snapshot with { LastAttemptUtc = timestampUtc };
            }
        }

        public void RecordSuccess(DateTimeOffset timestampUtc)
        {
            lock (_gate)
            {
                _snapshot = _snapshot with
                {
                    LastSuccessfulUtc = timestampUtc,
                    LastError = null,
                    IsReady = true,
                };
            }
        }

        public void RecordFailure(DateTimeOffset timestampUtc, Exception exception)
        {
            ArgumentNullException.ThrowIfNull(exception);

            lock (_gate)
            {
                _snapshot = _snapshot with
                {
                    LastFailureUtc = timestampUtc,
                    LastError = $"{exception.GetType().Name}: {exception.Message}",
                    IsReady = false,
                };
            }
        }
    }
}
