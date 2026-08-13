using Deda.Core;
using System.Collections.Concurrent;

namespace Deda.Host
{
    public sealed class InMemoryStateStore : IStateStore<string, ServiceScaleState>
    {
        private readonly ConcurrentDictionary<string, ServiceScaleState> _states = new();

        public ServiceScaleState GetOrAdd(string key) =>
            _states.GetOrAdd(key, _ => new ServiceScaleState());

        public void Remove(string key) => _states.TryRemove(key, out _);
    }
}
