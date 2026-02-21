namespace Deda.Core
{
    public sealed class RingBuffer<T>
    {
        private readonly T[] _buffer;
        private int _count;
        private int _index;

        public RingBuffer(int capacity)
        {
            if (capacity <= 0) throw new ArgumentOutOfRangeException(nameof(capacity));
            _buffer = new T[capacity];
        }

        public int Count => _count;
        public int Capacity => _buffer.Length;

        public void Add(T item)
        {
            _buffer[_index] = item;
            _index = (_index + 1) % _buffer.Length;
            if (_count < _buffer.Length) _count++;
        }

        // Oldest -> newest snapshot
        public IReadOnlyList<T> Snapshot()
        {
            var result = new List<T>(_count);
            int start = _count < _buffer.Length ? 0 : _index;

            for (int i = 0; i < _count; i++)
                result.Add(_buffer[(start + i) % _buffer.Length]);

            return result;
        }
    }
}
