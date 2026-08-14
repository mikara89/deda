using Deda.Credentials;
using Deda.Core;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using static Deda.Triggers.Ci.CiProviderHelpers;

namespace Deda.Triggers.Ci;

public sealed class GitHubActionsTriggerAdapter(GitHubActionsQueueProvider provider, CiObservationCache? cache = null) : CiTriggerAdapter(provider, cache)
{
    public const string TriggerType = "github-actions";
}

public sealed class AzurePipelinesTriggerAdapter(AzurePipelinesQueueProvider provider, CiObservationCache? cache = null) : CiTriggerAdapter(provider, cache)
{
    public const string TriggerType = "azure-pipelines";
}

public sealed class GitLabCiTriggerAdapter(GitLabCiQueueProvider provider, CiObservationCache? cache = null) : CiTriggerAdapter(provider, cache)
{
    public const string TriggerType = "gitlab-ci";
}

public sealed class GitHubActionsQueueProvider(IHttpClientFactory clients, CredentialTokenProvider tokens) : ICiQueueProvider
{
    public string Type => GitHubActionsTriggerAdapter.TriggerType;

    public async Task<CiQueueSnapshot> GetQueueAsync(ServiceRef service, ScaleConfig config, CancellationToken ct)
    {
        var owner = Required(config, "owner");
        var repos = Values(Required(config, "repos"));
        var runnerLabels = Values(Required(config, "labels"));
        var api = Endpoint(config.TriggerConfig.GetValueOrDefault("apiUrl") ?? "https://api.github.com");
        var token = tokens.Get(service, config, api, "github");
        var queued = 0; var active = 0;

        foreach (var repo in repos)
        foreach (var status in new[] { "queued", "in_progress" })
        {
            for (var page = 1; ; page++)
            {
                var runsUri = new Uri(api, $"repos/{Uri.EscapeDataString(owner)}/{Uri.EscapeDataString(repo)}/actions/runs?status={status}&per_page=100&page={page}");
                using var response = await SendAsync(clients.CreateClient("github-actions"), GitHubRequest(runsUri, token), Type, ct).ConfigureAwait(false);
                await EnsureSuccess(response, Type, ct).ConfigureAwait(false);
                using var document = JsonDocument.Parse(await response.Content.ReadAsStreamAsync(ct).ConfigureAwait(false));
                if (!document.RootElement.TryGetProperty("workflow_runs", out var runs) || runs.ValueKind != JsonValueKind.Array)
                    throw new InvalidOperationException("GitHub response is missing workflow_runs.");
                foreach (var run in runs.EnumerateArray())
                {
                    if (run.TryGetProperty("id", out var id) && id.TryGetInt64(out var runId))
                        (queued, active) = await CountJobsAsync(api, owner, repo, runId, token, runnerLabels, queued, active, ct).ConfigureAwait(false);
                }
                if (!HasNextPage(response, runs.GetArrayLength(), "Link")) break;
            }
        }
        return new(queued, active, DateTimeOffset.UtcNow);
    }

    private async Task<(int Queued, int Active)> CountJobsAsync(Uri api, string owner, string repo, long runId, string token, IReadOnlySet<string> runnerLabels, int queued, int active, CancellationToken ct)
    {
        for (var page = 1; ; page++)
        {
            var uri = new Uri(api, $"repos/{Uri.EscapeDataString(owner)}/{Uri.EscapeDataString(repo)}/actions/runs/{runId}/jobs?per_page=100&page={page}");
            using var response = await SendAsync(clients.CreateClient("github-actions"), GitHubRequest(uri, token), Type, ct).ConfigureAwait(false);
            await EnsureSuccess(response, Type, ct).ConfigureAwait(false);
            using var document = JsonDocument.Parse(await response.Content.ReadAsStreamAsync(ct).ConfigureAwait(false));
            if (!document.RootElement.TryGetProperty("jobs", out var jobs) || jobs.ValueKind != JsonValueKind.Array)
                throw new InvalidOperationException("GitHub jobs response is missing jobs.");
            foreach (var job in jobs.EnumerateArray())
            {
                var jobStatus = String(job, "status");
                if (jobStatus is not ("queued" or "in_progress") || !JobRequirementsMatch(job, "labels", runnerLabels, StringComparer.OrdinalIgnoreCase, false)) continue;
                if (jobStatus == "queued") queued++; else active++;
            }
            if (!HasNextPage(response, jobs.GetArrayLength(), "Link")) break;
        }
        return (queued, active);
    }

    private static HttpRequestMessage GitHubRequest(Uri uri, string token)
    {
        var request = new HttpRequestMessage(HttpMethod.Get, uri);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Headers.UserAgent.ParseAdd("deda-ci-autoscaler");
        request.Headers.Accept.ParseAdd("application/vnd.github+json");
        request.Headers.Add("X-GitHub-Api-Version", "2022-11-28");
        return request;
    }
}

