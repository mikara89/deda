using Deda.Controller;
using Deda.Host;

public sealed class Worker : BackgroundService
{
    private readonly AutoscalerController _controller;
    private readonly ILogger<Worker> _logger;
    private readonly DedaHostOptions _opts;

    public Worker(AutoscalerController controller, ILogger<Worker> logger, DedaHostOptions opts)
    {
        _controller = controller;
        _logger = logger;
        _opts = opts;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        _logger.LogInformation("DEDA Host started. PollSeconds={PollSeconds}", _opts.PollSeconds);

        while (!stoppingToken.IsCancellationRequested)
        {
            await _controller.ReconcileOnceAsync(stoppingToken);
            await Task.Delay(TimeSpan.FromSeconds(_opts.PollSeconds), stoppingToken);
        }
    }
}
