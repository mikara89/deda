using Deda.Core;

namespace Deda.Policies
{
    public sealed class SimpleScalePolicyMvp : IScalePolicy
    {
        public ScaleDecision Decide(ServiceRef service, ScaleConfig cfg, TriggerResult trigger, ServiceScaleState state, DateTimeOffset nowUtc)
        {
            int current = service.CurrentReplicas;

            if (!trigger.Success)
            {
                int desiredFail = cfg.FailSafe switch
                {
                    FailSafeMode.Min => cfg.MinReplicas,
                    FailSafeMode.Max => cfg.MaxReplicas,
                    _ => current
                };

                desiredFail = Clamp(desiredFail, cfg.MinReplicas, cfg.MaxReplicas);

                return new ScaleDecision(service.ServiceId, service.Name, current, desiredFail, 0,
                    $"trigger_failed:{trigger.Error}", nowUtc);
            }

            // Base desired
            int raw =
                trigger.Work <= cfg.ActivationThreshold
                    ? cfg.MinReplicas
                    : (int)Math.Ceiling(trigger.Work / cfg.TargetPerReplica);

            int bounded = Clamp(raw, cfg.MinReplicas, cfg.MaxReplicas);

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

            // Scale-down delay window: only allow downscale if sustained low demand
            bool blockedByDelayWindow = false;
            if (!blockedByCooldown && stabilized < current)
            {
                int required = RequiredSamples(cfg.PollSeconds, cfg.ScaleDownDelaySeconds);
                if (!HasSustainedLowDemand(state, required, cfg.ActivationThreshold))
                {
                    stabilized = current;
                    blockedByDelayWindow = true;
                }
            }

            // Step limits
            int final = ApplyStepLimits(current, stabilized, cfg);

            string reason =
                $"work={trigger.Work:0.##} raw={raw} bounded={bounded} stabilized={stabilized} final={final} " +
                $"cooldownBlocked={blockedByCooldown} delayBlocked={blockedByDelayWindow} " +
                $"needSamples={RequiredSamples(cfg.PollSeconds, cfg.ScaleDownDelaySeconds)} samplesHave={state.RecentWork.Count} trig={cfg.TriggerType}";


            return new ScaleDecision(service.ServiceId, service.Name, current, final, trigger.Work, reason, nowUtc);
        }

        private static int RequiredSamples(int pollSeconds, int windowSeconds)
        {
            if (pollSeconds <= 0) pollSeconds = 1;
            if (windowSeconds <= 0) return 1;
            return Math.Max(1, (int)Math.Ceiling(windowSeconds / (double)pollSeconds));
        }

        private static bool HasSustainedLowDemand(ServiceScaleState state, int requiredSamples, double threshold)
        {
            var samples = state.RecentWork.Snapshot();
            if (samples.Count < requiredSamples) return false;

            // Check last N samples are <= threshold
            for (int i = samples.Count - requiredSamples; i < samples.Count; i++)
            {
                if (samples[i] > threshold)
                    return false;
            }
            return true;
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
