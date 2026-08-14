using Deda.Credentials;
using Deda.Core;

namespace Deda.Triggers.RabbitMq;

public sealed record RabbitMqCredentials(string Username, string Password);

public interface IRabbitMqCredentialsProvider
{
    RabbitMqCredentials Get(ServiceRef service, ScaleConfig config);
}

/// <summary>RabbitMQ compatibility provider backed by the shared credential policy.</summary>
public sealed class EnvOrFileRabbitMqCredentialsProvider(
    ISecretResolver secretResolver,
    CredentialPolicy? policy = null,
    bool allowLegacyServiceSecret = true) : IRabbitMqCredentialsProvider
{
    private readonly CredentialPolicy _policy = policy ?? new CredentialPolicy();

    public RabbitMqCredentials Get(ServiceRef service, ScaleConfig config)
    {
        if (config.TriggerConfig.TryGetValue("credentialsRef", out var reference) && !string.IsNullOrWhiteSpace(reference))
        {
            var url = config.TriggerConfig.GetValueOrDefault("url") ?? throw new InvalidOperationException("RabbitMQ trigger.url is required with credentialsRef.");
            if (!Uri.TryCreate(url, UriKind.Absolute, out var endpoint)) throw new InvalidOperationException("RabbitMQ trigger.url must be an absolute URL with credentialsRef.");
            return ParseSecret(secretResolver.Resolve(_policy.Resolve(service, reference.Trim(), endpoint, "rabbitmq", allowLegacyUntyped: true).Secret), reference.Trim());
        }
        if (config.TriggerConfig.TryGetValue("credentialsSecret", out var secretName) && !string.IsNullOrWhiteSpace(secretName))
        {
            if (!allowLegacyServiceSecret) throw new InvalidOperationException("trigger.credentialsSecret is disabled; configure an operator credential policy and use trigger.credentialsRef.");
            return ParseSecret(secretResolver.Resolve(secretName.Trim()), secretName.Trim());
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
            throw new InvalidOperationException($"Docker secret '{secretName}' must use the format username:password.");
        var username = trimmed[..separator].Trim();
        var password = trimmed[(separator + 1)..].Trim();
        if (username.Length == 0 || password.Length == 0)
            throw new InvalidOperationException($"Docker secret '{secretName}' must contain a non-empty username and password.");
        return new(username, password);
    }

    private static string? ReadEnvOrFile(string envVar, string fileEnvVar)
    {
        var direct = Environment.GetEnvironmentVariable(envVar);
        if (!string.IsNullOrWhiteSpace(direct)) return direct;
        var file = Environment.GetEnvironmentVariable(fileEnvVar);
        return !string.IsNullOrWhiteSpace(file) && File.Exists(file) ? File.ReadAllText(file) : null;
    }
}
