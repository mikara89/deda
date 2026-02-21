using Deda.Core;

namespace Deda.Triggers.Abstractions
{
    public sealed class TriggerAdapterRegistry : ITriggerAdapterRegistry
    {
        private readonly Dictionary<string, ITriggerAdapter> _byType;

        public TriggerAdapterRegistry(IEnumerable<ITriggerAdapter> adapters)
        {
            _byType = adapters.ToDictionary(a => a.Type, StringComparer.OrdinalIgnoreCase);
        }

        public bool TryResolve(string triggerType, out ITriggerAdapter adapter)
            => _byType.TryGetValue(triggerType ?? string.Empty, out adapter!);
    }
}
