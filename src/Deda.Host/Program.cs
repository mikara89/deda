using Deda.Config.Labels;
using Deda.Credentials;
using Deda.Controller;
using Deda.Core;
using Deda.Host;
using Deda.HA;
using Deda.Observability;
using Deda.Policies;
using Deda.Swarm;
using Deda.Triggers.Abstractions;
using Deda.Triggers.Ci;
using Deda.Triggers.Http;
using Deda.Triggers.Prometheus;
using Deda.Triggers.RabbitMq;
using Deda.Updates;
using OpenTelemetry.Metrics;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;
using StackExchange.Redis;

var builder = WebApplication.CreateSlimBuilder(args);
var opts = DedaHostOptions.FromEnvironment();
builder.Services.AddSingleton(opts);
builder.Services.ConfigureHttpJsonOptions(options =>
    options.SerializerOptions.TypeInfoResolverChain.Insert(0, HealthJsonContext.Default));
builder.WebHost.UseUrls($"http://0.0.0.0:{opts.HttpPort}");

var otlpEnabled = !string.IsNullOrWhiteSpace(
    Environment.GetEnvironmentVariable("OTEL_EXPORTER_OTLP_ENDPOINT"));
builder.Services
    .AddOpenTelemetry()
    .ConfigureResource(resource => resource.AddService(
        serviceName: "deda",
        serviceVersion: typeof(Program).Assembly.GetName().Version?.ToString()))
    .WithMetrics(metrics =>
    {
        metrics
            .AddMeter(DedaDiagnostics.SourceName)
            .AddMeter(CiDiagnostics.SourceName)
            .AddPrometheusExporter();
        if (otlpEnabled)
            metrics.AddOtlpExporter();
    })
    .WithTracing(tracing =>
    {
        tracing.AddSource(DedaDiagnostics.SourceName);
        if (otlpEnabled)
            tracing.AddOtlpExporter();
    });

builder.Services.AddSingleton<AutoscalerController>();
builder.Services.AddSingleton(_ => DockerEndpoint.CreateHttpClientFromEnvironment());
builder.Services.AddSingleton<ISwarmServiceClient, DockerEngineSwarmServiceClient>();
builder.Services.AddSingleton<IScaleConfigProvider, LabelScaleConfigProvider>();
builder.Services.AddSingleton(new ReconciliationHealthState(
    TimeProvider.System,
    TimeSpan.FromSeconds(Math.Max(opts.ReadinessMaxAgeSeconds, opts.PollSeconds * 3))));
builder.Services.AddSingleton<IReconciliationHealth>(sp => sp.GetRequiredService<ReconciliationHealthState>());
builder.Services.AddSingleton(new Deda.Controller.HostOptions(
    opts.PollSeconds,
    opts.MaxServicesPerCycle,
    opts.JitterEnabled,
    opts.MaxConcurrentServices));
builder.Services.AddSingleton(new ReconcileLoopOptions(
    TimeSpan.FromSeconds(opts.PollSeconds),
    TimeSpan.FromSeconds(opts.MaxReconcileBackoffSeconds),
    TimeSpan.FromSeconds(opts.ReconcileTimeoutSeconds)));
builder.Services.AddSingleton(TimeProvider.System);
builder.Services.AddSingleton<ResilientReconcileRunner>();

if (opts.RedisConnectionString is not null)
{
    if (opts.LeaderRenewSeconds >= opts.LeaderLeaseSeconds)
        throw new InvalidOperationException("DEDA_LEADER_RENEW_SECONDS must be shorter than DEDA_LEADER_LEASE_SECONDS.");

    builder.Services.AddSingleton(new RedisLeaderOptions(
        opts.LeaderLockKey,
        opts.LeaderInstanceId,
        TimeSpan.FromSeconds(opts.LeaderLeaseSeconds),
        TimeSpan.FromSeconds(opts.LeaderRenewSeconds)));
    builder.Services.AddSingleton<IConnectionMultiplexer>(_ =>
    {
        var configuration = ConfigurationOptions.Parse(opts.RedisConnectionString);
        configuration.AbortOnConnectFail = false;
        return ConnectionMultiplexer.Connect(configuration);
    });
    builder.Services.AddSingleton<ILeaderLeaseStore, RedisLeaderLeaseStore>();
    builder.Services.AddSingleton<RedisLeaderElector>();
    builder.Services.AddSingleton<ILeaderElector>(sp => sp.GetRequiredService<RedisLeaderElector>());
    builder.Services.AddSingleton<IMutationGuard>(sp => new LeaderMutationGuard(sp.GetRequiredService<ILeaderElector>()));
    builder.Services.AddHostedService(sp => sp.GetRequiredService<RedisLeaderElector>());
}

