# HTTP trigger

The `http` trigger sends an HTTP GET to an operator-controlled endpoint and
extracts one numeric workload value.

## Labels

All names use the `com.deda.autoscale.` prefix.

| Label | Required | Default | Supported value |
| --- | --- | --- | --- |
| `trigger.type` | Yes | — | `http` |
| `trigger.url` | Yes | — | Absolute `http://` or `https://` URL |
| `trigger.timeoutSeconds` | No | `5` | Positive integer, capped at 120 seconds |
| `trigger.valuePath` | No | See below | Dot-separated, case-sensitive JSON object properties |

Only GET is supported. Redirect and transport behavior use the .NET HTTP client
defaults. Successful response bodies are limited to 65,536 characters (64 KiB).

## Response formats

A plain numeric body:

```text
42
```

A JSON root number or numeric string:

```json
42
```

With no `valuePath`, a top-level `value` property:

```json
{
  "value": 42
}
```

A nested object:

```json
{
  "queue": {
    "pending": 42
  }
}
```

Use:

```yaml
com.deda.autoscale.trigger.valuePath: "queue.pending"
```

Arrays and general JSONPath expressions are not supported. Missing paths,
non-numeric values, non-success HTTP status codes, oversized bodies, negative
numbers, `NaN`, and infinities invoke the configured fail-safe policy.

## Complete service configuration

```yaml
services:
  worker:
    image: example/orders-worker:1.0
    networks: [application]
    deploy:
      replicas: 1
      labels:
        com.deda.autoscale.enabled: "true"
        com.deda.autoscale.min: "0"
        com.deda.autoscale.max: "20"
        com.deda.autoscale.targetPerReplica: "25"
        com.deda.autoscale.activationThreshold: "1"
        com.deda.autoscale.scaleToZeroGraceSeconds: "60"
        com.deda.autoscale.trigger.type: "http"
        com.deda.autoscale.trigger.url: "http://worker-metrics:8080/queue"
        com.deda.autoscale.trigger.valuePath: "queue.pending"
        com.deda.autoscale.trigger.timeoutSeconds: "5"
        com.deda.autoscale.failsafe: "hold"
```

The endpoint is part of the autoscaling control plane. Authenticate or
network-isolate it, keep it fast, and return a stable aggregate rather than a
per-instance value unless that is intentional. DEDA does not currently provide
custom HTTP authentication headers.

See the runnable [HTTP trigger example](../../examples/http-trigger/README.md).
