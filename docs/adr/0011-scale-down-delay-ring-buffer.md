# ADR-0011: Scale-Down Delay Window Using a Ring Buffer

**Date:** 2026-02-21 **Status:** Superseded by ADR-0016

> Superseded by [ADR-0016](0016-timestamped-recommendation-stabilization.md),
> which replaces fixed recent-work samples with timestamped desired-replica
> recommendations.

## Context

Autoscalers that scale down immediately on a single low-metric reading cause
"flapping" — rapid up/down cycles that burn Swarm rolling-update capacity,
interrupt in-flight work, and create noisy logs. A cooldown period after a
scale-up event alone is insufficient, because load can drop right before the
cooldown expires and then spike again immediately after scale-down.

## Decision

`ServiceScaleState` holds a `RingBuffer<double>` with capacity 60. On every
successful trigger poll, the work value is appended to the buffer via
`state.RecentWork.Add(trigger.Work)`.

Before allowing a scale-down decision, `SimpleScalePolicyMvp` applies two guards
in sequence:

1. **Cooldown guard**: if `now - lastScaleUpUtc < cooldownSeconds`, the decision
   is stabilised to `current` regardless of the metric value.

2. **Delay-window guard**:
   `requiredSamples = ceil(scaleDownDelaySeconds / pollSeconds)` is computed.
   The last `requiredSamples` entries in the ring buffer must all be ≤
   `activationThreshold`. If the buffer does not yet have enough samples, or any
   recent sample exceeds the threshold, the decision is stabilised to `current`.

`RingBuffer<T>` is a fixed-capacity circular buffer that overwrites the oldest
entry when full. `Snapshot()` returns entries oldest-to-newest in a new
`List<T>`.

Scale-up decisions bypass both guards and are applied immediately (subject only
to `StepUp` clamping and `MaxReplicas`).

## Alternatives Considered

- **Simple timer (cooldown only)** — protects the period immediately after a
  scale-up but ignores whether load has actually remained low for a sustained
  period before scale-down.
- **Moving average threshold** — smoother signal but harder to reason about in
  configuration and in log output. The per-sample threshold comparison is
  directly observable in the decision reason string.
- **Kubernetes HPA stabilisation window** — same concept; implemented here
  natively without importing the HPA algorithm.
- **External time-series store** — would allow longer windows without ring
  buffer capacity limits; out of scope; 60 samples at a 10s poll interval covers
  a 10-minute window, which is sufficient for most workloads.

## Consequences

- The ring buffer capacity is fixed at 60. Maximum observable delay window is
  `60 * pollSeconds`. For a 10s poll interval this is 10 minutes; for a 1s poll
  interval this is 60 seconds. If `scaleDownDelaySeconds / pollSeconds > 60`,
  the required sample count is clamped to whatever the buffer holds, silently
  shortening the effective window. This should be documented as a configuration
  guideline.
- The delay window resets on container restart (see
  [ADR-0007](0007-in-memory-state-store.md)) — services may scale down faster
  than intended after a DEDA restart.
- The reason string attached to each `ScaleDecision` includes `needSamples` and
  `samplesHave` fields, making the guard state fully visible in logs.
