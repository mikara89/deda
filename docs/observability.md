# Observability

DEDA exposes health and Prometheus endpoints from one HTTP listener and can
export metrics and traces through OTLP.

## Health endpoints

The default listener port is 8080 (`DEDA_HTTP_PORT`).

| Endpoint | Success | Meaning |
| --- | --- | --- |
| `/health/live` | HTTP 200 | The DEDA process and web host are running. It does not prove Docker or metric sources are reachable. |
| `/health/ready` | HTTP 200 | The most recent controller-level reconciliation completed successfully. |
| `/health/ready` | HTTP 503 | No reconciliation has succeeded yet, Docker discovery failed, or Redis leader-election infrastructure is unavailable. |
| `/metrics` | HTTP 200 | Prometheus text exposition from the OpenTelemetry meter. |

A replica that successfully confirms another Redis owner is a healthy standby:
it skips Docker reconciliation and remains ready. A Redis connection or lease
operation failure is infrastructure failure and makes readiness unhealthy.
Individual service configuration or trigger failures are recorded but do not
make the entire DEDA process unready.

```bash
curl --fail http://MANAGER_IP:8080/health/live
curl --fail http://MANAGER_IP:8080/health/ready
curl --fail http://MANAGER_IP:8080/metrics
```

## Metrics

These names are the exact instrument and Prometheus family names emitted by the
current implementation.

### Reconciliation

| Metric | Type | Dimensions | Meaning |
| --- | --- | --- | --- |
| `deda_reconcile_total` | Counter | `result` | Completed reconciliation attempts. |
| `deda_reconcile_failures_total` | Counter | None | Controller-level failures. |
| `deda_reconcile_duration_seconds` | Histogram | `result` | Reconciliation duration. Prometheus also exposes `_bucket`, `_sum`, and `_count` series. |

### Triggers

| Metric | Type | Dimensions | Meaning |
| --- | --- | --- | --- |
| `deda_trigger_requests_total` | Counter | `service`, `trigger`, `result` | Trigger evaluations. |
| `deda_trigger_failures_total` | Counter | `service`, `trigger`, `result` | Failed trigger evaluations. |
| `deda_trigger_duration_seconds` | Histogram | `service`, `trigger`, `result` | Trigger request duration. |
| `deda_trigger_value` | Observable gauge | `service`, `trigger` | Latest successful workload value. A failed observation removes the current value. |

### CI triggers

| Metric | Type | Dimensions | Meaning |
| --- | --- | --- | --- |
| `deda_ci_jobs_queued` | Observable gauge | `provider`, `service` | Latest compatible queued jobs. |
| `deda_ci_jobs_active` | Observable gauge | `provider`, `service` | Latest compatible active jobs. |
| `deda_ci_required_capacity` | Observable gauge | `provider`, `service` | Queued plus active jobs; this is the trigger workload. |
| `deda_ci_api_requests_total` | Counter | `provider` | Successful CI queue observations. |
| `deda_ci_api_failures_total` | Counter | `provider` | Failed CI provider observations. |
| `deda_ci_observation_age_seconds` | Observable gauge | `provider`, `service` | Age of the most recent successful queue observation. |

### Scaling

| Metric | Type | Dimensions | Meaning |
| --- | --- | --- | --- |
| `deda_scale_decisions_total` | Counter | `service`, `direction` | Scale decisions, including holds. |
| `deda_scale_events_total` | Counter | `service`, `direction` | Decisions whose desired count differs from current. |
| `deda_current_replicas` | Observable gauge | `service` | Replica count observed for the latest decision. |
| `deda_desired_replicas` | Observable gauge | `service` | Desired count from the latest decision. |

The exporter also supplies resource/scope labels such as `otel_scope_name`.
Avoid alert rules that require those labels unless your telemetry pipeline
preserves them.

Useful PromQL:

```promql
# Controller failures per second over five minutes
rate(deda_reconcile_failures_total[5m])
```

```promql
# Non-hold scaling activity by service and direction
sum by (service, direction) (
  rate(deda_scale_events_total[5m])
)
```

```promql
# Latest desired/current difference
deda_desired_replicas - deda_current_replicas
```

```promql
# 95th percentile trigger latency
histogram_quantile(
  0.95,
  sum by (le, trigger) (rate(deda_trigger_duration_seconds_bucket[5m]))
)
```

## Structured logs and traces

Scale decisions and errors use `ILogger<T>` structured fields. Useful commands:

```bash
docker service logs --since 10m deda_deda
docker service logs --since 10m deda_deda 2>&1 | grep 'Scale decision'
```

Activities use source `Deda.Autoscaler` and cover reconciliation, discovery,
service evaluation, trigger calls, policy decisions, and replica updates.

## OTLP export

Set an endpoint to add OTLP exporters alongside `/metrics`:

```yaml
environment:
  OTEL_EXPORTER_OTLP_ENDPOINT: "http://otel-collector:4317"
  OTEL_EXPORTER_OTLP_PROTOCOL: "grpc"
```

Standard OpenTelemetry variables for headers, protocol, and timeout are honored
by the .NET OpenTelemetry SDK. DEDA does not define custom replacements for
them. Network access to the collector and any required authentication headers
must be configured explicitly.

See the runnable [observability example](../examples/observability/README.md).
