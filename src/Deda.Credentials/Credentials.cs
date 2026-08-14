using Deda.Core;
using System.Text.Json;

namespace Deda.Credentials;

public interface ISecretResolver
{
    string Resolve(string secretName);
}

public sealed record CredentialBinding(
    string Type,
    string Secret,
    IReadOnlySet<string> AllowedHosts,
    IReadOnlySet<string> AllowedServices);

public sealed class CredentialPolicy
{
    private readonly IReadOnlyDictionary<string, CredentialBinding> _bindings;

    public CredentialPolicy(IReadOnlyDictionary<string, CredentialBinding>? bindings = null) =>
        _bindings = bindings ?? new Dictionary<string, CredentialBinding>(StringComparer.OrdinalIgnoreCase);

    public static CredentialPolicy FromJsonFile(string? path)
    {
        if (string.IsNullOrWhiteSpace(path)) return new();
        using var document = JsonDocument.Parse(File.ReadAllText(path));
        if (document.RootElement.ValueKind != JsonValueKind.Object)
            throw new InvalidOperationException("Credential policy file must contain an object.");

        var bindings = new Dictionary<string, CredentialBinding>(StringComparer.OrdinalIgnoreCase);
        foreach (var entry in document.RootElement.EnumerateObject())
        {
            if (entry.Value.ValueKind != JsonValueKind.Object)
                throw new InvalidOperationException($"Credential '{entry.Name}' must be an object.");
            bindings.Add(entry.Name, new CredentialBinding(
                OptionalString(entry.Value, "type") ?? string.Empty,
                RequiredString(entry.Value, "secret", entry.Name),
                ReadStringSet(entry.Value, "allowedHosts", entry.Name),
                ReadStringSet(entry.Value, "allowedServices", entry.Name)));
        }
        return new(bindings);
    }

    public CredentialBinding Resolve(ServiceRef service, string reference, Uri endpoint, string? expectedType = null)
    {
        if (!_bindings.TryGetValue(reference, out var binding))
            throw new InvalidOperationException($"Credential reference '{reference}' is not defined by the operator policy.");
        if (!string.IsNullOrWhiteSpace(expectedType) && !string.Equals(binding.Type, expectedType, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException($"Credential reference '{reference}' is not a '{expectedType}' credential.");
        if (binding.AllowedHosts.Count == 0)
            throw new InvalidOperationException($"Credential reference '{reference}' must define at least one allowed host.");
        if (!binding.AllowedHosts.Contains(endpoint.Host))
            throw new InvalidOperationException($"Endpoint host '{endpoint.Host}' is not allowed for credential reference '{reference}'.");
        if (binding.AllowedServices.Count > 0 && !binding.AllowedServices.Contains(service.Name) && !binding.AllowedServices.Contains(service.ServiceId))
            throw new InvalidOperationException($"Service '{service.Name}' is not permitted to use credential reference '{reference}'.");
        return binding;
    }

    private static string RequiredString(JsonElement entry, string property, string reference) =>
        OptionalString(entry, property) ?? throw new InvalidOperationException($"Credential '{reference}' must contain a non-empty '{property}'.");
    private static string? OptionalString(JsonElement entry, string property) =>
        entry.TryGetProperty(property, out var value) && value.ValueKind == JsonValueKind.String && !string.IsNullOrWhiteSpace(value.GetString()) ? value.GetString()!.Trim() : null;
    private static IReadOnlySet<string> ReadStringSet(JsonElement entry, string property, string reference)
    {
        if (!entry.TryGetProperty(property, out var value)) return new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if (value.ValueKind != JsonValueKind.Array) throw new InvalidOperationException($"Credential '{reference}' property '{property}' must be an array.");
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

public sealed class DockerSecretFileResolver(string secretsDirectory) : ISecretResolver
{
    private readonly string _secretsDirectory = string.IsNullOrWhiteSpace(secretsDirectory)
        ? throw new ArgumentException("Secrets directory is required.", nameof(secretsDirectory))
        : Path.GetFullPath(secretsDirectory);

    public string Resolve(string secretName)
    {
        if (string.IsNullOrWhiteSpace(secretName) || !string.Equals(Path.GetFileName(secretName), secretName, StringComparison.Ordinal))
            throw new InvalidOperationException("Docker secret name must be a single file name.");
        var path = Path.GetFullPath(Path.Combine(_secretsDirectory, secretName));
        var relative = Path.GetRelativePath(_secretsDirectory, path);
        if (relative.StartsWith("..", StringComparison.Ordinal) || Path.IsPathRooted(relative))
            throw new InvalidOperationException("Docker secret path escapes the configured secrets directory.");
        if (!File.Exists(path)) throw new InvalidOperationException($"Docker secret '{secretName}' is not mounted.");
        return File.ReadAllText(path);
    }
}

public sealed class CredentialTokenProvider(ISecretResolver secretResolver, CredentialPolicy policy)
{
    public string Get(ServiceRef service, ScaleConfig config, Uri endpoint, string credentialType)
    {
        if (!config.TriggerConfig.TryGetValue("credentialsRef", out var reference) || string.IsNullOrWhiteSpace(reference))
            throw new InvalidOperationException($"{credentialType} trigger requires trigger.credentialsRef.");
        var binding = policy.Resolve(service, reference.Trim(), endpoint, credentialType);
        var token = secretResolver.Resolve(binding.Secret).Trim();
        return token.Length == 0 ? throw new InvalidOperationException($"Docker secret '{binding.Secret}' is empty.") : token;
    }
}
