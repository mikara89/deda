using Deda.Core;

using System.Globalization;
using System.Text.Json;

namespace Deda.Triggers.Http;

public sealed class HttpTriggerAdapter(IHttpClientFactory httpClientFactory) : ITriggerAdapter
{
    public const string TriggerType = "http";
    private const int MaximumResponseCharacters = 65_536;

    public string Type => TriggerType;

    public async Task<TriggerResult> GetWorkAsync(
        ServiceRef service,
        ScaleConfig config,
        CancellationToken ct)
    {
        try
        {
            if (!config.TriggerConfig.TryGetValue("url", out var configuredUrl) ||
                !Uri.TryCreate(configuredUrl, UriKind.Absolute, out var url) ||
                (url.Scheme != Uri.UriSchemeHttp && url.Scheme != Uri.UriSchemeHttps))
                return TriggerResult.Fail("http trigger requires an absolute HTTP or HTTPS trigger.url");

            var client = httpClientFactory.CreateClient("http");
            client.Timeout = TimeSpan.FromSeconds(ReadTimeoutSeconds(config));
            using var response = await client.GetAsync(url, ct).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
                return TriggerResult.Fail($"http trigger returned status {(int)response.StatusCode}");

            if (response.Content.Headers.ContentLength > MaximumResponseCharacters)
                return TriggerResult.Fail("http trigger response exceeds 64 KiB");

            var body = await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
            if (body.Length > MaximumResponseCharacters)
                return TriggerResult.Fail("http trigger response exceeds 64 KiB");

            return ParseBody(body, config.TriggerConfig.GetValueOrDefault("valuePath"));
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

    private static TriggerResult ParseBody(string body, string? valuePath)
    {
        if (string.IsNullOrWhiteSpace(valuePath) && TryParseValue(body, out var plainValue))
            return TriggerResult.Ok(plainValue);

        try
        {
            using var document = JsonDocument.Parse(body);
            var value = document.RootElement;
            if (string.IsNullOrWhiteSpace(valuePath))
            {
                if (value.ValueKind == JsonValueKind.Object && value.TryGetProperty("value", out var property))
                    value = property;
            }
            else
            {
                foreach (var segment in valuePath.Split('.', StringSplitOptions.RemoveEmptyEntries))
                {
                    if (value.ValueKind != JsonValueKind.Object || !value.TryGetProperty(segment, out value))
                        return TriggerResult.Fail($"http trigger valuePath '{valuePath}' was not found");
                }
            }

            var text = value.ValueKind == JsonValueKind.String ? value.GetString() : value.GetRawText();
            return TryParseValue(text, out var work)
                ? TriggerResult.Ok(work)
                : TriggerResult.Fail("http trigger value is not numeric");
        }
        catch (JsonException ex)
        {
            return TriggerResult.Fail($"http trigger response is neither a number nor valid JSON: {ex.Message}");
        }
    }

    private static bool TryParseValue(string? value, out double result) =>
        double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out result);

    private static int ReadTimeoutSeconds(ScaleConfig config) =>
        config.TriggerConfig.TryGetValue("timeoutSeconds", out var timeout) &&
        int.TryParse(timeout, NumberStyles.Integer, CultureInfo.InvariantCulture, out var seconds) &&
        seconds > 0
            ? Math.Min(seconds, 120)
            : 5;
}
