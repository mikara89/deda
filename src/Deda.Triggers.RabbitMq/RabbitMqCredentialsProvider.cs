namespace Deda.Triggers.RabbitMq
{
    public sealed record RabbitMqCredentials(string Username, string Password);

    public interface IRabbitMqCredentialsProvider
    {
        RabbitMqCredentials Get();
    }

    /// <summary>
    /// Reads credentials from:
    /// - RABBITMQ_USER / RABBITMQ_PASS
    /// - or RABBITMQ_USER_FILE / RABBITMQ_PASS_FILE (Docker/Swarm secrets pattern)
    /// </summary>
    public sealed class EnvOrFileRabbitMqCredentialsProvider : IRabbitMqCredentialsProvider
    {
        public RabbitMqCredentials Get()
        {
            var user = ReadEnvOrFile("RABBITMQ_USER", "RABBITMQ_USER_FILE");
            var pass = ReadEnvOrFile("RABBITMQ_PASS", "RABBITMQ_PASS_FILE");

            if (string.IsNullOrWhiteSpace(user) || string.IsNullOrWhiteSpace(pass))
                throw new InvalidOperationException("RabbitMQ credentials not set (RABBITMQ_USER/PASS or *_FILE).");

            return new RabbitMqCredentials(user.Trim(), pass.Trim());
        }

        private static string? ReadEnvOrFile(string envVar, string fileEnvVar)
        {
            var direct = Environment.GetEnvironmentVariable(envVar);
            if (!string.IsNullOrWhiteSpace(direct))
                return direct;

            var file = Environment.GetEnvironmentVariable(fileEnvVar);
            if (!string.IsNullOrWhiteSpace(file) && File.Exists(file))
                return File.ReadAllText(file);

            return null;
        }
    }
}
