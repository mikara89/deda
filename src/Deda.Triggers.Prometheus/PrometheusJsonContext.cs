using System.Text.Json.Serialization;

namespace Deda.Triggers.Prometheus
{
    [JsonSourceGenerationOptions(
        PropertyNameCaseInsensitive = true,
        WriteIndented = false,
        GenerationMode = JsonSourceGenerationMode.Metadata
    )]
    [JsonSerializable(typeof(PromQueryResponse))]
    [JsonSerializable(typeof(PromData))]
    [JsonSerializable(typeof(PromResult))]
    internal partial class PrometheusJsonContext : JsonSerializerContext
    {
    }
}
