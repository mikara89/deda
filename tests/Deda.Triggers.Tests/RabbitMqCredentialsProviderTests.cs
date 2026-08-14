using Deda.Core;
using Deda.Credentials;
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

    [Fact]
    public void CredentialReference_RequiresBoundServiceAndAllowedHost()
    {
        var policy = new CredentialPolicy(new Dictionary<string, CredentialBinding>
        {
            ["orders"] = new("rabbitmq", "orders-rabbitmq", new HashSet<string>(["rabbitmq.internal"]), new HashSet<string>(["worker"])),
        });
        var provider = new EnvOrFileRabbitMqCredentialsProvider(new RecordingSecretResolver("alice:secret"), policy, false);
        var config = new ScaleConfig { TriggerConfig = new Dictionary<string, string> { ["credentialsRef"] = "orders", ["url"] = "http://rabbitmq.internal:15672" } };

        Assert.Equal("alice", provider.Get(Service(), config).Username);
        config = config with { TriggerConfig = new Dictionary<string, string> { ["credentialsRef"] = "orders", ["url"] = "http://attacker.example:15672" } };
        Assert.Throws<InvalidOperationException>(() => provider.Get(Service(), config));
    }

    [Fact]
    public void CredentialPolicyFile_ParsesOperatorBindings()
    {
        var path = Path.Combine(Path.GetTempPath(), $"deda-policy-{Guid.NewGuid():N}.json");
        try
        {
            File.WriteAllText(path, """{"orders":{"secret":"orders-rabbitmq","allowedHosts":["rabbitmq.internal"],"allowedServices":["worker"]}}""");
            var policy = CredentialPolicy.FromJsonFile(path);
            var binding = policy.Resolve(Service(), "orders", new Uri("http://rabbitmq.internal:15672"));

            Assert.Equal("orders-rabbitmq", binding.Secret);
            Assert.Contains("rabbitmq.internal", binding.AllowedHosts);
        }
        finally
        {
            File.Delete(path);
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
