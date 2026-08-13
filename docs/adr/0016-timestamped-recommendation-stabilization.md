# ADR-0016: Timestamped Desired-Replica Recommendation Stabilization

**Date:** 2026-08-13 **Status:** Accepted; amended by ADR-0023

## Context

ADR-0011 based scale-down eligibility on a fixed 60-entry ring buffer of raw
work samples. Every sample had to be at or below `activationThreshold`. This
coupled proportional downscaling to the scale-to-min threshold and made windows
requiring more than 60 polls impossible. It also used the service-level
`pollSeconds` label even though only the global `DEDA_POLL_SECONDS` interval
controls reconciliation.

For example, 50 work units at a target of 10 correctly recommends five
replicas. A service at ten replicas must eventually reach five even when 50 is
well above its activation threshold.

## Decision

For each valid trigger result, `SimpleScalePolicyMvp` calculates and bounds the
desired replica count before recording a `ScaleRecommendation` containing that
count and the observation timestamp. Recommendations older than
`scaleDownDelaySeconds` are removed by elapsed time.

Scale-up remains immediate, subject to `StepUp`. For scale-down, the policy uses
the maximum desired-replica recommendation retained in the window, capped at
the current replica count, before applying `StepDown`. A zero-second window
retains only the current recommendation and therefore disables stabilization.

`activationThreshold` only identifies inactive or near-zero work and recommends
`MinReplicas`; it does not determine whether proportional downscale is allowed.

The public `ScaleConfig.PollSeconds` property and corresponding label are kept
as deprecated compatibility surfaces, but the label is ignored and the value
does not participate in scaling. `DEDA_POLL_SECONDS` remains the sole
authoritative reconciliation interval.

Work values must be finite and non-negative. Invalid nominally successful
trigger results are converted to trigger failures and follow the existing
per-service fail-safe policy without adding a recommendation.

## Alternatives Considered

- **Dynamically size the raw-work ring buffer** — removes the 60-sample ceiling
  but retains the incorrect activation-threshold gate and poll-count coupling.
- **Require all recommendations to remain low for a complete window** — delays
  downscale after startup even when no higher recommendation has been observed,
  and is less responsive than recommendation stabilization.
- **Persist recommendation history externally** — would survive restarts and
  support multiple controllers, but adds operational state outside this PR's
  single-instance scope.
- **Implement per-service scheduling** — resolves the label mismatch but adds a
  scheduler and changes reconciliation semantics beyond scaling correctness.

## Consequences

- Proportional downscales are independent of `activationThreshold`.
- Higher recent recommendations conservatively delay downscale and naturally
  expire, allowing progress such as `10 → 8 → 6 → 5`.
- Long stabilization windows are supported without a fixed sample limit.
- Memory use depends on reconcile frequency and window length because all
  in-window recommendations are retained.
- Restarting DEDA clears recommendation history, so the first post-restart
  downscale may occur without the full historical stabilization context.
- Per-service `pollSeconds` remains accepted but has no effect until a future
  scheduling design explicitly replaces the deprecated label behavior.

This decision supersedes [ADR-0011](0011-scale-down-delay-ring-buffer.md).
