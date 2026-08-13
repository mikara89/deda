# Observability example

This stack deploys DEDA and a Prometheus server that scrapes DEDA every five
seconds. It demonstrates health and reconciliation metrics without requiring an
autoscaled workload.

## Deploy

Deploy the stack. Swarm distributes `prometheus.yml` as a Docker config:

```bash
cd examples/observability
docker stack deploy -c stack.yml deda-observe
```

## Expected behavior

```bash
curl --fail http://MANAGER_IP:8084/health/live
curl --fail http://MANAGER_IP:8084/health/ready
curl --fail http://MANAGER_IP:8084/metrics | grep deda_reconcile_total
curl --get http://MANAGER_IP:9091/api/v1/query \
  --data-urlencode 'query=rate(deda_reconcile_total[1m])'
```

Prometheus is published on port 9091. Add an autoscaled example workload to
populate trigger and scaling metrics.

## Clean up

```bash
docker stack rm deda-observe
```

See [observability](../../docs/observability.md) for health semantics, the full
metric catalog, PromQL, structured logs, traces, and OTLP configuration.
