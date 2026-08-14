using System.Text.Json.Serialization;
using Microsoft.AspNetCore.Mvc;

namespace Deda.Host;

internal sealed record LiveHealthResponse(string Status);

internal sealed record ReadyHealthResponse(
    string Status,
    DateTimeOffset? LastAttemptUtc,
    DateTimeOffset? LastSuccessfulUtc);

[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase)]
[JsonSerializable(typeof(LiveHealthResponse))]
[JsonSerializable(typeof(ReadyHealthResponse))]
[JsonSerializable(typeof(ProblemDetails))]
internal partial class HealthJsonContext : JsonSerializerContext;