builder.Services.AddHttpClient("rabbitmq", client =>
    client.Timeout = TimeSpan.FromSeconds(opts.DefaultHttpTimeoutSeconds));
builder.Services.AddSingleton<ISecretResolver>(new DockerSecretFileResolver(opts.SecretsDirectory));
builder.Services.AddSingleton(CredentialPolicy.FromJsonFile(opts.CredentialPolicyFile));
builder.Services.AddSingleton<IRabbitMqCredentialsProvider>(sp => new EnvOrFileRabbitMqCredentialsProvider(
    sp.GetRequiredService<ISecretResolver>(), sp.GetRequiredService<CredentialPolicy>(), opts.AllowLegacyCredentialsSecret));
builder.Services.AddSingleton<ITriggerAdapter, RabbitMqTriggerAdapter>();

builder.Services.AddHttpClient("prometheus", client =>
    client.Timeout = TimeSpan.FromSeconds(opts.DefaultHttpTimeoutSeconds));
builder.Services.AddSingleton<ITriggerAdapter, PrometheusTriggerAdapter>();
builder.Services.AddHttpClient("http", client =>
    client.Timeout = TimeSpan.FromSeconds(opts.DefaultHttpTimeoutSeconds));
builder.Services.AddSingleton<ITriggerAdapter, HttpTriggerAdapter>();
builder.Services.AddHttpClient("github-actions", client => client.Timeout = TimeSpan.FromSeconds(opts.DefaultHttpTimeoutSeconds));
builder.Services.AddHttpClient("azure-pipelines", client => client.Timeout = TimeSpan.FromSeconds(opts.DefaultHttpTimeoutSeconds));
builder.Services.AddHttpClient("gitlab-ci", client => client.Timeout = TimeSpan.FromSeconds(opts.DefaultHttpTimeoutSeconds));
builder.Services.AddSingleton<CredentialTokenProvider>();
builder.Services.AddSingleton<GitHubActionsQueueProvider>();
builder.Services.AddSingleton<AzurePipelinesQueueProvider>();
builder.Services.AddSingleton<GitLabCiQueueProvider>();
builder.Services.AddSingleton<ITriggerAdapter, GitHubActionsTriggerAdapter>();
builder.Services.AddSingleton<ITriggerAdapter, AzurePipelinesTriggerAdapter>();
builder.Services.AddSingleton<ITriggerAdapter, GitLabCiTriggerAdapter>();
builder.Services.AddSingleton<ITriggerAdapterRegistry>(sp =>
    new TriggerAdapterRegistry(sp.GetServices<ITriggerAdapter>()));

builder.Services.AddSingleton<IScalePolicy, SimpleScalePolicyMvp>();
builder.Services.AddSingleton<IStateStore<string, ServiceScaleState>, InMemoryStateStore>();
builder.Services.AddSingleton<IAutoscalerTelemetry, OpenTelemetryAutoscalerTelemetry>();
builder.Services.AddSingleton<IServiceUpdateStrategy>(sp => new RetryOnVersionConflictUpdateStrategy(
    guard: sp.GetService<IMutationGuard>() ?? new NoOpMutationGuard()));
builder.Services.AddHostedService<Worker>();

var app = builder.Build();
if (opts.RedisConnectionString is null)
{
    app.Logger.LogWarning(
        "High availability is disabled. Run exactly one DEDA replica or configure DEDA_REDIS_CONNECTION.");
}
app.MapPrometheusScrapingEndpoint("/metrics");
app.MapGet("/health/live", () => Results.Ok(new LiveHealthResponse("ok")));
app.MapGet("/health/ready", (IReconciliationHealth healthState) =>
{
    var health = healthState.Snapshot();
    return health.IsReady
        ? Results.Ok(new ReadyHealthResponse(
            "ready",
            health.LastAttemptUtc,
            health.LastSuccessfulUtc))
        : Results.Problem(
            title: "Reconciliation is not healthy",
            detail: health.LastError ?? "No successful reconciliation has completed.",
            statusCode: 503);
});

await app.RunAsync();
