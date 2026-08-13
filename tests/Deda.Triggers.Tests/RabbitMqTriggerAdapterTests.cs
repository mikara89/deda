using Deda.Core;
using Deda.Triggers.RabbitMq;
using System.Net;
using System.Net.Http.Headers;
using System.Text;

namespace Deda.Triggers.Tests;

public sealed class RabbitMqTriggerAdapterTests
{
    [Fact]
    public async Task SuccessfulRequest_UsesBasicAuthEncodedPathAndConfiguredMetric()
    {
        AuthenticationHeaderValue? authorization = null;
        Uri? requestUri = null;
        var handler = new StubHttpMessageHandler((request, _) =>
        {
            authorization = request.Headers.Authorization;
            requestUri = request.RequestUri;
            return Task.FromResult(StubHttpMessageHandler.Json("{\"messages_ready\":12}"));
        });
        using var client = new HttpClient(handler);
        var adapter = new RabbitMqTriggerAdapter(
            new SingleClientFactory(client),
            new StaticCredentialsProvider("alice", "s3cret"));

        var result = await adapter.GetWorkAsync(
            Service(),
            Config(("vhost", "/"), ("queue", "orders/a"), ("metric", "messages_ready")),
            CancellationToken.None);

        Assert.True(result.Success);
        Assert.Equal(12, result.Work);
        Assert.Equal("Basic", authorization?.Scheme);
        Assert.Equal(
            Convert.ToBase64String(Encoding.UTF8.GetBytes("alice:s3cret")),
            authorization?.Parameter);
        Assert.Contains("/api/queues/%2F/orders%2Fa", requestUri?.AbsoluteUri);
    }

    [Fact]
    public async Task AuthenticationFailure_ReturnsHttpFailureWithoutThrowing()
    {
        var adapter = AdapterReturning(
            new HttpResponseMessage(HttpStatusCode.Unauthorized)
            {
                Content = new StringContent("denied"),
            });

        var result = await adapter.GetWorkAsync(Service(), Config(), CancellationToken.None);

        Assert.False(result.Success);
        Assert.Contains("rabbitmq http 401", result.Error);
    }

    [Theory]
    [InlineData("{}", "missing")]
    [InlineData("{\"messages\":\"many\"}", "not numeric")]
    public async Task BadOrMissingMetric_ReturnsFailure(string json, string expectedError)
    {
        var adapter = AdapterReturning(StubHttpMessageHandler.Json(json));

        var result = await adapter.GetWorkAsync(Service(), Config(), CancellationToken.None);

        Assert.False(result.Success);
        Assert.Contains(expectedError, result.Error);
    }

    [Fact]
    public async Task NegativeMetric_IsRejectedAsInvalidWork()
    {
        var adapter = AdapterReturning(StubHttpMessageHandler.Json("{\"messages\":-1}"));

        var result = await adapter.GetWorkAsync(Service(), Config(), CancellationToken.None);

        Assert.False(result.Success);
        Assert.Equal("invalid_work", result.Error);
    }

    [Fact]
    public async Task Timeout_ReturnsTriggerFailureAndAppliesServiceTimeout()
    {
        var handler = new StubHttpMessageHandler((_, _) =>
            Task.FromException<HttpResponseMessage>(new TaskCanceledException("request timed out")));
        using var client = new HttpClient(handler);
        var adapter = new RabbitMqTriggerAdapter(
            new SingleClientFactory(client),
            new StaticCredentialsProvider("user", "pass"));

        var result = await adapter.GetWorkAsync(
            Service(),
            Config(("timeoutSeconds", "17")),
            CancellationToken.None);

        Assert.False(result.Success);
        Assert.Contains(nameof(TaskCanceledException), result.Error);
        Assert.Equal(TimeSpan.FromSeconds(17), client.Timeout);
    }

    [Fact]
    public async Task CallerCancellation_Propagates()
    {
        using var cts = new CancellationTokenSource();
        var handler = new StubHttpMessageHandler((_, ct) =>
        {
            cts.Cancel();
            return Task.FromCanceled<HttpResponseMessage>(ct);
        });
        using var client = new HttpClient(handler);
        var adapter = new RabbitMqTriggerAdapter(
            new SingleClientFactory(client),
            new StaticCredentialsProvider("user", "pass"));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => adapter.GetWorkAsync(Service(), Config(), cts.Token));
    }

    private static RabbitMqTriggerAdapter AdapterReturning(HttpResponseMessage response)
    {
        var handler = new StubHttpMessageHandler((_, _) => Task.FromResult(response));
        return new RabbitMqTriggerAdapter(
            new SingleClientFactory(new HttpClient(handler)),
            new StaticCredentialsProvider("user", "pass"));
    }

    private static ServiceRef Service() =>
        new("service-1", "worker", 1, new Dictionary<string, string>(), 1, SwarmServiceMode.Replicated);

    private static ScaleConfig Config(params (string Key, string Value)[] values)
    {
        var triggerConfig = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["url"] = "http://rabbitmq:15672",
            ["queue"] = "orders",
        };
        foreach (var (key, value) in values)
            triggerConfig[key] = value;

        return new ScaleConfig { TriggerType = "rabbitmq", TriggerConfig = triggerConfig };
    }

    private sealed class StaticCredentialsProvider : IRabbitMqCredentialsProvider
    {
        private readonly RabbitMqCredentials _credentials;

        public StaticCredentialsProvider(string username, string password)
        {
            _credentials = new RabbitMqCredentials(username, password);
        }

        public RabbitMqCredentials Get(ServiceRef service, ScaleConfig config) => _credentials;
    }
}
