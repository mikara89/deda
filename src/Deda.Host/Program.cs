using Deda.Config.Labels;
using Deda.Controller;
using Deda.Core;
using Deda.Host;
using Deda.Policies;
using Deda.Swarm;
using Deda.Triggers.Abstractions;
using Deda.Triggers.Prometheus;
using Deda.Triggers.RabbitMq;
using Deda.Updates;

var builder = Host.CreateApplicationBuilder(args);

// Controller
builder.Services.AddSingleton<AutoscalerController>();

builder.Services.AddSingleton(sp =>
{
    // Single HttpClient instance for Docker Engine API
    return DockerEndpoint.CreateHttpClientFromEnvironment();
});

builder.Services.AddSingleton<ISwarmServiceClient, DockerEngineSwarmServiceClient>();

// Real label config provider
builder.Services.AddSingleton<IScaleConfigProvider, LabelScaleConfigProvider>();

var opts = DedaHostOptions.FromEnvironment();
builder.Services.AddSingleton(opts);

// Metrics + readiness + API server
builder.Services.AddSingleton<IMetricsRegistry, MetricsRegistry>();
builder.Services.AddSingleton<ReconciliationHealthState>();
builder.Services.AddSingleton<IReconciliationHealth>(sp => sp.GetRequiredService<ReconciliationHealthState>());
builder.Services.AddHostedService<ApiServerHostedService>();

builder.Services.AddSingleton(new Deda.Controller.HostOptions(opts.PollSeconds, opts.MaxServicesPerCycle, opts.JitterEnabled));
builder.Services.AddSingleton(new ReconcileLoopOptions(
    TimeSpan.FromSeconds(opts.PollSeconds),
    TimeSpan.FromSeconds(opts.MaxReconcileBackoffSeconds)));
builder.Services.AddSingleton(TimeProvider.System);
builder.Services.AddSingleton<ResilientReconcileRunner>();

builder.Services.AddHttpClient("rabbitmq", c =>
{
    c.Timeout = TimeSpan.FromSeconds(opts.DefaultHttpTimeoutSeconds);
});

// RabbitMQ trigger + creds provider
builder.Services.AddSingleton<IRabbitMqCredentialsProvider, EnvOrFileRabbitMqCredentialsProvider>();
builder.Services.AddSingleton<ITriggerAdapter, RabbitMqTriggerAdapter>();

// Prometheus trigger (example of a second trigger type, sharing the same HttpClientFactory)
builder.Services.AddHttpClient("prometheus", c =>
{
    c.Timeout = TimeSpan.FromSeconds(opts.DefaultHttpTimeoutSeconds);
});
builder.Services.AddSingleton<ITriggerAdapter, PrometheusTriggerAdapter>();

// Trigger registry
builder.Services.AddSingleton<ITriggerAdapterRegistry>(sp =>
    new TriggerAdapterRegistry(sp.GetServices<ITriggerAdapter>())
);

// Scaling policy
builder.Services.AddSingleton<IScalePolicy, SimpleScalePolicyMvp>();

// State store (in-memory MVP)
builder.Services.AddSingleton<IStateStore<string, ServiceScaleState>, InMemoryStateStoreMvp>();

// �No telemetry� (just logs)
builder.Services.AddSingleton<IAutoscalerTelemetry, ConsoleTelemetryMvp>();

// Update strategy (real)
builder.Services.AddSingleton<IServiceUpdateStrategy, RetryOnVersionConflictUpdateStrategy>();

// Worker loop
builder.Services.AddHostedService<Worker>();

var host = builder.Build();
await host.RunAsync();
