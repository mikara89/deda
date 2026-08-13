# Troubleshooting

Start with the running tasks, recent logs, health endpoints, and exact service
labels:

```bash
docker service ps deda_deda --no-trunc
docker service logs --tail 200 deda_deda
curl -i http://MANAGER_IP:8080/health/live
curl -i http://MANAGER_IP:8080/health/ready
docker service inspect STACK_SERVICE --format '{{json .Spec.Labels}}'
```

## DEDA is live but not ready

Liveness only proves the process is serving HTTP. Readiness needs a successful
reconciliation.

Check:

- `DOCKER_HOST` and connectivity to the manager/socket proxy;
- that the proxy and DEDA are on the same overlay network;
- manager status with `docker node ls`;
- Redis connectivity and lease settings when HA is enabled;
- the readiness response body and DEDA logs.

Readiness is initially 503 until the first attempt succeeds. A healthy Redis
standby is ready; a Redis infrastructure failure is not.

## A service never scales

Check:

- `com.deda.autoscale.enabled` is exactly parseable as `true`;
- labels are under `deploy.labels` on the Swarm service;
- the service uses replicated mode, not global mode;
- `trigger.type` is exactly `rabbitmq`, `prometheus`, or `http`;
- `targetPerReplica`, `min`, and `max` are sensible and valid;
- DEDA can resolve and reach the trigger endpoint;
- the metric is finite, non-negative, and above `activationThreshold` when
  scale-up is expected;
- `stepUp` is not limiting the change more than expected;
- `deda_trigger_requests_total` and logs show evaluations.

Unknown trigger types and invalid core configuration are logged as service
errors without making global readiness fail.

## Prometheus reports an ambiguous result

The query returned more than one vector series. DEDA requires one number.

Bad when it returns one series per instance:

```promql
rate(requests_total[1m])
```

Aggregate and scope it intentionally:

```promql
sum(rate(requests_total{job="orders"}[1m]))
```

Use the Prometheus query API or expression browser to verify the result before
updating labels.

## RabbitMQ returns 401 or 403

Check:

- the management API, not the AMQP port, is used in `trigger.url`;
- global `RABBITMQ_USER`/`RABBITMQ_PASS` or `_FILE` paths are present;
- a `trigger.credentialsSecret` is mounted on DEDA and contains one
  `username:password` line;
- the account has permission to inspect the configured vhost and queue;
- the vhost and queue names are correct.

Never copy a password into a service label to test it.

## A service scales up but not down

Inspect:

- `cooldownSeconds`: downscale is blocked after a DEDA scale-up;
- `scaleDownDelaySeconds`: a recent higher recommendation is retained;
- `stepDown`: removal may be intentionally gradual;
- the current metric and `activationThreshold`;
- other actors that may be changing the service replica count.

Cooldown is evaluated before stabilization. The two delays can accumulate.

## A service does not scale to zero

Check:

- `min=0`;
- work remains at or below `activationThreshold`;
- `scaleToZeroGraceSeconds` has elapsed continuously;
- the trigger remains healthy—failures reset inactivity evidence;
- cooldown and scale-down stabilization have also released;
- `stepDown` allows the remaining decrease.

`failsafe=min` with `min=0` can intentionally select zero on failure, bypassing
the ordinary grace path.

## Unknown trigger type

Supported values are:

```text
rabbitmq
prometheus
http
```

Values are resolved case-insensitively, but use the lowercase canonical names
in configuration.

## A global service does not scale

This is intentional. Global-mode services have one task per eligible node and
do not expose a replicated desired count that DEDA can control. Use replicated
mode for autoscaled workloads.

## DEDA repeatedly retries after Docker or Redis failure

Controller-level failures keep the process alive, mark readiness unhealthy, and
use exponential backoff capped by `DEDA_MAX_RECONCILE_BACKOFF_SECONDS`.
Restore the dependency and watch for the next successful reconciliation;
readiness then recovers and the backoff resets.

## Configuration appears to use an unexpected default

Malformed numeric label values fall back to defaults before validation. Quote
YAML values, inspect `.Spec.Labels`, and compare against the
[configuration reference](configuration.md). The deprecated service label
`com.deda.autoscale.pollSeconds` is ignored; set `DEDA_POLL_SECONDS` on DEDA.
