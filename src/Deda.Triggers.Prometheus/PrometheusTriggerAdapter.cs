using Deda.Core;
using System.Globalization;
using System.Text.Json;

namespace Deda.Triggers.Prometheus
{
    /// <summary>
    /// Reads one scalar or exactly one vector element from the Prometheus instant query API.
    /// </summary>
    public sealed class PrometheusTriggerAdapter : ITriggerAdapter
    {
        public const string TriggerType = "prometheus";
        public string Type => TriggerType;

        private readonly IHttpClientFactory _httpClientFactory;

        public PrometheusTriggerAdapter(IHttpClientFactory httpClientFactory)
        {
            _httpClientFactory = httpClientFactory ?? throw new ArgumentNullException(nameof(httpClientFactory));
        }

        public async Task<TriggerResult> GetWorkAsync(ServiceRef service, ScaleConfig config, CancellationToken ct)
        {
            try
            {
                if (!config.TriggerConfig.TryGetValue("url", out var baseUrl) || string.IsNullOrWhiteSpace(baseUrl))
                    return TriggerResult.Fail("prometheus trigger requires trigger.url");

                if (!config.TriggerConfig.TryGetValue("query", out var query) || string.IsNullOrWhiteSpace(query))
                    return TriggerResult.Fail("prometheus trigger requires trigger.query");

                var timeoutSeconds = ReadTimeoutSeconds(config);
                var url = BuildQueryUri(baseUrl, query);

                var client = _httpClientFactory.CreateClient("prometheus");
                client.Timeout = TimeSpan.FromSeconds(timeoutSeconds);

                using var resp = await client.GetAsync(url, ct).ConfigureAwait(false);
                if (!resp.IsSuccessStatusCode)
                {
                    var body = await SafeRead(resp, ct).ConfigureAwait(false);
                    return TriggerResult.Fail($"prometheus http {(int)resp.StatusCode}: {Truncate(body, 200)}");
                }

                await using var stream = await resp.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
                using var document = await JsonDocument.ParseAsync(stream, cancellationToken: ct).ConfigureAwait(false);
                return ParseResponse(document.RootElement);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                throw;
            }
            catch (Exception ex)
            {
                return TriggerResult.Fail($"{ex.GetType().Name}: {ex.Message}");
            }
        }

        private static TriggerResult ParseResponse(JsonElement root)
        {
            var status = root.TryGetProperty("status", out var statusElement)
                ? statusElement.GetString()
                : null;
            if (!string.Equals(status, "success", StringComparison.OrdinalIgnoreCase))
            {
                var errorType = GetOptionalString(root, "errorType");
                var error = GetOptionalString(root, "error");
                return TriggerResult.Fail($"prometheus: {errorType}:{error}");
            }

            if (!root.TryGetProperty("data", out var data) ||
                !data.TryGetProperty("resultType", out var resultTypeElement) ||
                !data.TryGetProperty("result", out var result))
            {
                return TriggerResult.Fail("prometheus: invalid response shape");
            }

            return resultTypeElement.GetString() switch
            {
                "scalar" => ParseValuePair(result, "scalar"),
                "vector" => ParseVector(result),
                var resultType => TriggerResult.Fail($"prometheus: unsupported result type '{resultType}'"),
            };
        }

        private static TriggerResult ParseVector(JsonElement result)
        {
            if (result.ValueKind != JsonValueKind.Array)
                return TriggerResult.Fail("prometheus: vector result is not an array");

            var count = result.GetArrayLength();
            if (count == 0)
                return TriggerResult.Ok(0);
            if (count != 1)
                return TriggerResult.Fail($"prometheus: ambiguous vector result contains {count} series");

            var series = result[0];
            if (!series.TryGetProperty("value", out var value))
                return TriggerResult.Fail("prometheus: vector value missing");

            return ParseValuePair(value, "vector");
        }

        private static TriggerResult ParseValuePair(JsonElement value, string resultType)
        {
            if (value.ValueKind != JsonValueKind.Array || value.GetArrayLength() < 2)
                return TriggerResult.Fail($"prometheus: invalid {resultType} value shape");

            var metricValue = value[1];
            var text = metricValue.ValueKind == JsonValueKind.String
                ? metricValue.GetString()
                : metricValue.GetRawText();

            if (!double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var work))
                return TriggerResult.Fail($"prometheus: non-numeric value '{text}'");

            return TriggerResult.Ok(work);
        }

        private static int ReadTimeoutSeconds(ScaleConfig config) =>
            config.TriggerConfig.TryGetValue("timeoutSeconds", out var timeout) &&
            int.TryParse(timeout, NumberStyles.Integer, CultureInfo.InvariantCulture, out var seconds) &&
            seconds > 0
                ? Math.Min(seconds, 120)
                : 5;

        private static string BuildQueryUri(string baseUrl, string promql)
        {
            var baseUri = new Uri(baseUrl.TrimEnd('/') + "/");
            var query = Uri.EscapeDataString(promql);
            return new Uri(baseUri, $"api/v1/query?query={query}").ToString();
        }

        private static string? GetOptionalString(JsonElement element, string propertyName) =>
            element.TryGetProperty(propertyName, out var property) ? property.GetString() : null;

        private static async Task<string> SafeRead(HttpResponseMessage response, CancellationToken ct)
        {
            try { return await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false); }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch { return string.Empty; }
        }

        private static string Truncate(string value, int max) =>
            string.IsNullOrEmpty(value)
                ? value
                : value.Length <= max ? value : value.Substring(0, max) + "...";
    }
}
