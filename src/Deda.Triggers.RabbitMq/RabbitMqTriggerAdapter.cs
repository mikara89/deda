using Deda.Core;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace Deda.Triggers.RabbitMq
{
    /// <summary>
    /// RabbitMQ trigger using the Management HTTP API:
    /// GET /api/queues/{vhost}/{queue}
    /// Metric can be: messages (default), messages_ready, messages_unacknowledged
    /// </summary>
    public sealed class RabbitMqTriggerAdapter : ITriggerAdapter
    {
        public const string TriggerType = "rabbitmq";
        public string Type => TriggerType;

        private readonly IHttpClientFactory _httpClientFactory;
        private readonly IRabbitMqCredentialsProvider _creds;

        public RabbitMqTriggerAdapter(IHttpClientFactory httpClientFactory, IRabbitMqCredentialsProvider creds)
        {
            _httpClientFactory = httpClientFactory ?? throw new ArgumentNullException(nameof(httpClientFactory));
            _creds = creds ?? throw new ArgumentNullException(nameof(creds));
        }

        public async Task<TriggerResult> GetWorkAsync(ServiceRef service, ScaleConfig config, CancellationToken ct)
        {
            try
            {
                // trigger.url, trigger.vhost, trigger.queue, trigger.metric
                if (!config.TriggerConfig.TryGetValue("url", out var baseUrl) || string.IsNullOrWhiteSpace(baseUrl))
                    return TriggerResult.Fail("rabbitmq trigger requires trigger.url");

                if (!config.TriggerConfig.TryGetValue("queue", out var queue) || string.IsNullOrWhiteSpace(queue))
                    return TriggerResult.Fail("rabbitmq trigger requires trigger.queue");

                var vhost = config.TriggerConfig.TryGetValue("vhost", out var vh) && !string.IsNullOrWhiteSpace(vh)
                    ? vh
                    : "/";

                var metric = config.TriggerConfig.TryGetValue("metric", out var m) && !string.IsNullOrWhiteSpace(m)
                    ? m.Trim()
                    : "messages";

                var timeoutSeconds =
                    config.TriggerConfig.TryGetValue("timeoutSeconds", out var ts) && int.TryParse(ts, out var tsv) && tsv > 0
                        ? tsv
                        : 5;

                var uri = BuildQueueUri(baseUrl, vhost, queue);

                var client = _httpClientFactory.CreateClient("rabbitmq");
                client.Timeout = TimeSpan.FromSeconds(timeoutSeconds);

                using var req = new HttpRequestMessage(HttpMethod.Get, uri);
                ApplyBasicAuth(req, service, config);

                using var resp = await client.SendAsync(req, ct).ConfigureAwait(false);

                if (!resp.IsSuccessStatusCode)
                {
                    var body = await SafeReadBody(resp, ct).ConfigureAwait(false);
                    return TriggerResult.Fail($"rabbitmq http {(int)resp.StatusCode}: {Truncate(body, 200)}");
                }

                await using var stream = await resp.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
                using var doc = await JsonDocument.ParseAsync(stream, cancellationToken: ct).ConfigureAwait(false);

                if (!doc.RootElement.TryGetProperty(metric, out var metricEl))
                    return TriggerResult.Fail($"rabbitmq metric '{metric}' missing in response");

                if (metricEl.ValueKind != JsonValueKind.Number)
                    return TriggerResult.Fail($"rabbitmq metric '{metric}' is not numeric");

                var work = metricEl.GetDouble();
                return TriggerResult.Ok(work);
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

        private void ApplyBasicAuth(HttpRequestMessage req, ServiceRef service, ScaleConfig config)
        {
            var c = _creds.Get(service, config);
            var token = Convert.ToBase64String(Encoding.UTF8.GetBytes($"{c.Username}:{c.Password}"));
            req.Headers.Authorization = new AuthenticationHeaderValue("Basic", token);
        }

        private static Uri BuildQueueUri(string baseUrl, string vhost, string queue)
        {
            // RabbitMQ requires URL-encoding in the path. vhost "/" => "%2F".
            var baseUri = new Uri(baseUrl.TrimEnd('/') + "/");
            var v = Uri.EscapeDataString(vhost);
            var q = Uri.EscapeDataString(queue);
            var rel = $"api/queues/{v}/{q}";
            return new Uri(baseUri, rel);
        }

        private static async Task<string> SafeReadBody(HttpResponseMessage resp, CancellationToken ct)
        {
            try { return await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false); }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch { return string.Empty; }
        }

        private static string Truncate(string s, int max)
        {
            if (string.IsNullOrEmpty(s)) return s;
            return s.Length <= max ? s : s.Substring(0, max) + "...";
        }
    }
}
