namespace Deda.Host
{
    public sealed class DedaHostOptions
    {
        /// <summary>Global reconcile loop interval. (Per-service pollSeconds can be added later)</summary>
        public int PollSeconds { get; init; } = 10;

        /// <summary>Named HttpClient timeout defaults (seconds) if triggers don't override.</summary>
        public int DefaultHttpTimeoutSeconds { get; init; } = 5;

        /// <summary>Reserved compatibility setting; structured decision logging is currently always enabled.</summary>
        public bool LogDecisions { get; init; } = true;

        public int MaxServicesPerCycle { get; init; } = 0; // 0 = no cap
        public bool JitterEnabled { get; init; } = true;
        public int MaxReconcileBackoffSeconds { get; init; } = 60;
        public string SecretsDirectory { get; init; } = "/run/secrets";
        public string? CredentialPolicyFile { get; init; }
        public bool AllowLegacyCredentialsSecret { get; init; }
        public int MaxConcurrentServices { get; init; } = 8;
        public int ReconcileTimeoutSeconds { get; init; } = 120;
        public int ReadinessMaxAgeSeconds { get; init; } = 60;
        public int HttpPort { get; init; } = 8080;
        public string? RedisConnectionString { get; init; }
        public string LeaderLockKey { get; init; } = "deda:leader";
        public string LeaderInstanceId { get; init; } = $"{Environment.MachineName}-{Environment.ProcessId}";
        public int LeaderLeaseSeconds { get; init; } = 30;
        public int LeaderRenewSeconds { get; init; } = 10;

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
                CredentialPolicyFile = ReadOptionalString("DEDA_CREDENTIAL_POLICY_FILE"),
                AllowLegacyCredentialsSecret = ReadBool("DEDA_ALLOW_LEGACY_CREDENTIALS_SECRET", false),
                MaxConcurrentServices = ReadInt("DEDA_MAX_CONCURRENT_SERVICES", 8, 1, 256),
                ReconcileTimeoutSeconds = ReadInt("DEDA_RECONCILE_TIMEOUT_SECONDS", 120, 1, 3600),
                ReadinessMaxAgeSeconds = ReadInt("DEDA_READINESS_MAX_AGE_SECONDS", 60, 1, 3600),
                HttpPort = ReadInt("DEDA_HTTP_PORT", 8080, 1, 65535),
                RedisConnectionString = ReadOptionalString("DEDA_REDIS_CONNECTION"),
                LeaderLockKey = ReadString("DEDA_LEADER_LOCK_KEY", "deda:leader"),
                LeaderInstanceId = ReadString(
                    "DEDA_INSTANCE_ID",
                    $"{Environment.MachineName}-{Environment.ProcessId}"),
                LeaderLeaseSeconds = ReadInt("DEDA_LEADER_LEASE_SECONDS", 30, 5, 300),
                LeaderRenewSeconds = ReadInt("DEDA_LEADER_RENEW_SECONDS", 10, 1, 299),
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

        private static string? ReadOptionalString(string key)
        {
            var value = Environment.GetEnvironmentVariable(key);
            return string.IsNullOrWhiteSpace(value) ? null : value.Trim();
        }
    }
}
