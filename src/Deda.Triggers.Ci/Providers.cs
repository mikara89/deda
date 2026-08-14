using Deda.Credentials;
using Deda.Core;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using static Deda.Triggers.Ci.CiProviderHelpers;

namespace Deda.Triggers.Ci;

public sealed class GitHubActionsTriggerAdapter(GitHubActionsQueueProvider provider) : CiTriggerAdapter(provider)
{
    public const string TriggerType = "github-actions";
}

public sealed class AzurePipelinesTriggerAdapter(AzurePipelinesQueueProvider provider) : CiTriggerAdapter(provider)
{
    public const string TriggerType = "azure-pipelines";
}

public sealed class GitLabCiTriggerAdapter(GitLabCiQueueProvider provider) : CiTriggerAdapter(provider)
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
        var labels = Values(config.TriggerConfig.GetValueOrDefault("labels"));
        var api = Endpoint(config.TriggerConfig.GetValueOrDefault("apiUrl") ?? "https://api.github.com");
        var token = tokens.Get(service, config, api, "github");
        var queued = 0; var active = 0;
        foreach (var repo in repos)
        {
            foreach (var status in new[] { "queued", "in_progress" })
            {
                using var request = Request(HttpMethod.Get, new Uri(api, $"repos/{owner}/{repo}/actions/runs?status={status}&per_page=100"), token, "github");
                using var response = await clients.CreateClient("github-actions").SendAsync(request, ct).ConfigureAwait(false);
                await EnsureSuccess(response, Type, ct).ConfigureAwait(false);
                using var document = JsonDocument.Parse(await response.Content.ReadAsStreamAsync(ct).ConfigureAwait(false));
                if (!document.RootElement.TryGetProperty("workflow_runs", out var runs) || runs.ValueKind != JsonValueKind.Array)
                    throw new InvalidOperationException("GitHub response is missing workflow_runs.");
                foreach (var run in runs.EnumerateArray())
                {
                    if (!run.TryGetProperty("id", out var id) || !id.TryGetInt64(out var runId)) continue;
                    using var jobRequest = Request(HttpMethod.Get, new Uri(api, $"repos/{owner}/{repo}/actions/runs/{runId}/jobs?per_page=100"), token, "github");
                    using var jobResponse = await clients.CreateClient("github-actions").SendAsync(jobRequest, ct).ConfigureAwait(false);
                    await EnsureSuccess(jobResponse, Type, ct).ConfigureAwait(false);
                    using var jobsDocument = JsonDocument.Parse(await jobResponse.Content.ReadAsStreamAsync(ct).ConfigureAwait(false));
                    if (!jobsDocument.RootElement.TryGetProperty("jobs", out var jobs) || jobs.ValueKind != JsonValueKind.Array)
                        throw new InvalidOperationException("GitHub jobs response is missing jobs.");
                    foreach (var job in jobs.EnumerateArray())
                    {
                        var jobStatus = String(job, "status");
                        if (jobStatus is not ("queued" or "in_progress") || !MatchesAll(job, "labels", labels)) continue;
                        if (jobStatus == "queued") queued++; else active++;
                    }
                }
            }
        }
        return new(queued, active, DateTimeOffset.UtcNow);
    }

    private static HttpRequestMessage Request(HttpMethod method, Uri uri, string token, string _) {
        var request = new HttpRequestMessage(method, uri);
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
        var tags = Values(config.TriggerConfig.GetValueOrDefault("tags"));
        var runUntagged = bool.TryParse(config.TriggerConfig.GetValueOrDefault("runUntagged"), out var allowed) && allowed;
        var queued = 0; var active = 0;
        foreach (var project in Values(Required(config, "projects")))
        {
            var path = $"api/v4/projects/{Uri.EscapeDataString(project)}/jobs?scope[]=pending&scope[]=running&per_page=100";
            using var request = new HttpRequestMessage(HttpMethod.Get, new Uri(api, path));
            request.Headers.Add("PRIVATE-TOKEN", token);
            using var response = await clients.CreateClient("gitlab-ci").SendAsync(request, ct).ConfigureAwait(false);
            await EnsureSuccess(response, Type, ct).ConfigureAwait(false);
            using var document = JsonDocument.Parse(await response.Content.ReadAsStreamAsync(ct).ConfigureAwait(false));
            if (document.RootElement.ValueKind != JsonValueKind.Array) throw new InvalidOperationException("GitLab jobs response is not an array.");
            foreach (var job in document.RootElement.EnumerateArray())
            {
                if (!MatchesAll(job, "tag_list", tags, runUntagged)) continue;
                if (String(job, "status") == "pending") queued++;
                else if (String(job, "status") == "running") active++;
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
        using var request = new HttpRequestMessage(HttpMethod.Get, new Uri(organization, $"_apis/distributedtask/pools/{poolId}/jobrequests?api-version=7.1"));
        request.Headers.Authorization = new AuthenticationHeaderValue("Basic", Convert.ToBase64String(Encoding.UTF8.GetBytes($":{token}")));
        using var response = await clients.CreateClient("azure-pipelines").SendAsync(request, ct).ConfigureAwait(false);
        await EnsureSuccess(response, Type, ct).ConfigureAwait(false);
        using var document = JsonDocument.Parse(await response.Content.ReadAsStreamAsync(ct).ConfigureAwait(false));
        if (!document.RootElement.TryGetProperty("value", out var jobs) || jobs.ValueKind != JsonValueKind.Array) throw new InvalidOperationException("Azure Pipelines job requests response is missing value.");
        var capabilities = Values(config.TriggerConfig.GetValueOrDefault("demands"));
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
        using var request = new HttpRequestMessage(HttpMethod.Get, new Uri(organization, $"_apis/distributedtask/pools?poolName={Uri.EscapeDataString(name)}&api-version=7.1"));
        request.Headers.Authorization = new AuthenticationHeaderValue("Basic", Convert.ToBase64String(Encoding.UTF8.GetBytes($":{token}")));
        using var response = await clients.CreateClient("azure-pipelines").SendAsync(request, ct).ConfigureAwait(false);
        await EnsureSuccess(response, Type, ct).ConfigureAwait(false);
        using var document = JsonDocument.Parse(await response.Content.ReadAsStreamAsync(ct).ConfigureAwait(false));
        if (!document.RootElement.TryGetProperty("value", out var pools) || pools.ValueKind != JsonValueKind.Array || pools.GetArrayLength() != 1 || !pools[0].TryGetProperty("id", out var pool) || !pool.TryGetInt32(out id))
            throw new InvalidOperationException($"Azure Pipelines pool '{name}' was not found.");
        return id;
    }
}

file static class CiProviderHelpers
{
    public static string Required(ScaleConfig config, string key) => config.TriggerConfig.TryGetValue(key, out var value) && !string.IsNullOrWhiteSpace(value) ? value.Trim() : throw new InvalidOperationException($"{config.TriggerType} trigger requires trigger.{key}.");
    public static Uri Endpoint(string value) => Uri.TryCreate(value.TrimEnd('/') + "/", UriKind.Absolute, out var uri) && (uri.Scheme == Uri.UriSchemeHttp || uri.Scheme == Uri.UriSchemeHttps) ? uri : throw new InvalidOperationException("CI provider URL must be absolute HTTP or HTTPS.");
    public static IReadOnlySet<string> Values(string? value) => string.IsNullOrWhiteSpace(value) ? new HashSet<string>(StringComparer.OrdinalIgnoreCase) : new HashSet<string>(value.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries), StringComparer.OrdinalIgnoreCase);
    public static string? String(JsonElement value, string property) => value.TryGetProperty(property, out var node) && node.ValueKind == JsonValueKind.String ? node.GetString() : null;
    public static bool MatchesAll(JsonElement item, string property, IReadOnlySet<string> required, bool allowUntagged = false)
    {
        if (required.Count == 0) return true;
        if (!item.TryGetProperty(property, out var labels) || labels.ValueKind != JsonValueKind.Array) return allowUntagged;
        var actual = new HashSet<string>(labels.EnumerateArray().Where(x => x.ValueKind == JsonValueKind.String).Select(x => x.GetString()!), StringComparer.OrdinalIgnoreCase);
        if (actual.Count == 0) return allowUntagged;
        return required.All(actual.Contains);
    }
    public static bool AzureDemandsMatch(JsonElement job, IReadOnlySet<string> capabilities)
    {
        if (capabilities.Count == 0) return true;
        if (!job.TryGetProperty("demands", out var demands) || demands.ValueKind != JsonValueKind.Array) return true;
        foreach (var demand in demands.EnumerateArray())
        {
            var name = demand.ValueKind == JsonValueKind.String ? demand.GetString() : String(demand, "name");
            if (!string.IsNullOrWhiteSpace(name) && !capabilities.Contains(name)) return false;
        }
        return true;
    }
    public static async Task EnsureSuccess(HttpResponseMessage response, string provider, CancellationToken ct)
    {
        if (response.IsSuccessStatusCode) return;
        var body = await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        throw new InvalidOperationException($"{provider} API returned {(int)response.StatusCode}: {(body.Length <= 200 ? body : body[..200])}");
    }
}
