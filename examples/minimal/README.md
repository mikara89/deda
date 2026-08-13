# Minimal DEDA stack

This example deploys DEDA and a private Docker socket proxy. It does not include
a metric source or autoscaled workload; use it as the common installation base
for services in other stacks.

## Prerequisites

- Active Linux Docker Swarm
- Manager-node Docker context

## Deploy

```bash
docker network create --driver overlay deda_metrics
docker stack deploy -c examples/minimal/stack.yml deda
```

`deda_metrics` is a shared external overlay for metric endpoints deployed in
other stacks. Attach only metric-source services that DEDA must reach. The
Docker proxy remains isolated on the stack-private `deda_net` network.

## Expected behavior

The `deda_docker-proxy` and `deda_deda` services reach one replica. Readiness
becomes HTTP 200 after DEDA successfully lists Swarm services.

```bash
docker stack services deda
curl --fail http://MANAGER_IP:8080/health/live
curl --fail http://MANAGER_IP:8080/health/ready
curl --fail http://MANAGER_IP:8080/metrics | head
```

Add an autoscaled service by following [getting started](../../docs/getting-started.md#3-opt-one-service-into-autoscaling).
Pin the DEDA image to a version or digest before production use.

## Clean up

```bash
docker stack rm deda
docker network rm deda_metrics
```

See [production deployment](../../docs/production.md) for socket-proxy,
resource, network, and image guidance.
