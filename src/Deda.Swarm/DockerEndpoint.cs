using System.Net.Sockets;

namespace Deda.Swarm
{
    public static class DockerEndpoint
    {
        public static HttpClient CreateHttpClientFromEnvironment()
        {
            var dockerHost =
                Environment.GetEnvironmentVariable("DOCKER_HOST")
                ?? (OperatingSystem.IsWindows()
                    ? "npipe://./pipe/docker_engine" // not supported by this implementation
                    : "unix:///var/run/docker.sock");

            return CreateHttpClient(dockerHost);
        }

        public static HttpClient CreateHttpClient(string dockerHost)
        {
            if (string.IsNullOrWhiteSpace(dockerHost))
                throw new ArgumentException("DOCKER_HOST is empty", nameof(dockerHost));

            // Normalize common forms
            // unix:///var/run/docker.sock
            // tcp://host:2375
            // http(s)://host:port
            var host = dockerHost.Trim();

            if (host.StartsWith("unix://", StringComparison.OrdinalIgnoreCase))
            {
                if (OperatingSystem.IsWindows())
                    throw new NotSupportedException("unix:// DOCKER_HOST is not supported on Windows.");

                var path = host.Substring("unix://".Length);

                var handler = new SocketsHttpHandler
                {
                    ConnectCallback = async (ctx, ct) =>
                    {
                        var socket = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
                        try
                        {
                            var ep = new UnixDomainSocketEndPoint(path);
                            await socket.ConnectAsync(ep, ct).ConfigureAwait(false);
                            return new NetworkStream(socket, ownsSocket: true);
                        }
                        catch
                        {
                            socket.Dispose();
                            throw;
                        }
                    }
                };

                // BaseAddress host is irrelevant; must be valid absolute URI.
                return new HttpClient(handler)
                {
                    BaseAddress = new Uri("http://docker"),
                    Timeout = TimeSpan.FromSeconds(10)
                };
            }

            if (host.StartsWith("tcp://", StringComparison.OrdinalIgnoreCase))
            {
                // Docker Engine API over TCP usually speaks HTTP unless you configure TLS separately.
                var http = "http://" + host.Substring("tcp://".Length);
                return new HttpClient
                {
                    BaseAddress = new Uri(http.EndsWith("/") ? http : http + "/"),
                    Timeout = TimeSpan.FromSeconds(10)
                };
            }

            if (host.StartsWith("http://", StringComparison.OrdinalIgnoreCase) ||
                host.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
            {
                return new HttpClient
                {
                    BaseAddress = new Uri(host.EndsWith("/") ? host : host + "/"),
                    Timeout = TimeSpan.FromSeconds(10)
                };
            }

            if (host.StartsWith("npipe://", StringComparison.OrdinalIgnoreCase))
            {
                // Windows named pipe support is possible but requires extra plumbing.
                // For production Swarm managers (Linux), unix:// is standard.
                throw new NotSupportedException("npipe:// is not supported in this AOT-friendly client. Use tcp:// or run on Linux with unix://.");
            }

            throw new NotSupportedException($"Unsupported DOCKER_HOST scheme: {dockerHost}");
        }
    }
}
