# ADR-0017: Resilient Reconciliation and Health-Based Readiness

**Date:** 2026-08-13 **Status:** Accepted

## Context

A Docker API failure during top-level service discovery escaped the worker loop
and could terminate the autoscaler. The readiness probe independently queried
Docker but was not invoked by the worker, so it did not represent whether real
reconciliation had succeeded. Cancellation thrown while evaluating a service
was also caught as an ordinary service error.

## Decision

`ResilientReconcileRunner` owns the top-level attempt boundary. It records every
attempt through `IReconciliationHealth`, invokes `AutoscalerController`, and:

- records success and resets backoff after a completed reconciliation;
- rethrows requested cancellation without recording a failure;
- records other controller-level failures, keeps the worker alive, and returns
  an exponential retry delay capped by `DEDA_MAX_RECONCILE_BACKOFF_SECONDS`.

`ReconciliationHealthState` is the in-process, thread-safe source for the last
attempt, last success, last failure, last error, and current readiness. The HTTP
readiness endpoint reads this state directly. It starts unready, becomes ready
only after reconciliation succeeds, becomes unready after a later failure, and
recovers automatically after the next success.

Per-service requested cancellation is rethrown. Invalid label configuration and
unknown trigger types remain isolated to their service but are recorded through
`IAutoscalerTelemetry` with explicit stages.

## Alternatives Considered

- **Catch exceptions only in `Worker`** — keeps the process alive but leaves
  retry policy and health transitions coupled to hosting code and harder to unit
  test.
- **Keep an independent Docker readiness probe** — duplicates Docker traffic and
  can disagree with the actual reconciliation path.
- **Exit and rely on Swarm restart policy** — creates unnecessary downtime and
  loses in-memory scaling history during transient manager restarts.

## Consequences

- Docker manager restarts no longer require restarting DEDA.
- Readiness now reflects completed reconciliation attempts rather than a
  separate synthetic check.
- Retry pressure is bounded during persistent controller-level failures.
- Reconciliation health remains in memory and resets to unready when DEDA
  restarts.
- Individual service failures are observable but do not make unrelated services
  unavailable; top-level failures make the controller unready.
