using Deda.Core;
using Deda.Policies;

namespace Deda.Controller.Tests;

public class SimpleScalePolicyTests
{
    private static readonly DateTimeOffset Now = new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);

    private static ServiceRef Svc(int currentReplicas) =>
        new("svc-1", "my-service", currentReplicas,
            new Dictionary<string, string>(), 1, SwarmServiceMode.Replicated);

    private static ScaleConfig Cfg(
        int min = 0, int max = 20,
        double targetPerReplica = 10, double activationThreshold = 2,
        int cooldownSeconds = 60, int scaleDownDelaySeconds = 30,
        int stepUp = 10, int stepDown = 5, int scaleToZeroGraceSeconds = 0) =>
        new()
        {
            Enabled = true,
            MinReplicas = min,
            MaxReplicas = max,
            TargetPerReplica = targetPerReplica,
            ActivationThreshold = activationThreshold,
            CooldownSeconds = cooldownSeconds,
            ScaleDownDelaySeconds = scaleDownDelaySeconds,
            ScaleToZeroGraceSeconds = scaleToZeroGraceSeconds,
            StepUp = stepUp,
            StepDown = stepDown,
            TriggerType = "fake",
        };

    [Fact]
    public void ScaleUp_WorkExceedsTarget_IncreasesReplicasImmediately()
    {
        var policy = new SimpleScalePolicyMvp();

        var decision = policy.Decide(Svc(1), Cfg(), TriggerResult.Ok(100), new(), Now);

        Assert.Equal(10, decision.DesiredReplicas);
    }

    [Fact]
    public void ProportionalScaleDown_EventuallyReachesCalculatedReplicaCount()
    {
        var policy = new SimpleScalePolicyMvp();
        var cfg = Cfg(scaleDownDelaySeconds: 30, stepDown: 0);
        var state = new ServiceScaleState();

        policy.Decide(Svc(10), cfg, TriggerResult.Ok(100), state, Now);
        var held = policy.Decide(Svc(10), cfg, TriggerResult.Ok(50), state, Now.AddSeconds(10));
        var released = policy.Decide(Svc(10), cfg, TriggerResult.Ok(50), state, Now.AddSeconds(31));

        Assert.Equal(10, held.DesiredReplicas);
        Assert.Equal(5, released.DesiredReplicas);
    }

    [Fact]
    public void ScaleDown_UsesHighestRecommendationInsideWindow()
    {
        var policy = new SimpleScalePolicyMvp();
        var cfg = Cfg(scaleDownDelaySeconds: 30, stepDown: 0);
        var state = new ServiceScaleState();

        policy.Decide(Svc(10), cfg, TriggerResult.Ok(100), state, Now);
        var eight = policy.Decide(Svc(10), cfg, TriggerResult.Ok(80), state, Now.AddSeconds(10));
        var five = policy.Decide(Svc(10), cfg, TriggerResult.Ok(50), state, Now.AddSeconds(20));

        Assert.Equal(10, eight.DesiredReplicas);
        Assert.Equal(10, five.DesiredReplicas);
        Assert.Contains("stabilizationBlocked=True", five.Reason);
    }

    [Fact]
    public void ScaleDown_ProgressesAsOlderRecommendationsExpire()
    {
        var policy = new SimpleScalePolicyMvp();
        var cfg = Cfg(scaleDownDelaySeconds: 30, stepDown: 0);
        var state = new ServiceScaleState();

        policy.Decide(Svc(10), cfg, TriggerResult.Ok(100), state, Now);
        policy.Decide(Svc(10), cfg, TriggerResult.Ok(80), state, Now.AddSeconds(10));
        policy.Decide(Svc(10), cfg, TriggerResult.Ok(60), state, Now.AddSeconds(20));

        var toEight = policy.Decide(Svc(10), cfg, TriggerResult.Ok(50), state, Now.AddSeconds(31));
        var toSix = policy.Decide(Svc(8), cfg, TriggerResult.Ok(50), state, Now.AddSeconds(41));
        var toFive = policy.Decide(Svc(6), cfg, TriggerResult.Ok(50), state, Now.AddSeconds(51));

        Assert.Equal(8, toEight.DesiredReplicas);
        Assert.Equal(6, toSix.DesiredReplicas);
        Assert.Equal(5, toFive.DesiredReplicas);
    }

    [Fact]
    public void RecommendationAtWindowBoundary_IsRetainedUntilItExpires()
    {
        var policy = new SimpleScalePolicyMvp();
        var cfg = Cfg(scaleDownDelaySeconds: 30, stepDown: 0);
        var state = new ServiceScaleState();

        policy.Decide(Svc(10), cfg, TriggerResult.Ok(100), state, Now);
        var atBoundary = policy.Decide(Svc(10), cfg, TriggerResult.Ok(50), state, Now.AddSeconds(30));
        var afterBoundary = policy.Decide(Svc(10), cfg, TriggerResult.Ok(50), state, Now.AddSeconds(31));

        Assert.Equal(10, atBoundary.DesiredReplicas);
        Assert.Equal(5, afterBoundary.DesiredReplicas);
        Assert.DoesNotContain(state.RecommendationHistory, recommendation => recommendation.TimestampUtc == Now);
    }

    [Fact]
    public void LongStabilizationWindow_IsNotLimitedToSixtyRecommendations()
    {
        var policy = new SimpleScalePolicyMvp();
        var cfg = Cfg(scaleDownDelaySeconds: 30 * 60, stepDown: 0);
        var state = new ServiceScaleState();

        policy.Decide(Svc(10), cfg, TriggerResult.Ok(100), state, Now);
        ScaleDecision decision = null!;
        for (var seconds = 10; seconds < 30 * 60; seconds += 10)
        {
            decision = policy.Decide(
                Svc(10), cfg, TriggerResult.Ok(50), state, Now.AddSeconds(seconds));
        }

        Assert.Equal(10, decision.DesiredReplicas);
        Assert.True(state.RecommendationHistory.Count > 60);

        var released = policy.Decide(
            Svc(10), cfg, TriggerResult.Ok(50), state, Now.AddSeconds((30 * 60) + 1));
        Assert.Equal(5, released.DesiredReplicas);
    }

    [Fact]
    public void ScaleDown_BlockedByCooldown_HoldsCurrentReplicas()
    {
        var policy = new SimpleScalePolicyMvp();
        var cfg = Cfg(cooldownSeconds: 60, scaleDownDelaySeconds: 0, stepDown: 0);
        var state = new ServiceScaleState { LastScaleUpUtc = Now.AddSeconds(-10) };

        var decision = policy.Decide(Svc(5), cfg, TriggerResult.Ok(0), state, Now);

        Assert.Equal(5, decision.DesiredReplicas);
        Assert.Contains("cooldownBlocked=True", decision.Reason);
    }

    [Fact]
    public void ActivationThreshold_ScalesInactiveWorkloadToMin()
    {
        var policy = new SimpleScalePolicyMvp();
        var cfg = Cfg(min: 2, activationThreshold: 5, scaleDownDelaySeconds: 0, stepDown: 0);

        var decision = policy.Decide(Svc(5), cfg, TriggerResult.Ok(1), new(), Now);

        Assert.Equal(2, decision.DesiredReplicas);
    }

    [Fact]
    public void ActivationThreshold_DoesNotBlockProportionalScaleDown()
    {
        var policy = new SimpleScalePolicyMvp();
        var cfg = Cfg(activationThreshold: 2, scaleDownDelaySeconds: 0, stepDown: 0);

        var decision = policy.Decide(Svc(10), cfg, TriggerResult.Ok(50), new(), Now);

        Assert.Equal(5, decision.DesiredReplicas);
    }

    [Fact]
    public void ScaleToZeroGrace_HoldsReplicasUntilGraceElapses()
    {
        var policy = new SimpleScalePolicyMvp();
        var cfg = Cfg(
            cooldownSeconds: 0,
            scaleDownDelaySeconds: 0,
            stepDown: 0,
            scaleToZeroGraceSeconds: 30);
        var state = new ServiceScaleState();

        var first = policy.Decide(Svc(5), cfg, TriggerResult.Ok(0), state, Now);
        var held = policy.Decide(Svc(5), cfg, TriggerResult.Ok(0), state, Now.AddSeconds(29));
        var released = policy.Decide(Svc(5), cfg, TriggerResult.Ok(0), state, Now.AddSeconds(30));

        Assert.Equal(5, first.DesiredReplicas);
        Assert.Equal(5, held.DesiredReplicas);
        Assert.Equal(0, released.DesiredReplicas);
        Assert.Contains("scaleToZeroGraceBlocked=True", held.Reason);
    }

    [Fact]
    public void ActiveWorkResetsScaleToZeroGrace()
    {
        var policy = new SimpleScalePolicyMvp();
        var cfg = Cfg(
            cooldownSeconds: 0,
            scaleDownDelaySeconds: 0,
            stepDown: 0,
            scaleToZeroGraceSeconds: 30);
        var state = new ServiceScaleState();

        policy.Decide(Svc(5), cfg, TriggerResult.Ok(0), state, Now);
        policy.Decide(Svc(5), cfg, TriggerResult.Ok(50), state, Now.AddSeconds(20));
        var inactiveAgain = policy.Decide(Svc(5), cfg, TriggerResult.Ok(0), state, Now.AddSeconds(31));

        Assert.Equal(5, inactiveAgain.DesiredReplicas);
        Assert.Equal(Now.AddSeconds(31), state.InactiveSinceUtc);
    }

    [Fact]
    public void StepUp_LimitsReplicaIncreasePerCycle()
    {
        var policy = new SimpleScalePolicyMvp();

        var decision = policy.Decide(Svc(1), Cfg(stepUp: 2), TriggerResult.Ok(100), new(), Now);

        Assert.Equal(3, decision.DesiredReplicas);
    }

    [Fact]
    public void StepDown_LimitsReplicaDecreaseAfterStabilization()
    {
        var policy = new SimpleScalePolicyMvp();
        var cfg = Cfg(stepDown: 2, scaleDownDelaySeconds: 0);

        var decision = policy.Decide(Svc(10), cfg, TriggerResult.Ok(0), new(), Now);

        Assert.Equal(8, decision.DesiredReplicas);
    }

    [Fact]
    public void DesiredReplicas_NeverExceedsMax()
    {
        var policy = new SimpleScalePolicyMvp();

        var decision = policy.Decide(
            Svc(1), Cfg(max: 5, stepUp: 0), TriggerResult.Ok(9999), new(), Now);

        Assert.Equal(5, decision.DesiredReplicas);
    }

    [Fact]
    public void VeryLargeFiniteWork_SaturatesAtMaxWithoutOverflow()
    {
        var policy = new SimpleScalePolicyMvp();

        var decision = policy.Decide(
            Svc(1), Cfg(max: 20, stepUp: 0), TriggerResult.Ok(double.MaxValue), new(), Now);

        Assert.Equal(20, decision.DesiredReplicas);
    }

    [Fact]
    public void DesiredReplicas_NeverFallsBelowMin()
    {
        var policy = new SimpleScalePolicyMvp();

        var decision = policy.Decide(
            Svc(10), Cfg(min: 3, scaleDownDelaySeconds: 0, stepDown: 0),
            TriggerResult.Ok(0), new(), Now);

        Assert.Equal(3, decision.DesiredReplicas);
    }

    [Fact]
    public void CurrentBelowMin_StepUpDoesNotPreventReachingMin()
    {
        var policy = new SimpleScalePolicyMvp();

        var decision = policy.Decide(
            Svc(0), Cfg(min: 5, stepUp: 2), TriggerResult.Ok(0), new(), Now);

        Assert.Equal(5, decision.DesiredReplicas);
    }

    [Fact]
    public void CurrentAboveMax_StepDownDoesNotPreventReachingMax()
    {
        var policy = new SimpleScalePolicyMvp();

        var decision = policy.Decide(
            Svc(30), Cfg(max: 20, scaleDownDelaySeconds: 0, stepDown: 5),
            TriggerResult.Ok(200), new(), Now);

        Assert.Equal(20, decision.DesiredReplicas);
    }

    [Theory]
    [InlineData(FailSafeMode.Hold, 7)]
    [InlineData(FailSafeMode.Min, 1)]
    [InlineData(FailSafeMode.Max, 20)]
    public void FailedTrigger_AppliesConfiguredFailSafe(FailSafeMode failSafe, int expected)
    {
        var policy = new SimpleScalePolicyMvp();
        var cfg = Cfg(min: 1) with { FailSafe = failSafe };

        var decision = policy.Decide(Svc(7), cfg, TriggerResult.Fail("timeout"), new(), Now);

        Assert.Equal(expected, decision.DesiredReplicas);
    }

    [Theory]
    [MemberData(nameof(InvalidWorkValues))]
    public void InvalidSuccessfulTrigger_AppliesFailSafeWithoutRecordingRecommendation(double work)
    {
        var policy = new SimpleScalePolicyMvp();
        var state = new ServiceScaleState();

        var decision = policy.Decide(
            Svc(7), Cfg(), new TriggerResult(true, work), state, Now);

        Assert.Equal(7, decision.DesiredReplicas);
        Assert.Empty(state.RecommendationHistory);
        Assert.Equal("trigger_failed:invalid_work", decision.Reason);
    }

    [Theory]
    [MemberData(nameof(InvalidWorkValues))]
    public void TriggerResultOk_ConvertsInvalidWorkToFailure(double work)
    {
        var result = TriggerResult.Ok(work);

        Assert.False(result.Success);
        Assert.Equal("invalid_work", result.Error);
    }

    public static TheoryData<double> InvalidWorkValues => new()
    {
        double.NaN,
        double.PositiveInfinity,
        double.NegativeInfinity,
        -1,
    };
}
