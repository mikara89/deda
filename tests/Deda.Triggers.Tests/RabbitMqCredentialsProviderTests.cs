using Deda.Core;
using Deda.Triggers.RabbitMq;

namespace Deda.Triggers.Tests;

public sealed class RabbitMqCredentialsProviderTests
{
    [Fact]
    public void PerServiceSecret_OverridesGlobalCredentialSource()
    {
        var resolver = new RecordingSecretResolver("tenant-user:tenant:password");
        var provider = new EnvOrFileRabbitMqCredentialsProvider(resolver);
        var config = new ScaleConfig
        {
            TriggerConfig = new Dictionary<string, string>
            {
                ["credentialsSecret"] = "tenant-a-rabbitmq",
            },
        };

        var credentials = provider.Get(Service(), config);

        Assert.Equal("tenant-a-rabbitmq", resolver.RequestedName);
        Assert.Equal("tenant-user", credentials.Username);
        Assert.Equal("tenant:password", credentials.Password);
    }

    [Fact]
    public void MalformedPerServiceSecret_IsRejectedWithoutLeakingContents()
    {
        var provider = new EnvOrFileRabbitMqCredentialsProvider(
            new RecordingSecretResolver("not-a-credential"));
        var config = new ScaleConfig
        {
            TriggerConfig = new Dictionary<string, string>
            {
                ["credentialsSecret"] = "tenant-a-rabbitmq",
            },
        };

        var error = Assert.Throws<InvalidOperationException>(() => provider.Get(Service(), config));

        Assert.Contains("username:password", error.Message);
        Assert.DoesNotContain("not-a-credential", error.Message);
    }

    [Fact]
    public void DockerSecretResolver_ReadsMountedSecretAndRejectsTraversal()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"deda-secrets-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        try
        {
            File.WriteAllText(Path.Combine(directory, "rabbitmq-a"), "alice:secret");
            var resolver = new DockerSecretFileResolver(directory);

            Assert.Equal("alice:secret", resolver.Resolve("rabbitmq-a"));
            Assert.Throws<InvalidOperationException>(() => resolver.Resolve("../rabbitmq-a"));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    private static ServiceRef Service() =>
        new("service-1", "worker", 1, new Dictionary<string, string>(), 1, SwarmServiceMode.Replicated);

    private sealed class RecordingSecretResolver : ISecretResolver
    {
        private readonly string _value;

        public RecordingSecretResolver(string value)
        {
            _value = value;
        }

        public string? RequestedName { get; private set; }

        public string Resolve(string secretName)
        {
            RequestedName = secretName;
            return _value;
        }
    }
}
