using Deda.Core;

namespace Deda.Policies
{
    public sealed class SimpleScalePolicyMvp : IScalePolicy
    {
        public ScaleDecision Decide(ServiceRef service, ScaleConfig cfg, TriggerResult trigger, ServiceScaleState state, DateTimeOffset nowUtc)
        {
            int current = service.CurrentReplicas;

            if (!trigger.Success || !TriggerResult.IsValidWork(trigger.Work))
            {
                int desiredFail = cfg.FailSafe switch
                {
                    FailSafeMode.Min => cfg.MinReplicas,
                    FailSafeMode.Max => cfg.MaxReplicas,
                    _ => current
                };

                desiredFail = Clamp(desiredFail, cfg.MinReplicas, cfg.MaxReplicas);
                string error = trigger.Success ? "invalid_work" : trigger.Error ?? "unknown";

                return new ScaleDecision(service.ServiceId, service.Name, current, desiredFail, 0,
                    $"trigger_failed:{error}", nowUtc);
            }

            // Base desired
            int raw =
                trigger.Work <= cfg.ActivationThreshold
                    ? cfg.MinReplicas
                    : CalculateProportionalRecommendation(trigger.Work, cfg.TargetPerReplica);

            int bounded = Clamp(raw, cfg.MinReplicas, cfg.MaxReplicas);

            bool blockedByScaleToZeroGrace = false;
            if (bounded == 0 && trigger.Work <= cfg.ActivationThreshold)
            {
                state.InactiveSinceUtc ??= nowUtc;
                if (current > 0 &&
                    nowUtc - state.InactiveSinceUtc.Value < TimeSpan.FromSeconds(cfg.ScaleToZeroGraceSeconds))
                {
                    bounded = current;
                    blockedByScaleToZeroGrace = true;
                }
            }
            else
            {
                state.InactiveSinceUtc = null;
            }

            RecordRecommendation(state, bounded, nowUtc, cfg.ScaleDownDelaySeconds);

            // Cooldown: block scale-down shortly after scale-up
            int stabilized = bounded;
            bool blockedByCooldown = false;
            if (bounded < current && state.LastScaleUpUtc is not null)
            {
                var sinceUp = nowUtc - state.LastScaleUpUtc.Value;
                if (sinceUp.TotalSeconds < cfg.CooldownSeconds)
                {
                    stabilized = current;
                    blockedByCooldown = true;
                }
            }

            // Scale-down stabilization: prefer the highest recent desired recommendation.
            bool blockedByStabilization = false;
            if (!blockedByCooldown && stabilized < current)
            {
                int highestRecentRecommendation = state.HighestRecommendation;

                // Recommendation history must never cause an otherwise-downscale decision
                // to scale up. External changes may make an old recommendation exceed current.
                stabilized = Math.Max(bounded, Math.Min(current, highestRecentRecommendation));
                blockedByStabilization = stabilized > bounded;
            }

            // Step limits
            // Absolute safety bounds override gradual step limits when the current
            // replica count is already outside the configured range.
            int final = Clamp(
                ApplyStepLimits(current, stabilized, cfg),
                cfg.MinReplicas,
                cfg.MaxReplicas);

            string reason =
                $"work={trigger.Work:0.##} raw={raw} bounded={bounded} stabilized={stabilized} final={final} " +
                $"cooldownBlocked={blockedByCooldown} stabilizationBlocked={blockedByStabilization} " +
                $"scaleToZeroGraceBlocked={blockedByScaleToZeroGrace} " +
                $"recommendations={state.RecommendationCount} windowSeconds={cfg.ScaleDownDelaySeconds} trig={cfg.TriggerType}";


            return new ScaleDecision(service.ServiceId, service.Name, current, final, trigger.Work, reason, nowUtc);
        }

        private static void RecordRecommendation(
            ServiceScaleState state,
            int desiredReplicas,
            DateTimeOffset nowUtc,
            int windowSeconds)
        {
            if (windowSeconds <= 0)
            {
                state.ClearRecommendations();
            }
            else
            {
                var cutoffUtc = nowUtc - TimeSpan.FromSeconds(windowSeconds);
                state.RemoveRecommendationsOlderThan(cutoffUtc);
            }

            state.AddRecommendation(new ScaleRecommendation(nowUtc, desiredReplicas));
        }

        private static int CalculateProportionalRecommendation(double work, double targetPerReplica)
        {
            double recommendation = Math.Ceiling(work / targetPerReplica);
            return recommendation >= int.MaxValue ? int.MaxValue : (int)recommendation;
        }

        private static int Clamp(int v, int min, int max)
        {
            if (min > max) (min, max) = (max, min);
            if (v < min) return min;
            if (v > max) return max;
            return v;
        }

        private static int ApplyStepLimits(int current, int desired, ScaleConfig cfg)
        {
            if (desired == current) return desired;

            if (desired > current)
            {
                int step = Math.Max(0, cfg.StepUp);
                return step == 0 ? desired : Math.Min(desired, current + step);
            }
            else
            {
                int step = Math.Max(0, cfg.StepDown);
                return step == 0 ? desired : Math.Max(desired, current - step);
            }
        }
    }
}
