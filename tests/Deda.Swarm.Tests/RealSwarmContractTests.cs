using Deda.Core;
using Deda.Swarm;

namespace Deda.Swarm.Tests;

public sealed class RealSwarmContractTests
{
    [Fact]
    public async Task RealManager_DiscoversLabelsModesAndUpdatesReplicas()
    {
        if (!string.Equals(
            Environment.GetEnvironmentVariable("DEDA_SWARM_TESTS"),
            "1",
            StringComparison.Ordinal))
        {
            return;
        }

        var replicatedName = RequiredEnvironment("DEDA_SWARM_REPLICATED_SERVICE");
        var globalName = RequiredEnvironment("DEDA_SWARM_GLOBAL_SERVICE");
        using var http = DockerEndpoint.CreateHttpClientFromEnvironment();
        using var swarm = new DockerEngineSwarmServiceClient(http);

        var services = await swarm.ListServicesAsync(CancellationToken.None);
        var replicated = Assert.Single(services, service => service.Name == replicatedName);
        var global = Assert.Single(services, service => service.Name == globalName);

        Assert.Equal(SwarmServiceMode.Replicated, replicated.Mode);
        Assert.Equal(1, replicated.CurrentReplicas);
        Assert.Equal("contract", replicated.Labels["com.deda.test"]);
        Assert.Equal(SwarmServiceMode.Global, global.Mode);

        try
        {
            await swarm.UpdateReplicasAsync(
                replicated.ServiceId,
                replicated.VersionIndex,
                2,
                CancellationToken.None);

            var updated = await swarm.GetServiceAsync(replicated.ServiceId, CancellationToken.None);
            Assert.Equal(2, updated.CurrentReplicas);
        }
        finally
        {
            var latest = await swarm.GetServiceAsync(replicated.ServiceId, CancellationToken.None);
            await swarm.UpdateReplicasAsync(
                latest.ServiceId,
                latest.VersionIndex,
                1,
                CancellationToken.None);
        }

        await Assert.ThrowsAsync<NotSupportedException>(() =>
            swarm.UpdateReplicasAsync(global.ServiceId, global.VersionIndex, 2, CancellationToken.None));
    }

    private static string RequiredEnvironment(string name) =>
        Environment.GetEnvironmentVariable(name) ??
        throw new InvalidOperationException($"Required integration-test environment variable '{name}' is missing.");
}
