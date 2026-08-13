# Redis HA example

This stack runs two DEDA replicas coordinated by one Redis TTL lease. One
replica is leader and the other is a healthy standby.

Redis itself is a single-replica demo service here. Use an appropriately
available Redis deployment before relying on DEDA HA in production.

## Deploy

```bash
docker stack deploy -c examples/ha-redis/stack.yml deda-ha
```

## Expected behavior

Both DEDA tasks run, only one logs lease acquisition, and the load-balanced
readiness endpoint returns HTTP 200 after reconciliation.

```bash
docker service ps deda-ha_deda
docker service logs --since 2m deda-ha_deda
curl --fail http://MANAGER_IP:8083/health/ready
```

To observe failover, identify and stop the task/node hosting the current leader,
then watch the logs. Take care not to disrupt a shared Swarm while testing.

To observe readiness failure in an isolated test cluster, temporarily scale
Redis to zero:

```bash
docker service scale deda-ha_redis=0
curl -i http://MANAGER_IP:8083/health/ready
docker service scale deda-ha_redis=1
```

During a Redis outage, each DEDA replica fails closed and becomes unready.

## Clean up

```bash
docker stack rm deda-ha
```

The named Redis volume remains until explicitly removed. See the
[HA guide](../../docs/high-availability.md) for failure limits and production
considerations.
