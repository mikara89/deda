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

            if (!TryGetBool(L, Key("enabled"), out var enabled) || !enabled)
                return null;

            var cfg = new ScaleConfig
            {
                Enabled = true,

                MinReplicas = GetInt(L, Key("min"), 0),
                MaxReplicas = GetInt(L, Key("max"), 50),

                TargetPerReplica = GetDouble(L, Key("targetPerReplica"), 50),
                ActivationThreshold = GetDouble(L, Key("activationThreshold"), 5),

                CooldownSeconds = GetInt(L, Key("cooldownSeconds"), 60),
                ScaleDownDelaySeconds = GetInt(L, Key("scaleDownDelaySeconds"), 120),
                ScaleToZeroGraceSeconds = GetInt(L, Key("scaleToZeroGraceSeconds"), 0),

                StepUp = GetInt(L, Key("stepUp"), 10),
                StepDown = GetInt(L, Key("stepDown"), 5),

                TriggerType = GetString(L, Key("trigger.type"), string.Empty),

                TriggerConfig = ExtractSubtree(L, Key("trigger."))
            };

            var fs = GetString(L, Key("failsafe"), "hold").ToLowerInvariant();
            cfg = cfg with
            {
                FailSafe = fs switch
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

        private static bool TryGetBool(IReadOnlyDictionary<string, string> labels, string key, out bool value)
        {
            value = false;
            return labels.TryGetValue(key, out var v) && bool.TryParse(v, out value);
        }

        private static int GetInt(IReadOnlyDictionary<string, string> labels, string key, int fallback)
            => labels.TryGetValue(key, out var v) &&
               int.TryParse(v, NumberStyles.Integer, CultureInfo.InvariantCulture, out var x)
                ? x : fallback;

        private static double GetDouble(IReadOnlyDictionary<string, string> labels, string key, double fallback)
            => labels.TryGetValue(key, out var v) &&
               double.TryParse(v, NumberStyles.Float, CultureInfo.InvariantCulture, out var x)
                ? x : fallback;

        private static string GetString(IReadOnlyDictionary<string, string> labels, string key, string fallback)
            => labels.TryGetValue(key, out var v) && !string.IsNullOrWhiteSpace(v) ? v.Trim() : fallback;
    }
}
