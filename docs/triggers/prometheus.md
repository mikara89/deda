# Prometheus trigger

The `prometheus` trigger performs an instant query against
`{trigger.url}/api/v1/query`.

## Labels

All names use the `com.deda.autoscale.` prefix.

| Label | Required | Default | Supported value |
| --- | --- | --- | --- |
| `trigger.type` | Yes | — | `prometheus` |
| `trigger.url` | Yes | — | Prometheus base URL, such as `http://prometheus:9090` |
| `trigger.query` | Yes | — | PromQL instant-query expression |
| `trigger.timeoutSeconds` | No | `5` | Positive integer, capped at 120 seconds |

```yaml
deploy:
  replicas: 1
  labels:
    com.deda.autoscale.enabled: "true"
    com.deda.autoscale.min: "1"
    com.deda.autoscale.max: "20"
    com.deda.autoscale.targetPerReplica: "10"
    com.deda.autoscale.trigger.type: "prometheus"
    com.deda.autoscale.trigger.url: "http://prometheus:9090"
    com.deda.autoscale.trigger.query: "sum(rate(my_jobs_processed_total[1m]))"
    com.deda.autoscale.trigger.timeoutSeconds: "5"
    com.deda.autoscale.failsafe: "hold"
```

`my_jobs_processed_total` is an example application metric, not a metric
provided by DEDA.

## Strict result semantics

DEDA accepts:

- a Prometheus scalar result;
- exactly one vector series;
- an empty vector, which represents zero work.

DEDA rejects matrices, strings, invalid values, and vectors containing more
than one series. It never silently selects the first series.

This query may be ambiguous:

```promql
rate(requests_total[1m])
```

If it returns one series per instance, DEDA rejects it. Aggregate intentionally:

```promql
sum(rate(requests_total[1m]))
```

Aggregation matters because DEDA needs one workload number for one Swarm
service. Select labels carefully when a shared Prometheus monitors multiple
applications.

## Query examples

Backlog-like application metric:

```promql
sum(my_application_pending_jobs)
```

Processing-rate application metric:

```promql
sum(rate(my_jobs_processed_total[1m]))
```

These names are illustrative. Your application or exporter must expose them.
For a rate, align `targetPerReplica` with work per second per replica; for a
backlog, align it with pending units per replica.

Test the exact query before enabling autoscaling:

```bash
curl --get 'http://PROMETHEUS:9090/api/v1/query' \
  --data-urlencode 'query=sum(my_application_pending_jobs)'
```

Inspect `data.resultType` and ensure `data.result` contains a scalar or at most
one vector entry. See the runnable [Prometheus example](../../examples/prometheus-trigger/README.md).
