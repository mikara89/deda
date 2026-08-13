using Deda.Config.Labels;
using Deda.Core;

namespace Deda.Integration.Tests;

public class LabelScaleConfigProviderTests
{
    private static ServiceRef Svc(Dictionary<string, string> labels) =>
        new("svc-1", "my-service", 1, labels, 1, SwarmServiceMode.Replicated);

    private static Dictionary<string, string> MinimalLabels() => new()
    {
        ["com.deda.autoscale.enabled"] = "true",
        ["com.deda.autoscale.trigger.type"] = "rabbitmq",
        ["com.deda.autoscale.trigger.url"] = "http://rabbitmq:15672",
        ["com.deda.autoscale.trigger.queue"] = "my-queue",
    };

    [Fact]
    public void NoLabels_ReturnsNull()
    {
        var provider = new LabelScaleConfigProvider();
        var cfg = provider.TryGetConfig(Svc([]), out _);
        Assert.Null(cfg);
    }

    [Fact]
    public void EnabledFalse_ReturnsNull()
    {
        var labels = MinimalLabels();
        labels["com.deda.autoscale.enabled"] = "false";
        var provider = new LabelScaleConfigProvider();
        var cfg = provider.TryGetConfig(Svc(labels), out _);
        Assert.Null(cfg);
    }

    [Fact]
    public void MinimalValidLabels_ReturnsConfig()
    {
        var provider = new LabelScaleConfigProvider();
        var cfg = provider.TryGetConfig(Svc(MinimalLabels()), out var error);
        Assert.NotNull(cfg);
        Assert.Null(error);
        Assert.True(cfg.Enabled);
    }

    [Fact]
    public void MissingTriggerType_ReturnsNullWithError()
    {
        var labels = MinimalLabels();
        labels.Remove("com.deda.autoscale.trigger.type");
        var provider = new LabelScaleConfigProvider();
        var cfg = provider.TryGetConfig(Svc(labels), out var error);
        Assert.Null(cfg);
        Assert.False(string.IsNullOrWhiteSpace(error));
    }

    [Fact]
    public void CustomMinMax_ParsedCorrectly()
    {
        var labels = MinimalLabels();
        labels["com.deda.autoscale.min"] = "2";
        labels["com.deda.autoscale.max"] = "15";
        var provider = new LabelScaleConfigProvider();
        var cfg = provider.TryGetConfig(Svc(labels), out _);
        Assert.NotNull(cfg);
        Assert.Equal(2, cfg.MinReplicas);
        Assert.Equal(15, cfg.MaxReplicas);
    }

    [Fact]
    public void MinGreaterThanMax_ReturnsNullWithError()
    {
        var labels = MinimalLabels();
        labels["com.deda.autoscale.min"] = "10";
        labels["com.deda.autoscale.max"] = "5";
        var provider = new LabelScaleConfigProvider();
        var cfg = provider.TryGetConfig(Svc(labels), out var error);
        Assert.Null(cfg);
        Assert.False(string.IsNullOrWhiteSpace(error));
    }

    [Fact]
    public void TriggerConfig_SubtreeExtracted()
    {
        var labels = MinimalLabels();
        labels["com.deda.autoscale.trigger.vhost"] = "/staging";
        labels["com.deda.autoscale.trigger.metric"] = "messages_ready";
        var provider = new LabelScaleConfigProvider();
        var cfg = provider.TryGetConfig(Svc(labels), out _);
        Assert.NotNull(cfg);
        Assert.True(cfg.TriggerConfig.TryGetValue("vhost", out var vhost));
        Assert.Equal("/staging", vhost);
        Assert.True(cfg.TriggerConfig.TryGetValue("metric", out var metric));
        Assert.Equal("messages_ready", metric);
    }

    [Fact]
    public void FailSafeLabel_ParsedCorrectly()
    {
        var labels = MinimalLabels();
        labels["com.deda.autoscale.failsafe"] = "min";
        var provider = new LabelScaleConfigProvider();
        var cfg = provider.TryGetConfig(Svc(labels), out _);
        Assert.NotNull(cfg);
        Assert.Equal(FailSafeMode.Min, cfg.FailSafe);
    }

    [Fact]
    public void DefaultValues_AppliedWhenLabelsOmitted()
    {
        var provider = new LabelScaleConfigProvider();
        var cfg = provider.TryGetConfig(Svc(MinimalLabels()), out _);
        Assert.NotNull(cfg);
        Assert.Equal(0, cfg.MinReplicas);
        Assert.Equal(50, cfg.MaxReplicas);
        Assert.Equal(50.0, cfg.TargetPerReplica);
        Assert.Equal(FailSafeMode.Hold, cfg.FailSafe);
    }

    [Theory]
    [InlineData("0")]
    [InlineData("not-a-number")]
    [InlineData("3600")]
    public void DeprecatedPollSecondsLabel_IsIgnored(string value)
    {
        var labels = MinimalLabels();
        labels["com.deda.autoscale.pollSeconds"] = value;

        var cfg = new LabelScaleConfigProvider().TryGetConfig(Svc(labels), out var error);

        Assert.NotNull(cfg);
        Assert.Null(error);
        Assert.Equal(new ScaleConfig().PollSeconds, cfg.PollSeconds);
    }

    [Theory]
    [InlineData("NaN")]
    [InlineData("Infinity")]
    [InlineData("-Infinity")]
    public void NonFiniteScalingValues_ReturnNullWithError(string value)
    {
        var labels = MinimalLabels();
        labels["com.deda.autoscale.targetPerReplica"] = value;

        var cfg = new LabelScaleConfigProvider().TryGetConfig(Svc(labels), out var error);

        Assert.Null(cfg);
        Assert.False(string.IsNullOrWhiteSpace(error));
    }

    [Fact]
    public void ScaleToZeroGraceSeconds_IsParsed()
    {
        var labels = MinimalLabels();
        labels["com.deda.autoscale.scaleToZeroGraceSeconds"] = "45";

        var cfg = new LabelScaleConfigProvider().TryGetConfig(Svc(labels), out var error);

        Assert.NotNull(cfg);
        Assert.Null(error);
        Assert.Equal(45, cfg.ScaleToZeroGraceSeconds);
    }

    [Theory]
    [InlineData("com.deda.autoscale.scaleDownDelaySeconds")]
    [InlineData("com.deda.autoscale.scaleToZeroGraceSeconds")]
    public void TimeWindowsLongerThanOneDayAreRejected(string label)
    {
        var labels = MinimalLabels();
        labels[label] = "86401";

        var cfg = new LabelScaleConfigProvider().TryGetConfig(Svc(labels), out var error);

        Assert.Null(cfg);
        Assert.Contains("86400", error);
    }
}
