using System.Text.Json.Serialization;

namespace Deda.Host;

internal sealed record LiveHealthResponse(string Status);

internal sealed record ReadyHealthResponse(
    string Status,
    DateTimeOffset? LastAttemptUtc,
    DateTimeOffset? LastSuccessfulUtc);

[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase)]
[JsonSerializable(typeof(LiveHealthResponse))]
[JsonSerializable(typeof(ReadyHealthResponse))]
internal partial class HealthJsonContext : JsonSerializerContext;
