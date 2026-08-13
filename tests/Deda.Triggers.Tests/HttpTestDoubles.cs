using System.Net;

namespace Deda.Triggers.Tests;

internal sealed class StubHttpMessageHandler : HttpMessageHandler
{
    private readonly Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> _handler;

    public StubHttpMessageHandler(
        Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> handler)
    {
        _handler = handler;
    }

    protected override Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken) => _handler(request, cancellationToken);

    public static HttpResponseMessage Json(string json, HttpStatusCode status = HttpStatusCode.OK) =>
        new(status)
        {
            Content = new StringContent(json, System.Text.Encoding.UTF8, "application/json"),
        };
}

internal sealed class SingleClientFactory : IHttpClientFactory
{
    public SingleClientFactory(HttpClient client)
    {
        Client = client;
    }

    public HttpClient Client { get; }

    public HttpClient CreateClient(string name) => Client;
}
