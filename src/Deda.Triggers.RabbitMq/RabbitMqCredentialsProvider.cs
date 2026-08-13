using Deda.Core;
using System.Text.Json;

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

    public sealed record RabbitMqCredentialBinding(
        string Secret,
        IReadOnlySet<string> AllowedHosts,
        IReadOnlySet<string> AllowedServices);

    public sealed class RabbitMqCredentialPolicy
    {
        private readonly IReadOnlyDictionary<string, RabbitMqCredentialBinding> _bindings;

        public RabbitMqCredentialPolicy(IReadOnlyDictionary<string, RabbitMqCredentialBinding>? bindings = null) =>
            _bindings = bindings ?? new Dictionary<string, RabbitMqCredentialBinding>(StringComparer.OrdinalIgnoreCase);

        public static RabbitMqCredentialPolicy FromJsonFile(string? path)
        {
            if (string.IsNullOrWhiteSpace(path)) return new();

            // JsonDocument is a DOM API and does not depend on reflection-based
            // serialization metadata, so this remains safe in the NativeAOT host.
            using var document = JsonDocument.Parse(File.ReadAllText(path));
            if (document.RootElement.ValueKind != JsonValueKind.Object)
                throw new InvalidOperationException("Credential policy file must contain an object.");

            var bindings = new Dictionary<string, RabbitMqCredentialBinding>(StringComparer.OrdinalIgnoreCase);
            foreach (var entry in document.RootElement.EnumerateObject())
            {
                if (entry.Value.ValueKind != JsonValueKind.Object)
                    throw new InvalidOperationException($"Credential '{entry.Name}' must be an object.");

                var secret = RequiredString(entry.Value, "secret", entry.Name);
                bindings.Add(entry.Name, new RabbitMqCredentialBinding(
                    secret,
                    ReadStringSet(entry.Value, "allowedHosts", entry.Name),
                    ReadStringSet(entry.Value, "allowedServices", entry.Name)));
            }

            return new RabbitMqCredentialPolicy(bindings);
        }
        public RabbitMqCredentialBinding Resolve(ServiceRef service, string reference, string url)
        {
            if (!_bindings.TryGetValue(reference, out var binding)) throw new InvalidOperationException($"RabbitMQ credential reference '{reference}' is not defined by the operator policy.");
            if (!Uri.TryCreate(url, UriKind.Absolute, out var endpoint) || string.IsNullOrWhiteSpace(endpoint.Host)) throw new InvalidOperationException("RabbitMQ trigger.url must be an absolute URL when credentialsRef is used.");
            if (!binding.AllowedHosts.Contains(endpoint.Host)) throw new InvalidOperationException($"RabbitMQ endpoint host '{endpoint.Host}' is not allowed for credential reference '{reference}'.");
            if (binding.AllowedServices.Count > 0 && !binding.AllowedServices.Contains(service.Name) && !binding.AllowedServices.Contains(service.ServiceId)) throw new InvalidOperationException($"Service '{service.Name}' is not permitted to use credential reference '{reference}'.");
            return binding;
        }
        private static string RequiredString(JsonElement entry, string property, string reference)
        {
            if (!entry.TryGetProperty(property, out var value) || value.ValueKind != JsonValueKind.String || string.IsNullOrWhiteSpace(value.GetString()))
                throw new InvalidOperationException($"Credential '{reference}' must contain a non-empty '{property}'.");
            return value.GetString()!.Trim();
        }

        private static IReadOnlySet<string> ReadStringSet(JsonElement entry, string property, string reference)
        {
            if (!entry.TryGetProperty(property, out var value))
                return new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            if (value.ValueKind != JsonValueKind.Array)
                throw new InvalidOperationException($"Credential '{reference}' property '{property}' must be an array.");

            var values = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var item in value.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.String || string.IsNullOrWhiteSpace(item.GetString()))
                    throw new InvalidOperationException($"Credential '{reference}' property '{property}' must contain non-empty strings.");
                values.Add(item.GetString()!.Trim());
            }
            return values;
        }
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
        private readonly RabbitMqCredentialPolicy _policy;
        private readonly bool _allowLegacyServiceSecret;

        public EnvOrFileRabbitMqCredentialsProvider(ISecretResolver secretResolver, RabbitMqCredentialPolicy? policy = null, bool allowLegacyServiceSecret = true)
        {
            _secretResolver = secretResolver;
            _policy = policy ?? new RabbitMqCredentialPolicy();
            _allowLegacyServiceSecret = allowLegacyServiceSecret;
        }

        public RabbitMqCredentials Get(ServiceRef service, ScaleConfig config)
        {
            if (config.TriggerConfig.TryGetValue("credentialsRef", out var reference) && !string.IsNullOrWhiteSpace(reference))
            {
                var url = config.TriggerConfig.GetValueOrDefault("url") ?? throw new InvalidOperationException("RabbitMQ trigger.url is required with credentialsRef.");
                var binding = _policy.Resolve(service, reference.Trim(), url);
                return ParseSecret(_secretResolver.Resolve(binding.Secret), binding.Secret);
            }
            if (config.TriggerConfig.TryGetValue("credentialsSecret", out var secretName) &&
                !string.IsNullOrWhiteSpace(secretName))
            {
                if (!_allowLegacyServiceSecret) throw new InvalidOperationException("trigger.credentialsSecret is disabled; configure an operator credential policy and use trigger.credentialsRef.");
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
