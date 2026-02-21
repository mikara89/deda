using System.Collections.Generic;
using System.Text.Json.Serialization;

namespace Deda.Triggers.Prometheus
{
    internal sealed class PromQueryResponse
	{
		[JsonPropertyName("status")] public string? Status { get; set; }
		[JsonPropertyName("data")] public PromData? Data { get; set; }
		[JsonPropertyName("error")] public string? Error { get; set; }
		[JsonPropertyName("errorType")] public string? ErrorType { get; set; }
	}

	internal sealed class PromData
	{
		[JsonPropertyName("resultType")] public string? ResultType { get; set; }
		[JsonPropertyName("result")] public List<PromResult>? Result { get; set; }
	}

	internal sealed class PromResult
	{
		// "value": [ <timestamp>, "<stringValue>" ]
		[JsonPropertyName("value")] public List<object>? Value { get; set; }

		// We ignore metric labels for MVP; query should return a single series or we sum ourselves later.
		[JsonPropertyName("metric")] public Dictionary<string, string>? Metric { get; set; }
	}
}
