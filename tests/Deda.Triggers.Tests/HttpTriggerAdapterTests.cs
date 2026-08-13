using Deda.Core;
using Deda.Triggers.Http;

using System.Net;

namespace Deda.Triggers.Tests;

public sealed class HttpTriggerAdapterTests
{
    [Theory]
    [InlineData("12.5", null, 12.5)]
    [InlineData("{\"value\":\"7\"}", null, 7)]
    [InlineData("{\"metrics\":{\"pending\":9}}", "metrics.pending", 9)]
    public async Task NumericResponsesReturnWork(string body, string? valuePath, double expected)
    {
        var adapter = Adapter((_, _) => Task.FromResult(Response(body)));

        var result = await adapter.GetWorkAsync(Service(), Config(valuePath), CancellationToken.None);

        Assert.True(result.Success);
        Assert.Equal(expected, result.Work);
    }

    [Fact]
    public async Task MissingValuePathReturnsClearFailure()
    {
        var adapter = Adapter((_, _) => Task.FromResult(Response("{\"metrics\":{}}")));

        var result = await adapter.GetWorkAsync(Service(), Config("metrics.pending"), CancellationToken.None);

        Assert.False(result.Success);
        Assert.Contains("valuePath", result.Error);
    }

    [Theory]
    [InlineData("-1")]
    [InlineData("NaN")]
    [InlineData("Infinity")]
    public async Task InvalidWorkValuesAreRejected(string body)
    {
        var adapter = Adapter((_, _) => Task.FromResult(Response(body)));

        var result = await adapter.GetWorkAsync(Service(), Config(), CancellationToken.None);

        Assert.False(result.Success);
    }

    [Fact]
    public async Task NonSuccessStatusReturnsFailure()
    {
        var adapter = Adapter((_, _) => Task.FromResult(Response("busy", HttpStatusCode.ServiceUnavailable)));

        var result = await adapter.GetWorkAsync(Service(), Config(), CancellationToken.None);

        Assert.False(result.Success);
        Assert.Contains("503", result.Error);
    }

    [Fact]
    public async Task InvalidUrlIsRejectedBeforeSendingRequest()
    {
        var adapter = Adapter((_, _) => throw new InvalidOperationException("should not send"));
        var config = Config() with
        {
            TriggerConfig = new Dictionary<string, string> { ["url"] = "file:///run/secrets/token" },
        };

        var result = await adapter.GetWorkAsync(Service(), config, CancellationToken.None);

        Assert.False(result.Success);
        Assert.Contains("HTTP or HTTPS", result.Error);
    }

    [Fact]
    public async Task CallerCancellationPropagates()
    {
        using var cts = new CancellationTokenSource();
        var adapter = Adapter((_, ct) =>
        {
            cts.Cancel();
            ct.ThrowIfCancellationRequested();
            return Task.FromResult(Response("1"));
        });

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => adapter.GetWorkAsync(Service(), Config(), cts.Token));
    }

    [Fact]
    public async Task ConfiguredTimeoutIsCapped()
    {
        using var client = new HttpClient(new StubHttpMessageHandler(
            (_, _) => Task.FromResult(Response("1"))));
        var adapter = new HttpTriggerAdapter(new SingleClientFactory(client));
        var config = Config() with
        {
            TriggerConfig = new Dictionary<string, string>
            {
                ["url"] = "https://metrics.example.test/value",
                ["timeoutSeconds"] = "999",
            },
        };

        await adapter.GetWorkAsync(Service(), config, CancellationToken.None);

        Assert.Equal(TimeSpan.FromSeconds(120), client.Timeout);
    }

    private static HttpTriggerAdapter Adapter(
        Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> handler)
    {
        var client = new HttpClient(new StubHttpMessageHandler(handler));
        return new HttpTriggerAdapter(new SingleClientFactory(client));
    }

    private static HttpResponseMessage Response(string body, HttpStatusCode status = HttpStatusCode.OK) =>
        new(status) { Content = new StringContent(body) };

    private static ServiceRef Service() =>
        new("id", "worker", 1, new Dictionary<string, string>(), 1, SwarmServiceMode.Replicated);

    private static ScaleConfig Config(string? valuePath = null)
    {
        var triggerConfig = new Dictionary<string, string>
        {
            ["url"] = "https://metrics.example.test/value",
        };
        if (valuePath is not null)
            triggerConfig["valuePath"] = valuePath;

        return new ScaleConfig { TriggerType = "http", TriggerConfig = triggerConfig };
    }
}
