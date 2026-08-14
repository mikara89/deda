using Deda.Credentials;
using Deda.Core;
using Deda.Triggers.Ci;
using System.Net;

namespace Deda.Triggers.Tests;

public sealed class CiProviderHardeningTests
{
    [Fact]
    public void EmptyCredentialHostAllowlist_FailsClosed()
    {
        var policy = new CredentialPolicy(new Dictionary<string, CredentialBinding>
        {
            ["build"] = new("github", "token", new HashSet<string>(), new HashSet<string>()),
        });

        var error = Assert.Throws<InvalidOperationException>(() => policy.Resolve(Service(), "build", new Uri("https://api.github.com"), "github"));

        Assert.Contains("at least one allowed host", error.Message);
    }

    [Fact]
    public async Task GitHub_RequiresRunnerLabelsAndRejectsUnsupportedJobRequirement()
    {
        var adapter = GitHub(Factory(_ => StubHttpMessageHandler.Json("""{"workflow_runs":[]}""")));
        var missing = await adapter.GetWorkAsync(Service(), Config("github-actions", [("owner", "org"), ("repos", "app"), ("credentialsRef", "build")]), CancellationToken.None);
        Assert.False(missing.Success);
        Assert.Contains("trigger.labels", missing.Error);

        var guarded = GitHub(Factory(request => request.RequestUri!.PathAndQuery.Contains("/jobs")
            ? StubHttpMessageHandler.Json("""{"jobs":[{"status":"queued","labels":["self-hosted","linux","gpu"]}]}""")
            : StubHttpMessageHandler.Json("""{"workflow_runs":[{"id":1}]}""")));
        var result = await guarded.GetWorkAsync(Service(), GitHubConfig(), CancellationToken.None);
        Assert.True(result.Success, result.Error);
        Assert.Equal(0, result.Work);
    }

    [Fact]
    public async Task GitHub_RunnerLabelSupersetAndPagination_AreCounted()
    {
        var adapter = GitHub(Factory(request =>
        {
            var path = request.RequestUri!.PathAndQuery;
            if (path.Contains("status=in_progress")) return StubHttpMessageHandler.Json("""{"workflow_runs":[]}""");
            if (path.Contains("actions/runs?status=queued") && path.EndsWith("page=1", StringComparison.Ordinal)) return Json("""{"workflow_runs":[{"id":1}]}""", "Link", "<https://api.github.com/next>; rel=\"next\"");
            if (path.Contains("actions/runs?status=queued") && path.EndsWith("page=2", StringComparison.Ordinal)) return StubHttpMessageHandler.Json("""{"workflow_runs":[{"id":2}]}""");
            return StubHttpMessageHandler.Json("""{"jobs":[{"status":"queued","labels":["self-hosted","linux"]}]}""");
        }));

        var result = await adapter.GetWorkAsync(Service(), GitHubConfig(("labels", "self-hosted,linux,x64")), CancellationToken.None);

        Assert.True(result.Success, result.Error);
        Assert.Equal(2, result.Work);
    }

    [Fact]
    public async Task CachedObservation_DoesNotRepeatProviderRequests()
    {
        var requests = 0;
        var adapter = GitLab(Factory(_ => { requests++; return StubHttpMessageHandler.Json("[]"); }));
        var config = GitLabConfig();

        await adapter.GetWorkAsync(Service(), config, CancellationToken.None);
        await adapter.GetWorkAsync(Service(), config, CancellationToken.None);

        Assert.Equal(1, requests);
    }

    [Fact]
    public async Task ConcurrentEvaluations_ShareOneInFlightProviderObservation()
    {
        var requests = 0;
        var adapter = GitLab(Factory(async (_, ct) =>
        {
            Interlocked.Increment(ref requests);
            await Task.Delay(25, ct);
            return StubHttpMessageHandler.Json("[]");
        }));
        var config = GitLabConfig();

        await Task.WhenAll(
            adapter.GetWorkAsync(Service(), config, CancellationToken.None),
            adapter.GetWorkAsync(Service(), config, CancellationToken.None));

        Assert.Equal(1, requests);
    }

    [Fact]
    public async Task GitLab_UsesCaseSensitiveSubsetMatchingAndPaginates()
    {
        var adapter = GitLab(Factory(request => request.RequestUri!.Query.EndsWith("page=1", StringComparison.Ordinal)
            ? Json("""[{"status":"pending","tag_list":["docker"]}]""", "X-Next-Page", "2")
            : StubHttpMessageHandler.Json("""[{"status":"running","tag_list":["docker"]}]""")));
        var result = await adapter.GetWorkAsync(Service(), GitLabConfig(("tags", "docker,linux")), CancellationToken.None);
        Assert.True(result.Success);
        Assert.Equal(2, result.Work);

        var caseSensitive = GitLab(Factory(_ => StubHttpMessageHandler.Json("""[{"status":"pending","tag_list":["docker"]}]""")));
        var wrongCase = await caseSensitive.GetWorkAsync(Service(), GitLabConfig(("tags", "Docker")), CancellationToken.None);
        Assert.True(wrongCase.Success);
        Assert.Equal(0, wrongCase.Work);
    }

