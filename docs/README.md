# DEDA documentation

DEDA documentation is organized in three levels so you can start small and go
deeper only when needed.

## Start in five minutes

- [Getting started](getting-started.md) — install DEDA, label one service, and
  verify health, metrics, and evaluation.

## Task-oriented guides

- [RabbitMQ trigger](triggers/rabbitmq.md)
- [Prometheus trigger](triggers/prometheus.md)
- [HTTP trigger](triggers/http.md)
- [CI runner triggers](triggers/ci-runners.md)
- [Autoscaled CI runner deployments](../examples/ci-runners/README.md)
- [v0.3 CI runner qualification](qualification/ci-runners-v0.3.md)
- [Scaling and scale-to-zero](scaling.md)
- [Observability](observability.md)
- [Optional Redis high availability](high-availability.md)
- [Production deployment](production.md)
- [Troubleshooting](troubleshooting.md)

## Reference

- [Labels and environment variables](configuration.md)
- [Runnable examples](../examples/README.md)
- [Docker CLI plugin](../src/tools/Docker.Deda.Cli/README.md)
- [Architecture decision records](adr/README.md)

The root [README](../README.md) remains the project overview. These pages are
the canonical user and operator documentation; ADRs explain why the internal
architecture was chosen.
