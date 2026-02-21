# Examples

Ready-to-deploy Docker Swarm stack files for common DEDA setups. Each example is
self-contained and fully commented.

---

## Overview

| Example                                               | Trigger                  | When to use                                       |
| ----------------------------------------------------- | ------------------------ | ------------------------------------------------- |
| [`minimal/`](minimal/stack.yml)                       | none                     | Starting point — add your own services and labels |
| [`rabbitmq-trigger/`](rabbitmq-trigger/stack.yml)     | RabbitMQ queue depth     | Worker queues, task processors, event consumers   |
| [`prometheus-trigger/`](prometheus-trigger/stack.yml) | Prometheus instant query | HTTP traffic (via Traefik), any custom metric     |

All examples follow the same base pattern from the DEDA CLI tool template:

- **Overlay network** (`deda_net`) — services communicate by name, no direct
  port exposure needed
- **Docker socket proxy** — DEDA talks to a `tecnativa/docker-socket-proxy`
  sidecar instead of mounting the raw Docker socket; no root access required
- **Resource limits** — DEDA is capped at `0.25 cpu / 256M` by default
- **Restart policy** — `on-failure` with a 5-second delay on all critical
  services

---

## Prerequisites

All examples require Docker Swarm mode:

```bash
docker swarm init
```

The `rabbitmq-trigger` example additionally requires two Swarm secrets before
deploying:

```bash
# Replace the values with your actual RabbitMQ credentials
printf 'admin'    | docker secret create rabbitmq_user -
printf 'changeme' | docker secret create rabbitmq_pass -
```

---

## Deploy

### Minimal

```bash
docker stack deploy -c examples/minimal/stack.yml deda
```

### RabbitMQ trigger

```bash
docker stack deploy -c examples/rabbitmq-trigger/stack.yml deda
```

### Prometheus trigger

The Prometheus config file uses a relative path mount, so deploy from the
example directory:

```bash
cd examples/prometheus-trigger
docker stack deploy -c stack.yml deda
```

---

## Verify

After deploying, check service health:

```bash
docker stack services deda
curl http://localhost:8080/health/ready
curl http://localhost:8080/metrics
```

Remove a stack when done:

```bash
docker stack rm deda
```

---

## Adapting to your workload

1. Copy the relevant example directory
2. Replace `ghcr.io/mikara89/deda:latest` with a pinned image tag
3. Replace `nginxdemos/hello:plain-text` / `alpine:3.20` with your real service
   image
4. Adjust the `com.deda.autoscale.*` labels on your service — see the full
   [Label Reference](../README.md#label-reference) in the root README

---

## See also

- [Label Reference](../README.md#label-reference)
- [Trigger Configuration](../README.md#trigger-configuration)
- [deploy/swarm/deda-stack.yml](../deploy/swarm/deda-stack.yml) — all-in-one
  development sandbox (RabbitMQ + Prometheus + Traefik)
- [docs/adr/](../docs/adr/README.md) — architecture decisions explaining the
  socket proxy, credentials, and scaling logic
