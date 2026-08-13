using System.Text;
internal static class Program
{
    static int Main(string[] args)
    {
        args = NormalizeArgs(args);
        // Docker CLI plugin handshake:
        // docker <name> invokes: docker-<name> docker-cli-plugin-metadata
        if (args.Length == 1 && args[0] == "docker-cli-plugin-metadata")
        {
            Console.WriteLine("""
        {
          "SchemaVersion": "0.1.0",
          "Vendor": "DEDA",
          "Version": "0.1.0",
          "ShortDescription": "DEDA autoscaler installer and tools for Docker Swarm"
        }
        """);
            return 0;
        }

        if (args.Length == 0 || args[0] is "--help" or "-h")
            return Help();

        var cmd = args[0].ToLowerInvariant();
        var rest = args.Skip(1).ToArray();

        try
        {
            return cmd switch
            {
                "install" => Commands.Install(rest),
                "status" => Commands.Status(rest),
                "validate" => Commands.Validate(rest),
                "upgrade" => Commands.Upgrade(rest),
                "uninstall" => Commands.Uninstall(rest),
                _ => Help($"Unknown command '{cmd}'")
            };
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"ERROR: {ex.GetType().Name}: {ex.Message}");
            return 1;
        }
    }

    static int Help(string? err = null)
    {
        if (!string.IsNullOrWhiteSpace(err))
            Console.Error.WriteLine(err);

        Console.WriteLine(@"
docker deda - Swarm autoscaler installer (CLI plugin)

Usage:
  docker deda install   [--image <img>] [--stack <name>] [--port <p>] [--poll <sec>] [--max-per-cycle <n>] [--jitter true|false]
  docker deda status    [--stack <name>]
  docker deda validate  [--stack <name>]
  docker deda upgrade   --image <img> [--stack <name>]
  docker deda uninstall [--stack <name>]

Examples:
  docker deda install --image ghcr.io/mikara89/deda:VERSION --stack deda --port 8080
  docker deda status
");
        return string.IsNullOrWhiteSpace(err) ? 0 : 1;
    }

    static string[] NormalizeArgs(string[] args)
    {
        // Docker may invoke plugin as: docker-deda.exe deda install ...
        // or with global flags before: docker --context X deda install ...
        var idx = Array.FindIndex(args, a => string.Equals(a, "deda", StringComparison.OrdinalIgnoreCase));
        if (idx >= 0)
            return args[(idx + 1)..];

        return args;
    }
    static class Commands
    {
        public static int Install(string[] args)
        {
            var o = CliArgs.Parse(args);

            var image = o.Get("--image", "deda:local");
            var stack = o.Get("--stack", "deda");
            var port = o.GetInt("--port", 8080);
            var poll = o.GetInt("--poll", 10);
            var maxPerCycle = o.GetInt("--max-per-cycle", 25);
            var jitter = o.GetBool("--jitter", true);
            var rabbitUserSecretName = o.Get("--rabbitmq-user-secret-name", "rabbitmq_user");
            var rabbitPassSecretName = o.Get("--rabbitmq-pass-secret-name", "rabbitmq_pass");

            DockerCli.RequireDocker();
            DockerCli.RequireSwarmActive();

            var yml = TemplateRender.Render(StackTemplate.Yaml, new Dictionary<string, string>
            {
                ["DEDA_IMAGE"] = image,
                ["DEDA_PUBLISHED_PORT"] = port.ToString(),
                ["DEDA_POLL_SECONDS"] = poll.ToString(),
                ["DEDA_MAX_SVC_PER_CYCLE"] = maxPerCycle.ToString(),
                ["DEDA_JITTER"] = jitter ? "true" : "false",
                ["RABBITMQ_USER_SECRET_NAME"] = rabbitUserSecretName ?? "rabbitmq_user",
                ["RABBITMQ_PASS_SECRET_NAME"] = rabbitPassSecretName ?? "rabbitmq_pass"
            });

            var tempFile = Path.Combine(Path.GetTempPath(), $"deda-stack-{Guid.NewGuid():N}.yml");
            File.WriteAllText(tempFile, yml, Encoding.UTF8);

            Console.WriteLine($"Deploying stack '{stack}' using image '{image}'...");
            DockerCli.Run($"stack deploy -c \"{tempFile}\" {stack}");

            Console.WriteLine("Done.");
            Console.WriteLine($"Try: docker deda status --stack {stack}");
            return 0;
        }

        public static int Upgrade(string[] args)
        {
            var o = CliArgs.Parse(args);
            var image = o.Get("--image", "");
            if (string.IsNullOrWhiteSpace(image))
                throw new ArgumentException("upgrade requires --image <img>");

            var stack = o.Get("--stack", "deda");
            // Reuse install logic, keep defaults unless user overrides
            return Install(
            [
                "--image", image,
                "--stack", stack,
                "--port", o.Get("--port", "8080"),
                "--poll", o.Get("--poll", "10"),
                "--max-per-cycle", o.Get("--max-per-cycle", "25"),
                "--jitter", o.Get("--jitter", "true"),
                "--rabbitmq-user-secret-name", o.Get("--rabbitmq-user-secret-name", "rabbitmq_user"),
                "--rabbitmq-pass-secret-name", o.Get("--rabbitmq-pass-secret-name", "rabbitmq_pass")
            ]);
        }

        public static int Uninstall(string[] args)
        {
            var o = CliArgs.Parse(args);
            var stack = o.Get("--stack", "deda");

            DockerCli.RequireDocker();

            Console.WriteLine($"Removing stack '{stack}'...");
            DockerCli.Run($"stack rm {stack}");
            Console.WriteLine("Done.");
            return 0;
        }

        public static int Status(string[] args)
        {
            var o = CliArgs.Parse(args);
            var stack = o.Get("--stack", "deda");

            DockerCli.RequireDocker();

            Console.WriteLine("Services:");
            DockerCli.Run($"stack services {stack}");

            Console.WriteLine();
            Console.WriteLine("Tasks:");
            DockerCli.Run($"service ps {stack}_deda --no-trunc");

            Console.WriteLine();
            Console.WriteLine("Recent logs:");
            DockerCli.Run($"service logs --tail 50 {stack}_deda");

            Console.WriteLine();
            Console.WriteLine("Tip: scrape metrics on published port (default 8080): /metrics, /health/ready");
            return 0;
        }

        public static int Validate(string[] args)
        {
            var o = CliArgs.Parse(args);
            var stack = o.Get("--stack", "deda");

            DockerCli.RequireDocker();
            DockerCli.RequireSwarmActive();

            // Basic checks: stack exists and service runs on manager
            ValidateChecks.CheckStackServiceExists(stack);
            ValidateChecks.CheckServiceOnManager(stack);

            Console.WriteLine("OK: basic validation passed.");
            Console.WriteLine("Next: validate your autoscale labels on target services.");
            return 0;
        }
    }

    sealed class CliArgs
    {
        private readonly Dictionary<string, string> _map;
        private CliArgs(Dictionary<string, string> map) => _map = map;

        public static CliArgs Parse(string[] args)
        {
            var map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            for (int i = 0; i < args.Length; i++)
            {
                var k = args[i];
                if (!k.StartsWith("--")) continue;
                var v = (i + 1 < args.Length && !args[i + 1].StartsWith("--")) ? args[++i] : "true";
                map[k] = v;
            }
            return new CliArgs(map);
        }

        public string Get(string key, string fallback) => _map.TryGetValue(key, out var v) ? v : fallback;

        public int GetInt(string key, int fallback)
            => int.TryParse(Get(key, ""), out var v) ? v : fallback;

        public bool GetBool(string key, bool fallback)
            => bool.TryParse(Get(key, ""), out var v) ? v : fallback;
    }
}