    [Fact]
    public async Task GitLab_UntaggedJobsRequireRunUntagged()
    {
        var noUntagged = GitLab(Factory(_ => StubHttpMessageHandler.Json("""[{"status":"pending","tag_list":[]}]""")));
        var denied = await noUntagged.GetWorkAsync(Service(), GitLabConfig(("runUntagged", "false")), CancellationToken.None);
        Assert.Equal(0, denied.Work);

        var allowed = GitLab(Factory(_ => StubHttpMessageHandler.Json("""[{"status":"pending","tag_list":[]}]""")));
        var accepted = await allowed.GetWorkAsync(Service(), GitLabConfig(("runUntagged", "true")), CancellationToken.None);
        Assert.Equal(1, accepted.Work);
    }

    [Theory]
    [InlineData("Agent.OS -equals Linux", "Agent.OS=Linux", 1)]
    [InlineData("Agent.OS -equals Windows", "Agent.OS=Linux", 0)]
    [InlineData("docker", "docker", 1)]
    public async Task AzurePipelines_MatchesExistsAndEqualsDemands(string demand, string capabilities, int expected)
    {
        var adapter = Azure(Factory(_ => StubHttpMessageHandler.Json($$"""{"value":[{"demands":["{{demand}}"],"assignTime":null,"finishTime":null}]}""")));
        var result = await adapter.GetWorkAsync(Service(), AzureConfig(("demands", capabilities)), CancellationToken.None);

        Assert.True(result.Success);
        Assert.Equal(expected, result.Work);
    }

    [Fact]
    public async Task ProviderHttpFailure_ReturnsFailedTriggerResult()
    {
        var adapter = GitLab(Factory(_ => StubHttpMessageHandler.Json("rate limited", HttpStatusCode.TooManyRequests)));
        var result = await adapter.GetWorkAsync(Service(), GitLabConfig(), CancellationToken.None);

        Assert.False(result.Success);
        Assert.Contains("429", result.Error);
    }

    [Fact]
    public async Task ProviderTimeout_ReturnsFailedTriggerResult()
    {
        var adapter = GitLab(Factory((_, _) => Task.FromException<HttpResponseMessage>(new TaskCanceledException("provider timeout"))));
        var result = await adapter.GetWorkAsync(Service(), GitLabConfig(), CancellationToken.None);

        Assert.False(result.Success);
        Assert.Contains("TaskCanceledException", result.Error);
    }

    private static GitHubActionsTriggerAdapter GitHub(IHttpClientFactory factory) => new(new GitHubActionsQueueProvider(factory, Tokens("github", "api.github.com")));
    private static GitLabCiTriggerAdapter GitLab(IHttpClientFactory factory) => new(new GitLabCiQueueProvider(factory, Tokens("gitlab", "gitlab.com")));
    private static AzurePipelinesTriggerAdapter Azure(IHttpClientFactory factory) => new(new AzurePipelinesQueueProvider(factory, Tokens("azure-devops", "dev.azure.com")));
    private static CredentialTokenProvider Tokens(string type, string host) => new(new TestSecretResolver(), new CredentialPolicy(new Dictionary<string, CredentialBinding> { ["build"] = new(type, "token", new HashSet<string>([host]), new HashSet<string>()) }));
    private static IHttpClientFactory Factory(Func<HttpRequestMessage, HttpResponseMessage> reply) => new SingleClientFactory(new HttpClient(new StubHttpMessageHandler((request, _) => Task.FromResult(reply(request)))));
    private static IHttpClientFactory Factory(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> reply) => new SingleClientFactory(new HttpClient(new StubHttpMessageHandler(reply)));
    private static HttpResponseMessage Json(string value, string header, string headerValue)
    {
        var response = StubHttpMessageHandler.Json(value);
        response.Headers.Add(header, headerValue);
        return response;
    }
    private static ServiceRef Service() => new("id", "runner", 0, new Dictionary<string, string>(), 0, SwarmServiceMode.Replicated);
    private static ScaleConfig Config(string type, (string Key, string Value)[] entries) => new() { TriggerType = type, TriggerConfig = entries.GroupBy(x => x.Key, StringComparer.OrdinalIgnoreCase).ToDictionary(group => group.Key, group => group.Last().Value, StringComparer.OrdinalIgnoreCase) };
    private static ScaleConfig GitHubConfig(params (string Key, string Value)[] overrides) => Config("github-actions", [("owner", "org"), ("repos", "app"), ("labels", "self-hosted,linux"), ("credentialsRef", "build"), .. overrides]);
    private static ScaleConfig GitLabConfig(params (string Key, string Value)[] overrides) => Config("gitlab-ci", [("projects", "group/project"), ("tags", "docker,linux"), ("credentialsRef", "build"), .. overrides]);
    private static ScaleConfig AzureConfig(params (string Key, string Value)[] overrides) => Config("azure-pipelines", [("organizationUrl", "https://dev.azure.com/example"), ("poolId", "12"), ("demands", "docker"), ("credentialsRef", "build"), .. overrides]);
    private sealed class TestSecretResolver : ISecretResolver { public string Resolve(string secretName) => "token"; }
}
