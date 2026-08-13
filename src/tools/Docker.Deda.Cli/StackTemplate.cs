static class StackTemplate
{
    public static string ForDockerAccess(string access)
    {
        if (string.Equals(access, "proxy", StringComparison.OrdinalIgnoreCase)) return Yaml;
        if (!string.Equals(access, "direct", StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException("--docker-access must be 'proxy' or 'direct'.");

        var proxyStart = Yaml.IndexOf("  docker-proxy:", StringComparison.Ordinal);
        var dedaStart = Yaml.IndexOf("  deda:", StringComparison.Ordinal);
        var direct = Yaml.Remove(proxyStart, dedaStart - proxyStart);
        return direct.Replace(
            "    secrets:\n      - rabbitmq_user\n      - rabbitmq_pass",
            "    user: \"0:0\" # deterministic socket access; see direct-mode documentation\n    volumes:\n      - /var/run/docker.sock:/var/run/docker.sock\n    secrets:\n      - rabbitmq_user\n      - rabbitmq_pass")
            .Replace("DOCKER_HOST: \"http://docker-proxy:2375\"", "DOCKER_HOST: \"unix:///var/run/docker.sock\"");
    }

    public const string Yaml = @"
version: ""3.8""

networks:
  deda_net:
    driver: overlay
    attachable: false

secrets:
  rabbitmq_user:
    external: true
    name: ""${RABBITMQ_USER_SECRET_NAME}""
  rabbitmq_pass:
    external: true
    name: ""${RABBITMQ_PASS_SECRET_NAME}""

services:
  docker-proxy:
    image: tecnativa/docker-socket-proxy@sha256:1f5038b54f06c3e18422902cf00ba21803d1c97805aae032e5e6673d532d3459
    networks: [deda_net]
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      # Allow only what you need (principle of least privilege)
      SERVICES: ""1""
      TASKS: ""1""
      NODES: ""1""
      SWARM: ""1""
      VERSION: ""1""
      POST: ""1""

      # Optional hardening:
      # BLOCK: ""1""          # block everything not explicitly enabled (supported in newer images)
      # LOG_LEVEL: ""info""
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.role == manager
      restart_policy:
        condition: on-failure
        delay: 5s
        max_attempts: 10
  deda:
    image: ${DEDA_IMAGE}
    networks: [deda_net]
    secrets:
      - rabbitmq_user
      - rabbitmq_pass
    environment:
      DEDA_POLL_SECONDS: ""${DEDA_POLL_SECONDS}""
      DEDA_HTTP_PORT: ""8080""
      DEDA_MAX_SERVICES_PER_CYCLE: ""${DEDA_MAX_SVC_PER_CYCLE}""
      DEDA_JITTER_ENABLED: ""${DEDA_JITTER}""
      DOCKER_HOST: ""http://docker-proxy:2375""
      RABBITMQ_USER_FILE: ""/run/secrets/rabbitmq_user""
      RABBITMQ_PASS_FILE: ""/run/secrets/rabbitmq_pass""
    ports:
      - target: 8080
        published: ${DEDA_PUBLISHED_PORT}
        protocol: tcp
        mode: ingress
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.role == manager
      restart_policy:
        condition: on-failure
        delay: 5s
        max_attempts: 10
      resources:
        limits:
          cpus: ""0.25""
          memory: 256M
        reservations:
          cpus: ""0.05""
          memory: 64M
";
}
