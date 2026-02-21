namespace Deda.Core.Tests;

public class RingBufferTests
{
    [Fact]
    public void Add_SingleItem_CountIsOne()
    {
        var buf = new RingBuffer<int>(5);
        buf.Add(42);
        Assert.Equal(1, buf.Count);
    }

    [Fact]
    public void Add_BeyondCapacity_CountCapsAtCapacity()
    {
        var buf = new RingBuffer<int>(3);
        buf.Add(1);
        buf.Add(2);
        buf.Add(3);
        buf.Add(4);
        Assert.Equal(3, buf.Count);
    }

    [Fact]
    public void Snapshot_ReturnsOldestToNewest()
    {
        var buf = new RingBuffer<int>(4);
        buf.Add(10);
        buf.Add(20);
        buf.Add(30);

        var snap = buf.Snapshot();

        Assert.Equal([10, 20, 30], snap);
    }

    [Fact]
    public void Snapshot_AfterWrapAround_ReturnsOldestToNewest()
    {
        var buf = new RingBuffer<int>(3);
        buf.Add(1);
        buf.Add(2);
        buf.Add(3);
        buf.Add(4); // overwrites slot 0 (value 1)

        var snap = buf.Snapshot();

        Assert.Equal([2, 3, 4], snap);
    }

    [Fact]
    public void Snapshot_EmptyBuffer_ReturnsEmpty()
    {
        var buf = new RingBuffer<double>(10);
        Assert.Empty(buf.Snapshot());
    }

    [Fact]
    public void Snapshot_FullBuffer_CountEqualsCapacity()
    {
        var buf = new RingBuffer<int>(5);
        for (int i = 0; i < 5; i++) buf.Add(i);
        Assert.Equal(5, buf.Count);
        Assert.Equal(5, buf.Snapshot().Count);
    }

    [Fact]
    public void Add_ManyItems_OnlyLastCapacityRetained()
    {
        var buf = new RingBuffer<int>(3);
        for (int i = 1; i <= 10; i++) buf.Add(i);

        var snap = buf.Snapshot();

        Assert.Equal([8, 9, 10], snap);
    }

    [Fact]
    public void Constructor_ZeroCapacity_Throws()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => new RingBuffer<int>(0));
    }

    [Fact]
    public void Constructor_NegativeCapacity_Throws()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => new RingBuffer<int>(-1));
    }
}