public sealed class GitLabCiQueueProvider(IHttpClientFactory clients, CredentialTokenProvider tokens) : ICiQueueProvider
{
    public string Type => GitLabCiTriggerAdapter.TriggerType;
    public async Task<CiQueueSnapshot> GetQueueAsync(ServiceRef service, ScaleConfig config, CancellationToken ct)
    {
        var api = Endpoint(config.TriggerConfig.GetValueOrDefault("url") ?? "https://gitlab.com");
        var token = tokens.Get(service, config, api, "gitlab");
        var runnerTags = Values(config.TriggerConfig.GetValueOrDefault("tags"), StringComparer.Ordinal);
        var runUntagged = bool.TryParse(config.TriggerConfig.GetValueOrDefault("runUntagged"), out var allowed) && allowed;
        var queued = 0; var active = 0;
        foreach (var project in Values(Required(config, "projects"), StringComparer.Ordinal))
        {
            for (var page = 1; ; page++)
            {
                var path = $"api/v4/projects/{Uri.EscapeDataString(project)}/jobs?scope[]=pending&scope[]=running&per_page=100&page={page}";
                using var request = new HttpRequestMessage(HttpMethod.Get, new Uri(api, path));
                request.Headers.Add("PRIVATE-TOKEN", token);
                using var response = await SendAsync(clients.CreateClient("gitlab-ci"), request, Type, ct).ConfigureAwait(false);
                await EnsureSuccess(response, Type, ct).ConfigureAwait(false);
                using var document = JsonDocument.Parse(await response.Content.ReadAsStreamAsync(ct).ConfigureAwait(false));
                if (document.RootElement.ValueKind != JsonValueKind.Array) throw new InvalidOperationException("GitLab jobs response is not an array.");
                foreach (var job in document.RootElement.EnumerateArray())
                {
                    if (!JobRequirementsMatch(job, "tag_list", runnerTags, StringComparer.Ordinal, runUntagged)) continue;
                    if (String(job, "status") == "pending") queued++;
                    else if (String(job, "status") == "running") active++;
                }
                if (!HasNextPage(response, document.RootElement.GetArrayLength(), "X-Next-Page")) break;
            }
        }
        return new(queued, active, DateTimeOffset.UtcNow);
    }
}

public sealed class AzurePipelinesQueueProvider(IHttpClientFactory clients, CredentialTokenProvider tokens) : ICiQueueProvider
{
    public string Type => AzurePipelinesTriggerAdapter.TriggerType;
    public async Task<CiQueueSnapshot> GetQueueAsync(ServiceRef service, ScaleConfig config, CancellationToken ct)
    {
        var organization = Endpoint(Required(config, "organizationUrl"));
        var token = tokens.Get(service, config, organization, "azure-devops");
        var poolId = await ResolvePoolId(organization, token, config, ct).ConfigureAwait(false);
        using var request = AzureRequest(new Uri(organization, $"_apis/distributedtask/pools/{poolId}/jobrequests?api-version=7.1"), token);
        using var response = await SendAsync(clients.CreateClient("azure-pipelines"), request, Type, ct).ConfigureAwait(false);
        await EnsureSuccess(response, Type, ct).ConfigureAwait(false);
        using var document = JsonDocument.Parse(await response.Content.ReadAsStreamAsync(ct).ConfigureAwait(false));
        if (!document.RootElement.TryGetProperty("value", out var jobs) || jobs.ValueKind != JsonValueKind.Array) throw new InvalidOperationException("Azure Pipelines job requests response is missing value.");
        var capabilities = AzureCapabilities(config.TriggerConfig.GetValueOrDefault("demands"));
        var queued = 0; var active = 0;
        foreach (var job in jobs.EnumerateArray())
        {
            if (job.TryGetProperty("finishTime", out var finish) && finish.ValueKind != JsonValueKind.Null) continue;
            if (!AzureDemandsMatch(job, capabilities)) continue;
            if (!job.TryGetProperty("assignTime", out var assigned) || assigned.ValueKind == JsonValueKind.Null) queued++; else active++;
        }
        return new(queued, active, DateTimeOffset.UtcNow);
    }

    private async Task<int> ResolvePoolId(Uri organization, string token, ScaleConfig config, CancellationToken ct)
    {
        if (int.TryParse(config.TriggerConfig.GetValueOrDefault("poolId"), out var id) && id > 0) return id;
        var name = Required(config, "poolName");
        using var request = AzureRequest(new Uri(organization, $"_apis/distributedtask/pools?poolName={Uri.EscapeDataString(name)}&api-version=7.1"), token);
        using var response = await SendAsync(clients.CreateClient("azure-pipelines"), request, Type, ct).ConfigureAwait(false);
        await EnsureSuccess(response, Type, ct).ConfigureAwait(false);
        using var document = JsonDocument.Parse(await response.Content.ReadAsStreamAsync(ct).ConfigureAwait(false));
        if (!document.RootElement.TryGetProperty("value", out var pools) || pools.ValueKind != JsonValueKind.Array || pools.GetArrayLength() != 1 || !pools[0].TryGetProperty("id", out var pool) || !pool.TryGetInt32(out id))
            throw new InvalidOperationException($"Azure Pipelines pool '{name}' was not found.");
        return id;
    }

