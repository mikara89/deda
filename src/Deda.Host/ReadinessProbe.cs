using Deda.Core;

namespace Deda.Host
{
    public sealed class ReadinessProbe
    {
        private readonly ISwarmServiceClient _swarm;
        private volatile bool _ok;
        private volatile string _detail = "starting";

        public ReadinessProbe(ISwarmServiceClient swarm)
        {
            _swarm = swarm;
        }

        public async Task CheckAsync(CancellationToken ct)
        {
            try
            {
                // Minimal: can we list services?
                _ = await _swarm.ListServicesAsync(ct).ConfigureAwait(false);
                _ok = true;
                _detail = "ok";
            }
            catch (Exception ex)
            {
                _ok = false;
                _detail = $"{ex.GetType().Name}: {ex.Message}";
            }
        }

        public (bool ok, string detail) Snapshot() => (_ok, _detail);
    }
}
