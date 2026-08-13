using Deda.Core;
using Deda.Triggers.Prometheus;

namespace Deda.Triggers.Tests;

public sealed class PrometheusTriggerAdapterTests
{
    [Fact]
    public async Task ScalarResult_ReturnsMetricAndEncodesQuery()
    {
        Uri? requestUri = null;
        var adapter = Adapter((request, _) =>
        {
            requestUri = request.RequestUri;
            return Task.FromResult(Response("{\"status\":\"success\",\"data\":{\"resultType\":\"scalar\",\"result\":[1,\"12.5\"]}}"));
        });

        var result = await adapter.GetWorkAsync(Service(), Config(), CancellationToken.None);

        Assert.True(result.Success);
        Assert.Equal(12.5, result.Work);
        Assert.Contains("query=sum%28rate%28requests_total%5B1m%5D%29%29", requestUri?.Query);
    }

    [Fact]
    public async Task ExactlyOneVectorSeries_ReturnsMetric()
    {
        var result = await ExecuteJson(
            "{\"status\":\"success\",\"data\":{\"resultType\":\"vector\",\"result\":[{\"metric\":{\"job\":\"api\"},\"value\":[1,\"7\"]}]}}");

        Assert.True(result.Success);
        Assert.Equal(7, result.Work);
    }

    [Fact]
    public async Task MultipleVectorSeries_AreRejectedAsAmbiguous()
    {
        var result = await ExecuteJson(
            "{\"status\":\"success\",\"data\":{\"resultType\":\"vector\",\"result\":[{\"value\":[1,\"7\"]},{\"value\":[1,\"8\"]}]}}");

        Assert.False(result.Success);
        Assert.Contains("ambiguous", result.Error);
    }

    [Fact]
    public async Task EmptyVector_IsZeroWork()
    {
        var result = await ExecuteJson(
            "{\"status\":\"success\",\"data\":{\"resultType\":\"vector\",\"result\":[]}}");

        Assert.True(result.Success);
        Assert.Equal(0, result.Work);
    }

    [Theory]
    [InlineData("NaN")]
    [InlineData("Infinity")]
    [InlineData("-Infinity")]
    [InlineData("-1")]
    public async Task InvalidMetricValue_IsRejected(string value)
    {
        var result = await ExecuteJson(
            $"{{\"status\":\"success\",\"data\":{{\"resultType\":\"scalar\",\"result\":[1,\"{value}\"]}}}}");

        Assert.False(result.Success);
    }

    [Fact]
    public async Task UnsupportedResultType_IsRejected()
    {
        var result = await ExecuteJson(
            "{\"status\":\"success\",\"data\":{\"resultType\":\"matrix\",\"result\":[]}}");

        Assert.False(result.Success);
        Assert.Contains("unsupported result type", result.Error);
    }

    [Fact]
    public async Task Timeout_ReturnsFailureAndCapsConfiguredTimeout()
    {
        var handler = new StubHttpMessageHandler((_, _) =>
            Task.FromException<HttpResponseMessage>(new TaskCanceledException("timeout")));
        using var client = new HttpClient(handler);
        var adapter = new PrometheusTriggerAdapter(new SingleClientFactory(client));

        var result = await adapter.GetWorkAsync(
            Service(),
            Config(("timeoutSeconds", "999")),
            CancellationToken.None);

        Assert.False(result.Success);
        Assert.Equal(TimeSpan.FromSeconds(120), client.Timeout);
    }

    [Fact]
    public async Task CallerCancellation_Propagates()
    {
        using var cts = new CancellationTokenSource();
        var adapter = Adapter((_, ct) =>
        {
            cts.Cancel();
            return Task.FromCanceled<HttpResponseMessage>(ct);
        });

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => adapter.GetWorkAsync(Service(), Config(), cts.Token));
    }

    private static Task<TriggerResult> ExecuteJson(string json)
    {
        var adapter = Adapter((_, _) => Task.FromResult(Response(json)));
        return adapter.GetWorkAsync(Service(), Config(), CancellationToken.None);
    }

    private static PrometheusTriggerAdapter Adapter(
        Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> handler) =>
        new(new SingleClientFactory(new HttpClient(new StubHttpMessageHandler(handler))));

    private static HttpResponseMessage Response(string json) => StubHttpMessageHandler.Json(json);

    private static ServiceRef Service() =>
        new("service-1", "api", 1, new Dictionary<string, string>(), 1, SwarmServiceMode.Replicated);

    private static ScaleConfig Config(params (string Key, string Value)[] values)
    {
        var triggerConfig = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["url"] = "http://prometheus:9090",
            ["query"] = "sum(rate(requests_total[1m]))",
        };
        foreach (var (key, value) in values)
            triggerConfig[key] = value;

        return new ScaleConfig { TriggerType = "prometheus", TriggerConfig = triggerConfig };
    }
}
