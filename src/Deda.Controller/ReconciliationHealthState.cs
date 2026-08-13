using Deda.Core;

namespace Deda.Controller
{
    public sealed class ReconciliationHealthState : IReconciliationHealth
    {
        private readonly object _gate = new();
        private ReconciliationHealthSnapshot _snapshot = new(null, null, null, null);

        public ReconciliationHealthSnapshot Snapshot()
        {
            lock (_gate)
            {
                return _snapshot;
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
