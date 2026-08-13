using Deda.Core;

namespace Deda.HA;

/// <summary>Fails closed immediately before every Swarm mutation attempt.</summary>
public sealed class LeaderMutationGuard(ILeaderElector leader) : IMutationGuard
{
    public async Task EnsureCanMutateAsync(CancellationToken ct)
    {
        if (!await leader.IsLeaderAsync(ct).ConfigureAwait(false))
            throw new InvalidOperationException("DEDA is no longer the active leader; mutation aborted.");
    }
}
