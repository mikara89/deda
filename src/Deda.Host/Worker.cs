using Deda.Controller;
using Deda.Host;

public sealed class Worker : BackgroundService
{
    private readonly ResilientReconcileRunner _runner;
    private readonly ILogger<Worker> _logger;
    private readonly DedaHostOptions _opts;

    public Worker(ResilientReconcileRunner runner, ILogger<Worker> logger, DedaHostOptions opts)
    {
        _runner = runner;
        _logger = logger;
        _opts = opts;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        _logger.LogInformation("DEDA Host started. PollSeconds={PollSeconds}", _opts.PollSeconds);

        try
        {
            while (!stoppingToken.IsCancellationRequested)
            {
                var delay = await _runner.RunOnceAsync(stoppingToken);
                await Task.Delay(delay, stoppingToken);
            }
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
        {
            _logger.LogInformation("DEDA Host stopping.");
        }
    }
}
