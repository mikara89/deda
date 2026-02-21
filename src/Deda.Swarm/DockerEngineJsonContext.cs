using System.Text.Json.Serialization;

namespace Deda.Swarm
{
    // Source-generated metadata for NativeAOT-friendly (de)serialization.
    // Add types here as needed.
    [JsonSourceGenerationOptions(
        PropertyNameCaseInsensitive = true,
        WriteIndented = false,
        GenerationMode = JsonSourceGenerationMode.Metadata // best AOT compatibility
    )]
    [JsonSerializable(typeof(List<ServiceListItemDto>))]
    [JsonSerializable(typeof(ServiceInspectDto))]
    [JsonSerializable(typeof(ServiceSpecDto))]
    [JsonSerializable(typeof(Dictionary<string, string>))]
    internal partial class DockerEngineJsonContext : JsonSerializerContext
    {
    }
}
