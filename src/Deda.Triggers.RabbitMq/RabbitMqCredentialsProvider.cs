using Deda.Core;

namespace Deda.Triggers.RabbitMq
{
    public sealed record RabbitMqCredentials(string Username, string Password);

    public interface IRabbitMqCredentialsProvider
    {
        RabbitMqCredentials Get(ServiceRef service, ScaleConfig config);
    }

    public interface ISecretResolver
    {
        string Resolve(string secretName);
    }

    public sealed class DockerSecretFileResolver : ISecretResolver
    {
        private readonly string _secretsDirectory;

        public DockerSecretFileResolver(string secretsDirectory)
        {
            if (string.IsNullOrWhiteSpace(secretsDirectory))
                throw new ArgumentException("Secrets directory is required.", nameof(secretsDirectory));

            _secretsDirectory = Path.GetFullPath(secretsDirectory);
        }

        public string Resolve(string secretName)
        {
            if (string.IsNullOrWhiteSpace(secretName) ||
                !string.Equals(Path.GetFileName(secretName), secretName, StringComparison.Ordinal))
            {
                throw new InvalidOperationException("Docker secret name must be a single file name.");
            }

            var secretPath = Path.GetFullPath(Path.Combine(_secretsDirectory, secretName));
            var relative = Path.GetRelativePath(_secretsDirectory, secretPath);
            if (relative.StartsWith("..", StringComparison.Ordinal) || Path.IsPathRooted(relative))
                throw new InvalidOperationException("Docker secret path escapes the configured secrets directory.");

            if (!File.Exists(secretPath))
                throw new InvalidOperationException($"Docker secret '{secretName}' is not mounted.");

            return File.ReadAllText(secretPath);
        }
    }

    /// <summary>
    /// Resolves per-service credentials from trigger.credentialsSecret first,
    /// then falls back to process-wide environment variables or secret files.
    /// </summary>
    public sealed class EnvOrFileRabbitMqCredentialsProvider : IRabbitMqCredentialsProvider
    {
        private readonly ISecretResolver _secretResolver;

        public EnvOrFileRabbitMqCredentialsProvider(ISecretResolver secretResolver)
        {
            _secretResolver = secretResolver;
        }

        public RabbitMqCredentials Get(ServiceRef service, ScaleConfig config)
        {
            if (config.TriggerConfig.TryGetValue("credentialsSecret", out var secretName) &&
                !string.IsNullOrWhiteSpace(secretName))
            {
                return ParseSecret(_secretResolver.Resolve(secretName.Trim()), secretName.Trim());
            }

            var user = ReadEnvOrFile("RABBITMQ_USER", "RABBITMQ_USER_FILE");
            var pass = ReadEnvOrFile("RABBITMQ_PASS", "RABBITMQ_PASS_FILE");

            if (string.IsNullOrWhiteSpace(user) || string.IsNullOrWhiteSpace(pass))
                throw new InvalidOperationException("RabbitMQ credentials not set (RABBITMQ_USER/PASS or *_FILE).");

            return new RabbitMqCredentials(user.Trim(), pass.Trim());
        }

        private static RabbitMqCredentials ParseSecret(string value, string secretName)
        {
            var trimmed = value.Trim();
            var separator = trimmed.IndexOf(':');
            if (separator <= 0 || separator == trimmed.Length - 1)
            {
                throw new InvalidOperationException(
                    $"Docker secret '{secretName}' must use the format username:password.");
            }

            var username = trimmed.Substring(0, separator).Trim();
            var password = trimmed.Substring(separator + 1).Trim();
            if (username.Length == 0 || password.Length == 0)
            {
                throw new InvalidOperationException(
                    $"Docker secret '{secretName}' must contain a non-empty username and password.");
            }

            return new RabbitMqCredentials(username, password);
        }

        private static string? ReadEnvOrFile(string envVar, string fileEnvVar)
        {
            var direct = Environment.GetEnvironmentVariable(envVar);
            if (!string.IsNullOrWhiteSpace(direct))
                return direct;

            var file = Environment.GetEnvironmentVariable(fileEnvVar);
            if (!string.IsNullOrWhiteSpace(file) && File.Exists(file))
                return File.ReadAllText(file);

            return null;
        }
    }
}
