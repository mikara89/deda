namespace Deda.Host
{
    public sealed class DedaHostOptions
    {
        /// <summary>Global reconcile loop interval. (Per-service pollSeconds can be added later)</summary>
        public int PollSeconds { get; init; } = 10;

        /// <summary>Named HttpClient timeout defaults (seconds) if triggers don't override.</summary>
        public int DefaultHttpTimeoutSeconds { get; init; } = 5;

        /// <summary>Log decisions to console (MVP "logs").</summary>
        public bool LogDecisions { get; init; } = true;

        public int MaxServicesPerCycle { get; init; } = 0; // 0 = no cap
        public bool JitterEnabled { get; init; } = true;
        public int MaxReconcileBackoffSeconds { get; init; } = 60;
        public string SecretsDirectory { get; init; } = "/run/secrets";

        public static DedaHostOptions FromEnvironment()
        {
            return new DedaHostOptions
            {
                PollSeconds = ReadInt("DEDA_POLL_SECONDS", 10, min: 1, max: 3600),
                DefaultHttpTimeoutSeconds = ReadInt("DEDA_HTTP_TIMEOUT_SECONDS", 5, min: 1, max: 120),
                LogDecisions = ReadBool("DEDA_LOG_DECISIONS", true),
                MaxServicesPerCycle = ReadInt("DEDA_MAX_SERVICES_PER_CYCLE", 0, 0, 10_000),
                JitterEnabled = ReadBool("DEDA_JITTER_ENABLED", true),
                MaxReconcileBackoffSeconds = ReadInt("DEDA_MAX_RECONCILE_BACKOFF_SECONDS", 60, 1, 3600),
                SecretsDirectory = ReadString("DEDA_SECRETS_DIRECTORY", "/run/secrets"),
            };
        }

        private static int ReadInt(string key, int fallback, int min, int max)
        {
            var s = Environment.GetEnvironmentVariable(key);
            if (!int.TryParse(s, out var v)) return fallback;
            if (v < min) return min;
            if (v > max) return max;
            return v;
        }

        private static bool ReadBool(string key, bool fallback)
        {
            var s = Environment.GetEnvironmentVariable(key);
            return bool.TryParse(s, out var v) ? v : fallback;
        }

        private static string ReadString(string key, string fallback)
        {
            var value = Environment.GetEnvironmentVariable(key);
            return string.IsNullOrWhiteSpace(value) ? fallback : value.Trim();
        }
    }
}
