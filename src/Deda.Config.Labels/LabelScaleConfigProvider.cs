using Deda.Core;
using System.Globalization;

namespace Deda.Config.Labels
{
    /// <summary>
    /// Parses autoscaling config from Swarm service labels under "com.deda.autoscale.*"
    /// </summary>
    public sealed class LabelScaleConfigProvider : IScaleConfigProvider
    {
        public const string Prefix = "com.deda.autoscale.";

        public ScaleConfig? TryGetConfig(ServiceRef service, out string? error)
        {
            error = null;
            var L = service.Labels;

            if (L is null || L.Count == 0) return null;

            if (!TryGetOptionalBool(L, Key("enabled"), out var enabled, out error))
                return null;
            if (!enabled)
                return null;

            if (!TryGetInt(L, Key("min"), 0, out var min, out error) ||
                !TryGetInt(L, Key("max"), 50, out var max, out error) ||
                !TryGetDouble(L, Key("targetPerReplica"), 50, out var target, out error) ||
                !TryGetDouble(L, Key("activationThreshold"), 5, out var activation, out error) ||
                !TryGetInt(L, Key("cooldownSeconds"), 60, out var cooldown, out error) ||
                !TryGetInt(L, Key("scaleDownDelaySeconds"), 120, out var scaleDownDelay, out error) ||
                !TryGetInt(L, Key("scaleToZeroGraceSeconds"), 0, out var scaleToZeroGrace, out error) ||
                !TryGetInt(L, Key("stepUp"), 10, out var stepUp, out error) ||
                !TryGetInt(L, Key("stepDown"), 5, out var stepDown, out error))
                return null;

            var failsafe = GetString(L, Key("failsafe"), "hold").ToLowerInvariant();
            if (failsafe is not ("hold" or "min" or "max"))
            {
                error = $"failsafe must be one of hold, min, or max (was '{failsafe}').";
                return null;
            }

            var cfg = new ScaleConfig
            {
                Enabled = true,

                MinReplicas = min,
                MaxReplicas = max,

                TargetPerReplica = target,
                ActivationThreshold = activation,

                CooldownSeconds = cooldown,
                ScaleDownDelaySeconds = scaleDownDelay,
                ScaleToZeroGraceSeconds = scaleToZeroGrace,

                StepUp = stepUp,
                StepDown = stepDown,

                TriggerType = GetString(L, Key("trigger.type"), string.Empty),

                TriggerConfig = ExtractSubtree(L, Key("trigger."))
            };

            cfg = cfg with
            {
                FailSafe = failsafe switch
                {
                    "min" => FailSafeMode.Min,
                    "max" => FailSafeMode.Max,
                    _ => FailSafeMode.Hold
                }
            };

            if (!Validate(cfg, out error))
                return null;

            return cfg;
        }

        private static string Key(string suffix) => Prefix + suffix;

        private static bool Validate(ScaleConfig cfg, out string? error)
        {
            error = null;

            if (!cfg.Enabled) { error = "autoscale disabled"; return false; }

            if (cfg.MinReplicas < 0) { error = "min < 0"; return false; }
            if (cfg.MaxReplicas < 0) { error = "max < 0"; return false; }
            if (cfg.MinReplicas > cfg.MaxReplicas) { error = "min > max"; return false; }

            if (!double.IsFinite(cfg.TargetPerReplica) || cfg.TargetPerReplica <= 0)
            { error = "targetPerReplica must be finite and > 0"; return false; }
            if (!double.IsFinite(cfg.ActivationThreshold) || cfg.ActivationThreshold < 0)
            { error = "activationThreshold must be finite and >= 0"; return false; }

            if (cfg.CooldownSeconds < 0) { error = "cooldownSeconds < 0"; return false; }
            if (cfg.ScaleDownDelaySeconds < 0) { error = "scaleDownDelaySeconds < 0"; return false; }
            if (cfg.ScaleDownDelaySeconds > 86_400) { error = "scaleDownDelaySeconds > 86400"; return false; }
            if (cfg.ScaleToZeroGraceSeconds < 0) { error = "scaleToZeroGraceSeconds < 0"; return false; }
            if (cfg.ScaleToZeroGraceSeconds > 86_400) { error = "scaleToZeroGraceSeconds > 86400"; return false; }
            if (cfg.StepUp < 0) { error = "stepUp < 0"; return false; }
            if (cfg.StepDown < 0) { error = "stepDown < 0"; return false; }

            if (string.IsNullOrWhiteSpace(cfg.TriggerType))
            {
                error = "trigger.type missing";
                return false;
            }

            return true;
        }

        private static IReadOnlyDictionary<string, string> ExtractSubtree(
            IReadOnlyDictionary<string, string> labels,
            string prefixWithDot)
        {
            var dict = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

            foreach (var kv in labels)
            {
                if (kv.Key.StartsWith(prefixWithDot, StringComparison.OrdinalIgnoreCase))
                {
                    var shortKey = kv.Key.Substring(prefixWithDot.Length);
                    dict[shortKey] = kv.Value;
                }
            }

            return dict;
        }

        private static bool TryGetOptionalBool(IReadOnlyDictionary<string, string> labels, string key, out bool value, out string? error)
        {
            error = null;
            value = false;
            if (!labels.TryGetValue(key, out var v))
                return true;
            if (bool.TryParse(v, out value))
                return true;
            error = $"{key} must be true or false (was '{v}').";
            return false;
        }

        private static bool TryGetInt(IReadOnlyDictionary<string, string> labels, string key, int fallback, out int value, out string? error)
        {
            error = null;
            value = fallback;
            if (!labels.TryGetValue(key, out var v)) return true;
            if (int.TryParse(v, NumberStyles.Integer, CultureInfo.InvariantCulture, out value)) return true;
            error = $"{key} must be an integer (was '{v}').";
            return false;
        }

        private static bool TryGetDouble(IReadOnlyDictionary<string, string> labels, string key, double fallback, out double value, out string? error)
        {
            error = null;
            value = fallback;
            if (!labels.TryGetValue(key, out var v)) return true;
            if (double.TryParse(v, NumberStyles.Float, CultureInfo.InvariantCulture, out value)) return true;
            error = $"{key} must be a number (was '{v}').";
            return false;
        }

        private static string GetString(IReadOnlyDictionary<string, string> labels, string key, string fallback)
            => labels.TryGetValue(key, out var v) && !string.IsNullOrWhiteSpace(v) ? v.Trim() : fallback;
    }
}
