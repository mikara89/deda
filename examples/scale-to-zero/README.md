# Scale-to-zero example

This stack starts a demo worker at one replica and exposes a continuously zero
HTTP metric. DEDA requires 30 seconds of valid continuous inactivity before it
can recommend zero.

## Deploy

```bash
docker stack deploy -c examples/scale-to-zero/stack.yml deda-zero
```

## Expected behavior

The worker remains at one replica during the grace window, then reaches zero.
Cooldown, stabilization, and step-down are disabled here so only grace behavior
is visible.

```bash
watch docker service inspect deda-zero_worker \
  --format '{{.Spec.Mode.Replicated.Replicas}}'
```

Read DEDA logs to see `scaleToZeroGraceBlocked=True` during the window:

```bash
docker service logs --since 2m deda-zero_deda
```

## Clean up

```bash
docker stack rm deda-zero
```

See [scaling behavior](../../docs/scaling.md#d-scale-to-zero) before enabling
zero in a workload with startup dependencies.
