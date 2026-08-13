using Deda.Core;
using System.Net;

namespace Deda.Host
{
    public sealed class ApiServerHostedService : IHostedService
    {
        private readonly IMetricsRegistry _metrics;
        private readonly IReconciliationHealth _health;

        private WebApplication? _app;

        public ApiServerHostedService(IMetricsRegistry metrics, IReconciliationHealth health)
        {
            _metrics = metrics;
            _health = health;
        }

        public async Task StartAsync(CancellationToken cancellationToken)
        {
            var port = ReadInt("DEDA_HTTP_PORT", 8080, 1, 65535);

            var builder = WebApplication.CreateSlimBuilder();

            // Listen on all interfaces (0.0.0.0) for container scenarios
            builder.WebHost.ConfigureKestrel(o => o.Listen(IPAddress.Any, port));

            var app = builder.Build();

            // Minimal hosting: map endpoints directly (no UseEndpoints needed)
            app.MapGet("/metrics",
                () => Results.Text(_metrics.RenderPrometheus(), "text/plain; version=0.0.4"));

            app.MapGet("/health/live",
                () => Results.Ok(new { status = "ok" }));

            app.MapGet("/health/ready", () =>
            {
                var health = _health.Snapshot();
                return health.IsReady
                    ? Results.Ok(new
                    {
                        status = "ready",
                        lastAttemptUtc = health.LastAttemptUtc,
                        lastSuccessfulUtc = health.LastSuccessfulUtc,
                    })
                    : Results.Problem(
                        title: "Reconciliation is not healthy",
                        detail: health.LastError ?? "No successful reconciliation has completed.",
                        statusCode: 503);
            });

            _app = app;
            await app.StartAsync(cancellationToken);
        }

        public async Task StopAsync(CancellationToken cancellationToken)
        {
            if (_app is null) return;

            await _app.StopAsync(cancellationToken);
            await _app.DisposeAsync();
            _app = null;
        }

        private static int ReadInt(string key, int fallback, int min, int max)
        {
            var s = Environment.GetEnvironmentVariable(key);
            if (!int.TryParse(s, out var v)) return fallback;
            if (v < min) return min;
            if (v > max) return max;
            return v;
        }
    }
}
