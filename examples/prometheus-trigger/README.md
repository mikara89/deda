# Prometheus trigger example

This stack routes traffic through Traefik, scrapes Traefik and DEDA with
Prometheus, and scales the demo HTTP service from the aggregated Traefik request
rate.

The stack name is intentionally `deda-prometheus` because the Traefik network
configuration references Docker's stack-scoped network name.

## Prerequisites

- Active Linux Docker Swarm
- Manager-node Docker context
- Ports 80, 8080, and 9090 available

## Deploy

Deploy from this directory so the Prometheus bind mount resolves:

```bash
cd examples/prometheus-trigger
docker stack deploy -c stack.yml deda-prometheus
```

## Generate load

```bash
for i in $(seq 1 1000); do
  curl --silent --header 'Host: demo.local' http://MANAGER_IP/ >/dev/null &
done
wait
```

## Expected behavior

Prometheus scrapes Traefik every 10 seconds. DEDA evaluates
`sum(rate(traefik_service_requests_total[1m]))`; sustained request rate above
the activation threshold produces a proportional scale-up.

```bash
curl --fail http://MANAGER_IP:8080/health/ready
curl --get 'http://MANAGER_IP:9090/api/v1/query' \
  --data-urlencode 'query=sum(rate(traefik_service_requests_total[1m]))'
docker service logs --since 5m deda-prometheus_deda
docker service inspect deda-prometheus_demo-http \
  --format '{{.Spec.Mode.Replicated.Replicas}}'
```

## Clean up

```bash
docker stack rm deda-prometheus
```

The example uses Traefik's direct Docker socket mount for its own Swarm
provider. Review that separate privilege before adapting the demo. See the
[Prometheus trigger guide](../../docs/triggers/prometheus.md).
