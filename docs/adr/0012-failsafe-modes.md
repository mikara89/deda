# ADR-0012: FailSafe Modes (Hold / Min / Max) on Trigger Failure

**Date:** 2026-02-21 **Status:** Accepted

## Context

When a trigger adapter cannot read the metric — network partition, RabbitMQ
management API down, Prometheus unreachable, HTTP timeout — the autoscaler must
decide what to do with the current replica count. The correct answer differs by
workload:

- A critical stateless service should scale to maximum capacity to absorb
  potential load.
- A batch or cost-sensitive service should scale to minimum (zero) replicas when
  the metric source is unavailable.
- A stateful service should hold its current count to avoid any disruption.

## Decision

`ScaleConfig.FailSafe` is an enum with three values, configurable per service
via the `com.deda.autoscale.failsafe` label:

| Value  | Behaviour                  | Label value      |
| ------ | -------------------------- | ---------------- |
| `Hold` | Keep current replica count | `hold` (default) |
| `Min`  | Scale to `MinReplicas`     | `min`            |
| `Max`  | Scale to `MaxReplicas`     | `max`            |

`SimpleScalePolicyMvp` applies the failsafe mode when
`trigger.Success == false`, then clamps the result within
`[MinReplicas, MaxReplicas]`. The decision reason string is prefixed with
`trigger_failed:<error>` so the failsafe activation is visible in logs and
metrics. A nominally successful response containing `NaN`, infinity, or a
negative workload is treated as an `invalid_work` trigger failure before any
scaling arithmetic occurs.

## Alternatives Considered

- **Always hold** — safe default but not configurable; availability-sensitive
  services would never scale up under metric source failure.
- **Always scale to max** — maximally available but can be extremely expensive
  for batch workloads.
- **Configurable numeric target** — more granular but harder to express as a
  label value and harder to reason about in an incident.
- **Separate per-trigger failsafe** — considered (e.g., a second trigger as a
  fallback source); out of scope for MVP; could be added as a
  `trigger.fallback.*` label group later.

## Consequences

- Operators must explicitly set `com.deda.autoscale.failsafe=max` or `min` for
  services where the default `hold` is unsafe; the default is conservative.
- FailSafe applies to any trigger failure — transient network errors and
  persistent outages are treated identically. A future improvement could add a
  `failsafeAfterConsecutiveFailures` threshold to tolerate brief metric-source
  blips before activating failsafe mode.
- The clamping to `[MinReplicas, MaxReplicas]` means `failsafe=max` with `max=0`
  still results in 0 replicas — operators must set `max` appropriately for their
  safety intent.
