using Deda.Core;

namespace Deda.Triggers.Ci;

public interface ICiQueueProvider
{
    string Type { get; }
    Task<CiQueueSnapshot> GetQueueAsync(ServiceRef service, ScaleConfig config, CancellationToken cancellationToken);
}

public abstract class CiTriggerAdapter(ICiQueueProvider provider, CiObservationCache? cache = null) : ITriggerAdapter
{
    private readonly CiObservationCache _cache = cache ?? new CiObservationCache();
    public string Type => provider.Type;
    public async Task<TriggerResult> GetWorkAsync(ServiceRef service, ScaleConfig config, CancellationToken ct)
    {
        try
        {
            var snapshot = await _cache.GetAsync(
                Type,
                service,
                config,
                providerCt => provider.GetQueueAsync(service, config, providerCt),
                ct).ConfigureAwait(false);
            if (snapshot.Queued < 0 || snapshot.Active < 0) return TriggerResult.Fail("CI provider returned negative capacity.");
            CiDiagnostics.Record(Type, service.Name, snapshot);
            return TriggerResult.Ok(snapshot.RequiredCapacity);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
        catch (Exception ex)
        {
            CiDiagnostics.Failure(Type);
            return TriggerResult.Fail($"{Type}: {ex.GetType().Name}: {ex.Message}");
        }
    }
}
