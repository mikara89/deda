using Deda.Credentials;
using Deda.Core;
using Deda.Triggers.Ci;
using System.Net;

namespace Deda.Triggers.Tests;

public sealed class CiTriggerAdapterTests
{
    [Fact]
    public async Task GitLab_CountsPendingAndRunningJobsThatMatchRunnerTags()
    {
        var adapter = new GitLabCiTriggerAdapter(new GitLabCiQueueProvider(Factory(_ => StubHttpMessageHandler.Json("""[{"status":"pending","tag_list":["docker","linux"]},{"status":"running","tag_list":["docker","linux"]},{"status":"pending","tag_list":["gpu"]}]""")), Tokens("gitlab", "gitlab.com")));
        var result = await adapter.GetWorkAsync(Service(), Config("gitlab-ci", [
            ("url", "https://gitlab.com"), ("projects", "group/project"), ("tags", "docker,linux"), ("credentialsRef", "build")]), CancellationToken.None);

        Assert.True(result.Success);
        Assert.Equal(2, result.Work);
    }

    [Fact]
    public async Task AzurePipelines_KeepsActiveJobsInRequiredCapacity()
    {
        var adapter = new AzurePipelinesTriggerAdapter(new AzurePipelinesQueueProvider(Factory(_ => StubHttpMessageHandler.Json("""{"value":[{"demands":["docker"],"assignTime":null,"finishTime":null},{"demands":["docker"],"assignTime":"2026-01-01T00:00:00Z","finishTime":null},{"demands":["gpu"],"assignTime":null,"finishTime":null}]}""")), Tokens("azure-devops", "dev.azure.com")));
        var result = await adapter.GetWorkAsync(Service(), Config("azure-pipelines", [
            ("organizationUrl", "https://dev.azure.com/example"), ("poolId", "12"), ("demands", "docker"), ("credentialsRef", "build")]), CancellationToken.None);

        Assert.True(result.Success);
        Assert.Equal(2, result.Work);
    }

    [Fact]
    public async Task GitHubActions_CountsMatchingQueuedAndInProgressJobs()
    {
        var adapter = new GitHubActionsTriggerAdapter(new GitHubActionsQueueProvider(Factory(request =>
        {
            var path = request.RequestUri!.PathAndQuery;
            if (path.Contains("status=queued")) return StubHttpMessageHandler.Json("""{"workflow_runs":[{"id":1}]}""");
            if (path.Contains("status=in_progress")) return StubHttpMessageHandler.Json("""{"workflow_runs":[{"id":2}]}""");
            if (path.Contains("/1/jobs")) return StubHttpMessageHandler.Json("""{"jobs":[{"status":"queued","labels":["self-hosted","linux"]}]}""");
            return StubHttpMessageHandler.Json("""{"jobs":[{"status":"in_progress","labels":["self-hosted","linux"]},{"status":"queued","labels":["windows"]}]}""");
        }), Tokens("github", "api.github.com")));
        var result = await adapter.GetWorkAsync(Service(), Config("github-actions", [
            ("owner", "example"), ("repos", "app"), ("labels", "self-hosted,linux"), ("credentialsRef", "build")]), CancellationToken.None);

        Assert.True(result.Success);
        Assert.Equal(2, result.Work);
    }

    [Fact]
    public async Task CredentialTypeMismatch_FailsClosed()
    {
        var adapter = new GitLabCiTriggerAdapter(new GitLabCiQueueProvider(Factory(_ => StubHttpMessageHandler.Json("[]")), Tokens("github", "gitlab.com")));
        var result = await adapter.GetWorkAsync(Service(), Config("gitlab-ci", [("projects", "group/project"), ("credentialsRef", "build")]), CancellationToken.None);

        Assert.False(result.Success);
        Assert.Contains("not a 'gitlab' credential", result.Error);
    }

    private static IHttpClientFactory Factory(Func<HttpRequestMessage, HttpResponseMessage> reply) => new SingleClientFactory(new HttpClient(new StubHttpMessageHandler((request, _) => Task.FromResult(reply(request)))));
    private static CredentialTokenProvider Tokens(string type, string host) => new(new TestSecretResolver(), new CredentialPolicy(new Dictionary<string, CredentialBinding> { ["build"] = new(type, "token", new HashSet<string>([host]), new HashSet<string>()) }));
    private static ServiceRef Service() => new("id", "runner", 0, new Dictionary<string, string>(), 0, SwarmServiceMode.Replicated);
    private static ScaleConfig Config(string type, (string Key, string Value)[] entries) => new() { TriggerType = type, TriggerConfig = entries.ToDictionary(x => x.Key, x => x.Value) };
    private sealed class TestSecretResolver : ISecretResolver { public string Resolve(string secretName) => "secret-token"; }
}
