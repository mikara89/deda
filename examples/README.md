# DEDA examples

These Docker Swarm examples progress from installation to individual features
and an end-to-end topology. Each directory contains prerequisites, deployment,
expected behavior, verification, cleanup, and links to canonical documentation.

| Example | Demonstrates | Published ports |
| --- | --- | --- |
| [Minimal](minimal/README.md) | DEDA plus private Docker socket proxy | DEDA 8080 |
| [RabbitMQ trigger](rabbitmq-trigger/README.md) | Queue-depth scaling with global credential files | DEDA 8080, RabbitMQ 15672 |
| [Prometheus trigger](prometheus-trigger/README.md) | Strict single-value PromQL scaling from Traefik request rate | DEDA 8080, Prometheus 9090, HTTP 80 |
| [HTTP trigger](http-trigger/README.md) | Nested JSON `valuePath` extraction | DEDA 8081 |
| [Scale to zero](scale-to-zero/README.md) | Continuous-inactivity grace before zero | DEDA 8082 |
| [Redis HA](ha-redis/README.md) | Two DEDA replicas with leader/standby behavior | DEDA 8083 |
| [Observability](observability/README.md) | Prometheus scraping DEDA health/reconcile metrics | DEDA 8084, Prometheus 9091 |
| [Order processing](order-processing/README.md) | Queue worker, per-service credentials, stabilization, and metrics | DEDA 8085, Prometheus 9092, RabbitMQ 15675 |
| [Autoscaled CI runners](ci-runners/README.md) | GitHub Actions, Azure Pipelines, and GitLab runner lifecycle references | None |

## Common prerequisites

- Linux Docker Engine with Swarm mode active
- A Docker context with manager access
- Network and published ports available for the chosen example

```bash
docker swarm init
```

Examples default to the compatible pre-release
`ghcr.io/mikara89/deda:v0.1.0-preview.1`. Override `DEDA_IMAGE` with another
released tag or immutable digest when evaluating a different version:

```bash
DEDA_IMAGE=ghcr.io/mikara89/deda@sha256:DIGEST \
  docker stack deploy -c examples/minimal/stack.yml deda
```

Every DEDA topology uses the pinned socket-proxy image and a private overlay
network. The proxy narrows Docker API endpoint families, but service scaling
requires POST access; do not publish the proxy port.

## Suggested learning path

1. Deploy [minimal](minimal/README.md) and verify health.
2. Choose one trigger: [RabbitMQ](rabbitmq-trigger/README.md),
   [Prometheus](prometheus-trigger/README.md), or [HTTP](http-trigger/README.md).
3. Try [scale to zero](scale-to-zero/README.md).
4. Add [observability](observability/README.md).
5. Evaluate [Redis HA](ha-redis/README.md) only if multiple DEDA replicas are
   required.
6. Use [order processing](order-processing/README.md) as an integration
   blueprint.

The complete user documentation starts at [docs/README.md](../docs/README.md).