    private static HttpRequestMessage AzureRequest(Uri uri, string token)
    {
        var request = new HttpRequestMessage(HttpMethod.Get, uri);
        request.Headers.Authorization = new AuthenticationHeaderValue("Basic", Convert.ToBase64String(Encoding.UTF8.GetBytes($":{token}")));
        return request;
    }
}

file static class CiProviderHelpers
{
    public static string Required(ScaleConfig config, string key) => config.TriggerConfig.TryGetValue(key, out var value) && !string.IsNullOrWhiteSpace(value) ? value.Trim() : throw new InvalidOperationException($"{config.TriggerType} trigger requires trigger.{key}.");
    public static Uri Endpoint(string value) => Uri.TryCreate(value.TrimEnd('/') + "/", UriKind.Absolute, out var uri) && (uri.Scheme == Uri.UriSchemeHttp || uri.Scheme == Uri.UriSchemeHttps) ? uri : throw new InvalidOperationException("CI provider URL must be absolute HTTP or HTTPS.");
    public static IReadOnlySet<string> Values(string? value, StringComparer? comparer = null) => string.IsNullOrWhiteSpace(value) ? new HashSet<string>(comparer ?? StringComparer.OrdinalIgnoreCase) : new HashSet<string>(value.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries), comparer ?? StringComparer.OrdinalIgnoreCase);
    public static string? String(JsonElement value, string property) => value.TryGetProperty(property, out var node) && node.ValueKind == JsonValueKind.String ? node.GetString() : null;
    public static bool JobRequirementsMatch(JsonElement job, string property, IReadOnlySet<string> runnerCapabilities, StringComparer comparer, bool runUntagged)
    {
        if (!job.TryGetProperty(property, out var requirements) || requirements.ValueKind != JsonValueKind.Array) return runUntagged;
        var required = new HashSet<string>(requirements.EnumerateArray().Where(x => x.ValueKind == JsonValueKind.String).Select(x => x.GetString()!), comparer);
        return required.Count == 0 ? runUntagged : required.All(runnerCapabilities.Contains);
    }
    public static Dictionary<string, string?> AzureCapabilities(string? raw)
    {
        var capabilities = new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase);
        foreach (var token in Values(raw))
        {
            var separator = token.IndexOf('=');
            capabilities[separator < 0 ? token : token[..separator].Trim()] = separator < 0 ? null : token[(separator + 1)..].Trim();
        }
        return capabilities;
    }
    public static bool AzureDemandsMatch(JsonElement job, IReadOnlyDictionary<string, string?> capabilities)
    {
        if (!job.TryGetProperty("demands", out var demands) || demands.ValueKind != JsonValueKind.Array) return true;
        foreach (var demandElement in demands.EnumerateArray())
        {
            var demand = AzureDemand.Parse(demandElement);
            if (demand is null || !capabilities.TryGetValue(demand.Name, out var capability)) return false;
            if (demand.Value is not null && !string.Equals(capability, demand.Value, StringComparison.OrdinalIgnoreCase)) return false;
        }
        return true;
    }
    public static async Task<HttpResponseMessage> SendAsync(HttpClient client, HttpRequestMessage request, string provider, CancellationToken ct)
    {
        CiDiagnostics.RecordApiRequest(provider);
        return await client.SendAsync(request, ct).ConfigureAwait(false);
    }
    public static bool HasNextPage(HttpResponseMessage response, int itemCount, string header)
    {
        if (string.Equals(header, "X-Next-Page", StringComparison.OrdinalIgnoreCase))
            return response.Headers.TryGetValues(header, out var values) && values.Any(value => !string.IsNullOrWhiteSpace(value) && value != "0");
        return response.Headers.TryGetValues(header, out var links)
            ? links.Any(link => link.Contains("rel=\"next\"", StringComparison.OrdinalIgnoreCase))
            : itemCount == 100;
    }
    public static async Task EnsureSuccess(HttpResponseMessage response, string provider, CancellationToken ct)
    {
        if (response.IsSuccessStatusCode) return;
        var body = await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        throw new InvalidOperationException($"{provider} API returned {(int)response.StatusCode}: {(body.Length <= 200 ? body : body[..200])}");
    }

    private sealed record AzureDemand(string Name, string? Value)
    {
        public static AzureDemand? Parse(JsonElement element)
        {
            var text = element.ValueKind == JsonValueKind.String ? element.GetString() : String(element, "name");
            if (string.IsNullOrWhiteSpace(text)) return null;
            const string equals = " -equals ";
            var index = text.IndexOf(equals, StringComparison.OrdinalIgnoreCase);
            if (index >= 0) return new(text[..index].Trim(), text[(index + equals.Length)..].Trim());
            if (element.ValueKind == JsonValueKind.Object && String(element, "value") is { Length: > 0 } value) return new(text.Trim(), value);
            return new(text.Trim(), null);
        }
    }
}
