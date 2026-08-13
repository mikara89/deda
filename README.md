# DEDA — Docker Swarm Autoscaler

[![CI](https://github.com/mikara89/deda/actions/workflows/ci.yml/badge.svg)](https://github.com/mikara89/deda/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**DEDA** is a KEDA-inspired autoscaler for **Docker Swarm**. It runs as a single
daemon on your Swarm manager, watches all services, and scales replica counts up
or down based on external metrics — RabbitMQ queue depth, Prometheus queries,
and more.

> **Status: release-candidate development.** The autoscaling loop, resilient
> reconciliation, OpenTelemetry, release hardening, and optional Redis leader
> election are implemented; see the remaining [roadmap](#roadmap) items.

---

## Features

- Scale Swarm services by RabbitMQ queue depth, Prometheus, or an HTTP scalar endpoint
- Configuration entirely via Docker service labels — no config files to manage
- Cooldown, recommendation-based scale-down stabilization, and per-step limits prevent flapping
- Round-robin paging across large service fleets (`DEDA_MAX_SERVICES_PER_CYCLE`)
- Optional active/standby replicas using a fail-closed Redis TTL leader lease
- Built-in `/metrics` (Prometheus text), `/health/live`, `/health/ready`
  endpoints
- Compiled as a NativeAOT Linux binary — tiny footprint, instant startup

---

## Quickstart

### 1. Label your service

```yaml
services:
    my-worker:
        image: my-worker:latest
        deploy:
            replicas: 1
            labels:
                com.deda.autoscale.enabled: "true"
                com.deda.autoscale.min: "1"
                com.deda.autoscale.max: "20"
                com.deda.autoscale.targetPerReplica: "50"
                com.deda.autoscale.trigger.type: "rabbitmq"
                com.deda.autoscale.trigger.url: "http://rabbitmq:15672"
                com.deda.autoscale.trigger.queue: "my-queue"
```

### 2. Deploy DEDA alongside your stack

```yaml
services:
    deda:
        image: ghcr.io/mikara89/deda:latest
        environment:
            DEDA_POLL_SECONDS: "10"
        user: "0:0" # needs access to the Docker socket
        volumes:
            - /var/run/docker.sock:/var/run/docker.sock:ro
        deploy:
            replicas: 1
            placement:
                constraints:
                    - node.role == manager
            restart_policy:
                condition: on-failure
```

```bash
docker stack deploy -c deda-stack.yml myapp
```

Ready-to-deploy, fully commented example stacks are in
[`examples/`](examples/README.md):

| Example                                                                 | Trigger                                    |
| ----------------------------------------------------------------------- | ------------------------------------------ |
| [`examples/minimal/`](examples/minimal/stack.yml)                       | none — base pattern, add your own services |
| [`examples/rabbitmq-trigger/`](examples/rabbitmq-trigger/stack.yml)     | RabbitMQ queue depth                       |
| [`examples/prometheus-trigger/`](examples/prometheus-trigger/stack.yml) | Prometheus instant query                   |

A development sandbox with all services combined (RabbitMQ + Prometheus +
Traefik, dev credentials) is in
[`deploy/swarm/deda-stack.yml`](deploy/swarm/deda-stack.yml).

> ⚠️ The development stack contains `RABBITMQ_DEFAULT_USER: admin` /
> `RABBITMQ_DEFAULT_PASS: admin`. These are **local development credentials
> only**. Never use them in production. The production examples in `examples/`
> use Docker Swarm secrets and `RABBITMQ_USER_FILE` / `RABBITMQ_PASS_FILE`
> instead.

---

## Label Reference

All labels are prefixed with `com.deda.autoscale.`.

| Label                   | Type   | Default | Description                                                                   |
| ----------------------- | ------ | ------- | ----------------------------------------------------------------------------- |
| `enabled`               | bool   | —       | **Required.** Must be `"true"` to opt in.                                     |
| `min`                   | int    | `0`     | Minimum replica count.                                                        |
| `max`                   | int    | `50`    | Maximum replica count.                                                        |
| `targetPerReplica`      | double | `50`    | Desired work units per replica (e.g., messages per worker).                   |
| `activationThreshold`   | double | `5`     | Work at or below this value is inactive and recommends `min`.                 |
| `cooldownSeconds`       | int    | `60`    | How long to block scale-down after a scale-up event.                          |
| `scaleDownDelaySeconds` | int    | `120`   | Timestamp-based desired-replica stabilization window for scale-down.          |
| `scaleToZeroGraceSeconds` | int  | `0`     | Continuous inactive time required before a service with `min=0` can reach zero. |
| `stepUp`                | int    | `10`    | Maximum replicas added in a single cycle. `0` = unlimited.                    |
| `stepDown`              | int    | `5`     | Maximum replicas removed in a single cycle. `0` = unlimited.                  |
| `pollSeconds`           | int    | —        | Deprecated and ignored; use the global `DEDA_POLL_SECONDS` setting.           |
| `trigger.type`          | string | —       | **Required.** Trigger type: `rabbitmq`, `prometheus`, or `http`.               |
| `trigger.*`             | string | —       | Trigger-specific configuration keys (see below).                              |
| `failsafe`              | string | `hold`  | Replica target when the trigger fails: `hold`, `min`, or `max`.               |

---

## Scaling behavior

For a valid, active workload, DEDA recommends
`ceil(work / targetPerReplica)`, clamps that recommendation to `min`/`max`, and
records it with its observation time. `activationThreshold` is used only to
identify an inactive or near-zero workload and recommend `min`; it does not
gate proportional downscaling.

Scale-up recommendations are applied immediately, subject to `stepUp`. For a
scale-down, DEDA selects the highest desired-replica recommendation still inside
`scaleDownDelaySeconds`, then applies `stepDown`. Recommendations expire by
elapsed time rather than sample count, so long windows do not depend on the
polling frequency or a fixed history capacity. Setting the window to `0`
disables recommendation stabilization. An expiry queue and monotonic maximum
deque keep state operations amortized O(1); time windows are limited to 86,400
seconds.

When `min=0`, `scaleToZeroGraceSeconds` requires continuously inactive work
before zero is recommended. Active work resets the timer. Cooldown and
scale-down stabilization still apply after the grace period.

`DEDA_POLL_SECONDS` is the authoritative reconcile-loop interval. The legacy
`com.deda.autoscale.pollSeconds` label is retained as a deprecated compatibility
surface but is ignored; DEDA does not schedule services independently.

Successful trigger responses must contain a finite, non-negative workload.
`NaN`, infinities, and negative values are treated as trigger failures and use
the service's configured `failsafe` behavior.

---

## Trigger Configuration

### RabbitMQ

Reads queue depth from the
[RabbitMQ Management HTTP API](https://www.rabbitmq.com/management.html).

| Label                       | Required | Default    | Description                                                                                                                                                                                                                |
| --------------------------- | -------- | ---------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `trigger.type`              | ✅       | —          | `rabbitmq`                                                                                                                                                                                                                 |
| `trigger.url`               | ✅       | —          | Base URL of the management API, e.g. `http://rabbitmq:15672`                                                                                                                                                               |
| `trigger.queue`             | ✅       | —          | Queue name                                                                                                                                                                                                                 |
| `trigger.vhost`             | —        | `/`        | Virtual host                                                                                                                                                                                                               |
| `trigger.metric`            | —        | `messages` | `messages`, `messages_ready`, or `messages_unacknowledged`                                                                                                                                                                 |
| `trigger.timeoutSeconds`    | —        | `5`        | HTTP request timeout                                                                                                                                                                                                       |
| `trigger.credentialsSecret` | —        | —          | Name of a Docker Swarm secret containing `username:password` for this service. Overrides the global `RABBITMQ_USER` / `RABBITMQ_PASS` credentials. See [Per-service credentials](#per-service-rabbitmq-credentials) below. |

```yaml
deploy:
    labels:
        com.deda.autoscale.enabled: "true"
        com.deda.autoscale.min: "0"
        com.deda.autoscale.max: "20"
        com.deda.autoscale.targetPerReplica: "50"
        com.deda.autoscale.trigger.type: "rabbitmq"
        com.deda.autoscale.trigger.url: "http://rabbitmq:15672"
        com.deda.autoscale.trigger.vhost: "/"
        com.deda.autoscale.trigger.queue: "orders"
        com.deda.autoscale.trigger.metric: "messages_ready"
```

RabbitMQ credentials are read from environment variables on the **DEDA**
container, not service labels:

| Env var              | Description                                          |
| -------------------- | ---------------------------------------------------- |
| `RABBITMQ_USER`      | Username (plain)                                     |
| `RABBITMQ_PASS`      | Password (plain)                                     |
| `RABBITMQ_USER_FILE` | Path to a Docker secret file containing the username |
| `RABBITMQ_PASS_FILE` | Path to a Docker secret file containing the password |

By default, services share the global credential set. A service can override it
with `trigger.credentialsSecret` as described below. Credentials are resolved on
each poll so mounted-secret rotation takes effect without restarting DEDA.

---

### Per-service RabbitMQ credentials

To use different credentials for a specific service, create a Docker Swarm
secret whose contents are `username:password` on a single line, then reference
it by name in the service label:

**1. Create the secret:**

```bash
echo -n "tenant_b_user:tenant_b_pass" | docker secret create rabbitmq_tenant_b -
```

**2. Mount it on the DEDA container:**

```yaml
services:
    deda:
        secrets:
            - rabbitmq_tenant_b # must be mounted so DEDA can read /run/secrets/rabbitmq_tenant_b
```

**3. Reference it in the scaled service label:**

```yaml
deploy:
    labels:
        com.deda.autoscale.enabled: "true"
        com.deda.autoscale.trigger.type: "rabbitmq"
        com.deda.autoscale.trigger.url: "http://rabbitmq-b:15672"
        com.deda.autoscale.trigger.queue: "my-queue"
        com.deda.autoscale.trigger.credentialsSecret: "rabbitmq_tenant_b"
```

DEDA reads `/run/secrets/rabbitmq_tenant_b`, splits on the first `:`, and uses
those credentials only for this service's trigger calls. Services without
`trigger.credentialsSecret` continue to use the global `RABBITMQ_USER` /
`RABBITMQ_PASS`.

The secrets directory defaults to `/run/secrets` and can be changed with
`DEDA_SECRETS_DIRECTORY`. Secret names must be single file names; path traversal
is rejected.

---

### Prometheus

Runs an instant query against a Prometheus HTTP API. The query must return a
scalar or exactly one vector series. Empty vectors represent zero work; vectors
with multiple series are rejected as ambiguous instead of selecting one
silently.

| Label                    | Required | Default | Description                             |
| ------------------------ | -------- | ------- | --------------------------------------- |
| `trigger.type`           | ✅       | —       | `prometheus`                            |
| `trigger.url`            | ✅       | —       | Base URL, e.g. `http://prometheus:9090` |
| `trigger.query`          | ✅       | —       | PromQL expression                       |
| `trigger.timeoutSeconds` | —        | `5`     | HTTP request timeout                    |

```yaml
deploy:
    labels:
        com.deda.autoscale.enabled: "true"
        com.deda.autoscale.min: "1"
        com.deda.autoscale.max: "10"
        com.deda.autoscale.targetPerReplica: "100"
        com.deda.autoscale.trigger.type: "prometheus"
        com.deda.autoscale.trigger.url: "http://prometheus:9090"
        com.deda.autoscale.trigger.query: "sum(rate(http_requests_total[1m]))"
```

### HTTP

Performs a GET against an operator-controlled HTTP(S) endpoint. The response may
be a plain number, a JSON root scalar, a top-level `value`, or a nested scalar
selected by a dot-separated `valuePath`. Responses larger than 64 KiB,
ambiguous objects, and invalid workload values fail safely.

| Label                    | Required | Default | Description                                       |
| ------------------------ | -------- | ------- | ------------------------------------------------- |
| `trigger.type`           | ✅       | —       | `http`                                            |
| `trigger.url`            | ✅       | —       | Absolute HTTP(S) metric URL                       |
| `trigger.valuePath`      | —        | —       | Dotted JSON property path, e.g. `metrics.pending` |
| `trigger.timeoutSeconds` | —        | `5`     | Request timeout, capped at 120 seconds            |

```yaml
deploy:
    labels:
        com.deda.autoscale.enabled: "true"
        com.deda.autoscale.min: "0"
        com.deda.autoscale.max: "20"
        com.deda.autoscale.targetPerReplica: "25"
        com.deda.autoscale.scaleToZeroGraceSeconds: "60"
        com.deda.autoscale.trigger.type: "http"
        com.deda.autoscale.trigger.url: "http://worker-metrics:8080/queue"
        com.deda.autoscale.trigger.valuePath: "metrics.pending"
```

---

## Environment Variables (DEDA Daemon)

| Variable                      | Default | Description                                                             |
| ----------------------------- | ------- | ----------------------------------------------------------------------- |
| `DEDA_POLL_SECONDS`           | `10`    | Global reconcile loop interval in seconds (1–3600).                     |
| `DEDA_MAX_RECONCILE_BACKOFF_SECONDS` | `60` | Maximum retry delay after controller-level reconciliation failures. |
| `DEDA_SECRETS_DIRECTORY`      | `/run/secrets` | Directory containing named per-service Docker secrets.          |
| `DEDA_HTTP_TIMEOUT_SECONDS`   | `5`     | Default outbound HTTP timeout for triggers (1–120).                     |
| `DEDA_LOG_DECISIONS`          | `true`  | Log every scale decision to stdout.                                     |
| `DEDA_MAX_SERVICES_PER_CYCLE` | `0`     | Max services processed per poll cycle. `0` = no cap.                    |
| `DEDA_JITTER_ENABLED`         | `true`  | Stable-hash ordering of services to spread load across cycles.          |
| `DEDA_HTTP_PORT`              | `8080`  | Port for the `/metrics`, `/health/live`, and `/health/ready` endpoints. |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | —       | Enables OTLP metrics and traces using standard OpenTelemetry settings. |
| `DEDA_REDIS_CONNECTION`       | —       | Enables Redis leader election; omit for documented single-replica operation. |
| `DEDA_INSTANCE_ID`            | host/process | Unique owner ID for the Redis lease.                               |
| `DEDA_LEADER_LOCK_KEY`        | `deda:leader` | Redis key used for leader coordination.                           |
| `DEDA_LEADER_LEASE_SECONDS`   | `30`    | Leader lease TTL (5–300 seconds).                                    |
| `DEDA_LEADER_RENEW_SECONDS`   | `10`    | Renewal interval; must be shorter than the lease TTL.                 |

---

## Reconciliation health

Controller-level failures such as a temporarily unavailable Docker manager do
not terminate DEDA. The worker records the failed attempt, reports
`/health/ready` as HTTP 503, and retries with exponential backoff bounded by
`DEDA_MAX_RECONCILE_BACKOFF_SECONDS`. A subsequent successful reconciliation
automatically restores readiness and resets the retry delay. Cancellation during
shutdown is propagated and is not recorded as a failure.

Invalid service configuration and unknown trigger types are reported as explicit
service errors rather than being skipped silently.

---

## Observability

DEDA uses `ILogger<T>`, `System.Diagnostics.Metrics`, and `ActivitySource` with
the source name `Deda.Autoscaler`. `/metrics` is served by the OpenTelemetry
Prometheus exporter. Set `OTEL_EXPORTER_OTLP_ENDPOINT` to additionally export
metrics and traces to an OTLP-compatible backend; standard variables such as
`OTEL_EXPORTER_OTLP_PROTOCOL`, headers, and timeout are honored by the exporter.

Core metrics include reconcile count/failures/duration, trigger
requests/failures/duration/value, scale decisions/events, and current/desired
replicas. Dimensions are limited to service, trigger, direction, and result.
Trace spans cover reconciliation, Docker discovery, service evaluation, trigger
calls, scale decisions, and replica updates.

### High availability

Set `DEDA_REDIS_CONNECTION` on two or more DEDA replicas to enable active/standby
operation. The leader renews an owner-specific Redis TTL lease; standbys skip
reconciliation and take over after release or TTL expiry. Lease failures are
fail-closed, and ownership is confirmed again immediately before each Docker
replica update. Without Redis, DEDA warns at startup and must run with
`deploy.replicas: 1`. See [Deda.HA](src/Deda.HA/README.md) for operational
details and the Docker fencing limitation.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Docker Swarm Manager Node                                      │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  DEDA Daemon                                             │  │
│  │                                                          │  │
│  │  Worker loop (every DEDA_POLL_SECONDS)                   │  │
│  │    │                                                     │  │
│  │    ├─► AutoscalerController.ReconcileOnceAsync()         │  │
│  │    │     │                                               │  │
│  │    │     ├─► ISwarmServiceClient   ──► Docker Engine API │  │
│  │    │     │     ListServices / UpdateReplicas             │  │
│  │    │     │                                               │  │
│  │    │     ├─► IScaleConfigProvider  ──► Docker labels     │  │
│  │    │     │     (com.deda.autoscale.*)                    │  │
│  │    │     │                                               │  │
│  │    │     ├─► ITriggerAdapter       ──► Rabbit / Prom / HTTP │
│  │    │     │     GetWorkAsync()                            │  │
│  │    │     │                                               │  │
│  │    │     └─► IScalePolicy          (pure logic)         │  │
│  │    │           SimpleScalePolicyMvp.Decide()             │  │
│  │    │                                                     │  │
│  │    └─► IServiceUpdateStrategy                           │  │
│  │          RetryOnVersionConflictUpdateStrategy            │  │
│  │                                                          │  │
│  │  HTTP server (:8080)                                     │  │
│  │    GET /metrics      Prometheus text format              │  │
│  │    GET /health/live  Always 200                          │  │
│  │    GET /health/ready When reconcile loop is healthy      │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

### Project Layout

| Project                      | Role                                                         |
| ---------------------------- | ------------------------------------------------------------ |
| `Deda.Core`                  | Domain models and all port interfaces (no dependencies)      |
| `Deda.Controller`            | Main reconciliation loop                                     |
| `Deda.Swarm`                 | Docker Engine HTTP client (socket or TCP)                    |
| `Deda.Config.Labels`         | Parses `com.deda.autoscale.*` labels into `ScaleConfig`      |
| `Deda.Triggers.Abstractions` | Trigger registry                                             |
| `Deda.Triggers.RabbitMq`     | RabbitMQ Management API trigger                              |
| `Deda.Triggers.Prometheus`   | Prometheus instant query trigger                             |
| `Deda.Triggers.Http`         | Generic HTTP/JSON scalar metric trigger                      |
| `Deda.Policies`              | `SimpleScalePolicyMvp` — cooldown, delay window, step limits |
| `Deda.Updates`               | Optimistic concurrency update with backoff+jitter            |
| `Deda.Host`                  | DI wiring, hosted service, HTTP server, entry point          |
| `Deda.HA`                    | Optional Redis TTL leader lease for active/standby replicas  |
| `Deda.Observability`         | OpenTelemetry metrics, traces, and structured logging        |
| `examples/`                  | Ready-to-deploy, commented Swarm stack files                 |
| `deploy/swarm/`              | All-in-one development sandbox stack                         |

### Architecture Decision Records

The significant design decisions behind DEDA — including the choice of
NativeAOT, label-based configuration, the Docker socket proxy pattern, the
ring-buffer delay window, and more — are documented as ADRs in
[`docs/adr/`](docs/adr/README.md).

---

## Building Locally

### Prerequisites

- [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0)
- Docker (for running the example stack)

### Build and test

```bash
dotnet build Deda.sln
dotnet test Deda.sln
```

Unit and adapter tests run on every machine. CI additionally initializes a real
single-node Docker Swarm and runs `tests/swarm/run-e2e.sh`. That job verifies
Docker service discovery, label parsing, replicated/global modes, replica
updates, and end-to-end Prometheus and RabbitMQ scale-up/scale-down. The local
contract test activates only when `DEDA_SWARM_TESTS=1` and its service-name
environment variables are supplied by the harness.

### Build the Docker image

```bash
docker build -f src/Deda.Host/Dockerfile -t deda:local .
```

The image uses NativeAOT compilation. The build requires `clang` and
`zlib1g-dev` (installed automatically inside the multi-stage Dockerfile).

---

## Roadmap

### v1.0.0 — Stable Release Checklist

The following items must be completed before a v1.0.0 tag is cut. Items are
grouped by area. Open an issue if you want to pick one up.

#### Core correctness

- [x] **Per-service trigger credentials (`trigger.credentialsSecret`)** —
      implement label-driven secret resolution in `RabbitMqTriggerAdapter` so
      each service can reference a named Docker secret (`username:password`)
      instead of sharing the global credential set. See the
      [Per-service RabbitMQ credentials](#per-service-rabbitmq-credentials)
      section for the intended behaviour.
- [x] **Fix Prometheus metrics model** — replace the string-interpolated custom
      registry with standard OpenTelemetry instruments and the Prometheus
      exporter
- [x] **Switch telemetry to structured logging** — replace `ConsoleTelemetryMvp`
      / `Console.WriteLine` with `ILogger<T>` so log level, structured fields,
      and sink configuration all work through the standard .NET logging pipeline
- [x] **Warn when HA is disabled** — log a startup warning when `ILeaderElector`
      is not registered, so operators know they are running without HA

#### High availability (`Deda.HA`)

- [x] **Implement `ILeaderElector`** — at minimum one working strategy
      (shared-store TTL lock via Redis, or Swarm-native `replicas: 1` +
      documented single-instance guidance). See
      [src/Deda.HA/README.md](src/Deda.HA/README.md) for design options
- [x] **Integration test** — verify that a standby instance does not apply scale
      changes while a leader is active

#### Observability (`Deda.Observability`)

- [x] **Implement `IAutoscalerTelemetry` with OpenTelemetry** — emit scale event
      counters, current replica gauge, and trigger value gauge via the OTel
      metrics SDK
- [x] **Expose OTLP export** — configurable via `OTEL_EXPORTER_OTLP_ENDPOINT`
      following OTel conventions
- [x] **Distributed traces** — spans for the reconcile loop and each trigger
      call, so latency outliers are visible in any OTLP-compatible backend

#### Test coverage

- [x] **`AutoscalerController` unit tests** — mock all ports and assert the
      reconcile loop correctly pages, skips global services, records state, and
      calls `ApplyDesiredReplicasAsync` only on a real change
- [x] **`RetryOnVersionConflictUpdateStrategy` unit tests** — assert
      retry/backoff behaviour on version conflict responses
- [x] **`RabbitMqTriggerAdapter` unit tests** — mock `IHttpClientFactory` and
      assert metric extraction, auth header, and error paths
- [x] **`PrometheusTriggerAdapter` unit tests** — mock HTTP and assert PromQL
      response parsing and empty-result handling
- [x] **Minimum 80 % line coverage** enforced in CI

#### Deployment & packaging

- [x] **Pre-built Docker image on GHCR** — publish `ghcr.io/mikara89/deda:<tag>`
      via GitHub Actions on every version tag
- [x] **Multi-arch image** — `linux/amd64` and `linux/arm64` (NativeAOT
      cross-compilation)
- [ ] **Reference Swarm stack** — a production-ready
      `deploy/swarm/deda-stack.yml` with secrets, placement constraints,
      resource limits, and inline comments

#### Documentation

- [ ] **Per-service poll interval** — replace the deprecated, currently ignored
      `com.deda.autoscale.pollSeconds` label with real per-service scheduling
- [x] **Changelog** — maintain `CHANGELOG.md` with semantic versioning from
      first public release onwards
- [x] **Security policy** — add `SECURITY.md` with a vulnerability disclosure
      contact

---

### Backlog (post-v1.0.0)

| Area                         | Notes                                                           |
| ---------------------------- | --------------------------------------------------------------- |
| Additional triggers          | Redis list length, Kafka, cloud queues, custom webhooks          |
| Advanced scaling             | Scale-up stabilization, separate policies, predictive options   |
| Label-based trigger chaining | Scale on the max/avg of multiple trigger values for one service |
| Web UI / dashboard           | Read-only view of current service states and recent decisions   |

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

---

## License

[MIT](LICENSE)
