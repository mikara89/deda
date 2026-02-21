using Deda.Core;
using Deda.Policies;

namespace Deda.Controller.Tests;

public class SimpleScalePolicyTests
{
    private static readonly DateTimeOffset Now = DateTimeOffset.UtcNow;

    private static ServiceRef Svc(int currentReplicas) =>
        new("svc-1", "my-service", currentReplicas,
            new Dictionary<string, string>(), 1, SwarmServiceMode.Replicated);

    private static ScaleConfig Cfg(
        int min = 0, int max = 20,
        double targetPerReplica = 10, double activationThreshold = 2,
        int cooldownSeconds = 60, int scaleDownDelaySeconds = 30,
        int stepUp = 10, int stepDown = 5, int pollSeconds = 5) =>
        new()
        {
            Enabled = true,
            MinReplicas = min,
            MaxReplicas = max,
            TargetPerReplica = targetPerReplica,
            ActivationThreshold = activationThreshold,
            CooldownSeconds = cooldownSeconds,
            ScaleDownDelaySeconds = scaleDownDelaySeconds,
            StepUp = stepUp,
            StepDown = stepDown,
            PollSeconds = pollSeconds,
            TriggerType = "fake",
        };

    private static ServiceScaleState EmptyState() => new();

    [Fact]
    public void ScaleUp_WorkExceedsTarget_IncreasesReplicas()
    {
        var policy = new SimpleScalePolicyMvp();
        // 100 work / 10 per replica = 10 desired
        var decision = policy.Decide(Svc(1), Cfg(), TriggerResult.Ok(100), EmptyState(), Now);

        Assert.Equal(10, decision.DesiredReplicas);
    }

    [Fact]
    public void ScaleDown_LowWorkSustained_DecreasesReplicas()
    {
        var policy = new SimpleScalePolicyMvp();
        var cfg = Cfg(min: 1, scaleDownDelaySeconds: 10, pollSeconds: 5); // requires 2 samples

        var state = new ServiceScaleState { LastAppliedReplicas = 5 };
        // Add enough low-demand samples to satisfy the delay window
        state.RecentWork.Add(0);
        state.RecentWork.Add(0);
        state.RecentWork.Add(0);

        var decision = policy.Decide(Svc(5), cfg, TriggerResult.Ok(0), state, Now);

        Assert.Equal(1, decision.DesiredReplicas); // min replicas
    }

    [Fact]
    public void ScaleDown_BlockedByCooldown_HoldsCurrentReplicas()
    {
        var policy = new SimpleScalePolicyMvp();
        var cfg = Cfg(cooldownSeconds: 60);
        var state = new ServiceScaleState
        {
            LastScaleUpUtc = Now.AddSeconds(-10) // only 10s ago, inside 60s cooldown
        };
        // add low-demand samples
        state.RecentWork.Add(0);
        state.RecentWork.Add(0);

        var decision = policy.Decide(Svc(5), cfg, TriggerResult.Ok(0), state, Now);

        Assert.Equal(5, decision.DesiredReplicas); // held
    }

    [Fact]
    public void StepUp_LimitsReplicaIncreasePerCycle()
    {
        var policy = new SimpleScalePolicyMvp();
        var cfg = Cfg(stepUp: 2); // max +2 per cycle
        // desired would be 10, but step limits to current+2
        var decision = policy.Decide(Svc(1), cfg, TriggerResult.Ok(100), EmptyState(), Now);

        Assert.Equal(3, decision.DesiredReplicas); // 1 + 2
    }

    [Fact]
    public void StepDown_LimitsReplicaDecreasePerCycle()
    {
        var policy = new SimpleScalePolicyMvp();
        var cfg = Cfg(min: 0, stepDown: 2, scaleDownDelaySeconds: 0, pollSeconds: 5);
        var state = new ServiceScaleState();
        // Add enough samples to pass delay window
        state.RecentWork.Add(0); state.RecentWork.Add(0); state.RecentWork.Add(0);

        var decision = policy.Decide(Svc(10), cfg, TriggerResult.Ok(0), state, Now);

        Assert.Equal(8, decision.DesiredReplicas); // 10 - 2
    }

    [Fact]
    public void BelowActivationThreshold_ScalesToMin()
    {
        var policy = new SimpleScalePolicyMvp();
        var cfg = Cfg(min: 2, activationThreshold: 5, scaleDownDelaySeconds: 0);
        var state = new ServiceScaleState();
        state.RecentWork.Add(1); state.RecentWork.Add(1);

        var decision = policy.Decide(Svc(5), cfg, TriggerResult.Ok(1), state, Now);

        // raw = min because work <= activation threshold
        Assert.True(decision.DesiredReplicas <= 2);
    }

    [Fact]
    public void FailedTrigger_FailSafeHold_HoldsCurrentReplicas()
    {
        var policy = new SimpleScalePolicyMvp();
        var cfg = Cfg() with { FailSafe = FailSafeMode.Hold };

        var decision = policy.Decide(Svc(7), cfg, TriggerResult.Fail("timeout"), EmptyState(), Now);

        Assert.Equal(7, decision.DesiredReplicas);
    }

    [Fact]
    public void FailedTrigger_FailSafeMin_ScalesToMin()
    {
        var policy = new SimpleScalePolicyMvp();
        var cfg = Cfg(min: 1) with { FailSafe = FailSafeMode.Min };

        var decision = policy.Decide(Svc(7), cfg, TriggerResult.Fail("timeout"), EmptyState(), Now);

        Assert.Equal(1, decision.DesiredReplicas);
    }

    [Fact]
    public void DesiredReplicas_NeverExceedsMax()
    {
        var policy = new SimpleScalePolicyMvp();
        var cfg = Cfg(max: 5, stepUp: 0); // unlimited step, cap at 5

        var decision = policy.Decide(Svc(1), cfg, TriggerResult.Ok(9999), EmptyState(), Now);

        Assert.Equal(5, decision.DesiredReplicas);
    }

    [Fact]
    public void DesiredReplicas_NeverBelowMin()
    {
        var policy = new SimpleScalePolicyMvp();
        var cfg = Cfg(min: 3, scaleDownDelaySeconds: 0);
        var state = new ServiceScaleState();
        state.RecentWork.Add(0); state.RecentWork.Add(0);

        var decision = policy.Decide(Svc(3), cfg, TriggerResult.Ok(0), state, Now);

        Assert.True(decision.DesiredReplicas >= 3);
    }
}
