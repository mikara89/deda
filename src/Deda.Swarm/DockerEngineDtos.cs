using System.Text.Json;
using System.Text.Json.Serialization;

namespace Deda.Swarm
{
    internal sealed class ServiceListItemDto
    {
        [JsonPropertyName("ID")] public string? Id { get; set; }
        [JsonPropertyName("Version")] public VersionDto? Version { get; set; }
        [JsonPropertyName("Spec")] public ServiceSpecDto? Spec { get; set; }

        [JsonExtensionData] public Dictionary<string, JsonElement>? Extra { get; set; }
    }

    internal sealed class ServiceInspectDto
    {
        [JsonPropertyName("ID")] public string? Id { get; set; }
        [JsonPropertyName("Version")] public VersionDto? Version { get; set; }
        [JsonPropertyName("Spec")] public ServiceSpecDto? Spec { get; set; }

        [JsonExtensionData] public Dictionary<string, JsonElement>? Extra { get; set; }
    }

    internal sealed class VersionDto
    {
        [JsonPropertyName("Index")] public long Index { get; set; }
        [JsonExtensionData] public Dictionary<string, JsonElement>? Extra { get; set; }
    }

    internal sealed class ServiceSpecDto
    {
        [JsonPropertyName("Name")] public string? Name { get; set; }
        [JsonPropertyName("Labels")] public Dictionary<string, string>? Labels { get; set; }
        [JsonPropertyName("Mode")] public ServiceModeDto? Mode { get; set; }

        // Keep unknown fields so we don't delete them on update
        [JsonExtensionData] public Dictionary<string, JsonElement>? Extra { get; set; }
    }

    internal sealed class ServiceModeDto
    {
        [JsonPropertyName("Replicated")] public ReplicatedServiceDto? Replicated { get; set; }
        [JsonPropertyName("Global")] public JsonElement? Global { get; set; } // presence indicates global mode

        [JsonExtensionData] public Dictionary<string, JsonElement>? Extra { get; set; }
    }

    internal sealed class ReplicatedServiceDto
    {
        [JsonPropertyName("Replicas")] public long? Replicas { get; set; }
        [JsonExtensionData] public Dictionary<string, JsonElement>? Extra { get; set; }
    }
}
