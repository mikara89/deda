using Deda.Core;
using System.Globalization;
using System.Text.Json;

namespace Deda.Triggers.Prometheus
{
    /// <summary>
    /// Prometheus trigger:
    /// - Calls: GET {url}/api/v1/query?query=...
    /// - Expects a single timeseries result OR multiple, but we take the first for MVP.
    /// - Work is the numeric value.
    ///
    /// Labels:
    /// com.deda.autoscale.trigger.type=prometheus
    /// com.deda.autoscale.trigger.url=http://prometheus:9090
    /// com.deda.autoscale.trigger.query=sum(rate(...[1m]))
    /// optional: timeoutSeconds=5
    /// </summary>
    public sealed class PrometheusTriggerAdapter : ITriggerAdapter
    {
        public const string TriggerType = "prometheus";
        public string Type => TriggerType;

        private readonly IHttpClientFactory _httpClientFactory;
        private static readonly PrometheusJsonContext JsonCtx = PrometheusJsonContext.Default;

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

                var timeoutSeconds =
                    config.TriggerConfig.TryGetValue("timeoutSeconds", out var ts) && int.TryParse(ts, out var tsv) && tsv > 0
                        ? tsv
                        : 5;

                var url = BuildQueryUri(baseUrl, query);

                var client = _httpClientFactory.CreateClient("prometheus");
                client.Timeout = TimeSpan.FromSeconds(timeoutSeconds);

                using var resp = await client.GetAsync(url, ct).ConfigureAwait(false);
                if (!resp.IsSuccessStatusCode)
                {
                    var body = await SafeRead(resp, ct).ConfigureAwait(false);
                    return TriggerResult.Fail($"prometheus http {(int)resp.StatusCode}: {Trunc(body, 200)}");
                }

                await using var stream = await resp.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
                var dto = await JsonSerializer.DeserializeAsync(stream, JsonCtx.PromQueryResponse, ct).ConfigureAwait(false);

                if (dto is null)
                    return TriggerResult.Fail("prometheus: empty response");

                if (!string.Equals(dto.Status, "success", StringComparison.OrdinalIgnoreCase))
                    return TriggerResult.Fail($"prometheus: {dto.ErrorType}:{dto.Error}");

                var result = dto.Data?.Result;
                if (result is null || result.Count == 0)
                    return TriggerResult.Ok(0); // no data => 0 work

                // MVP: take the first series
                var valueArr = result[0].Value;
                if (valueArr is null || valueArr.Count < 2)
                    return TriggerResult.Fail("prometheus: invalid value shape");

                var strVal = valueArr[1]?.ToString();
                if (!double.TryParse(strVal, NumberStyles.Float, CultureInfo.InvariantCulture, out var work))
                    return TriggerResult.Fail($"prometheus: non-numeric value '{strVal}'");

                return TriggerResult.Ok(work);
            }
            catch (Exception ex)
            {
                return TriggerResult.Fail($"{ex.GetType().Name}: {ex.Message}");
            }
        }

        private static string BuildQueryUri(string baseUrl, string promql)
        {
            var baseUri = new Uri(baseUrl.TrimEnd('/') + "/");
            var q = Uri.EscapeDataString(promql);
            return new Uri(baseUri, $"api/v1/query?query={q}").ToString();
        }

        private static async Task<string> SafeRead(HttpResponseMessage resp, CancellationToken ct)
        {
            try { return await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false); }
            catch { return string.Empty; }
        }

        private static string Trunc(string s, int max)
            => string.IsNullOrEmpty(s) ? s : (s.Length <= max ? s : s.Substring(0, max) + "...");
    }
}
