# ADR-0007: In-Memory Ephemeral State Store (MVP)

**Date:** 2026-02-21 **Status:** Accepted

## Context

The autoscaling policy (`SimpleScalePolicyMvp`) requires per-service mutable
state that persists across reconcile cycles: the last scale-up and scale-down
timestamps (for cooldown and delay-window logic) and a rolling window of recent
work samples (for the `scaleDownDelaySeconds` ring buffer). This state cannot be
derived from the Docker Engine API alone on each cycle.

## Decision

`InMemoryStateStoreMvp` stores `ServiceScaleState` objects in a
`ConcurrentDictionary<string, ServiceScaleState>` keyed by service ID. Entries
are created on first access via `GetOrAdd` and removed when a service
disappears. State is held entirely in-process and is lost on container restart.

The generic `IStateStore<TKey, TValue>` interface constrains `TValue` to
`class, new()`, allowing both in-memory and future external-store
implementations to be swapped in `Deda.Host` without touching
`AutoscalerController` or `SimpleScalePolicyMvp`.

## Alternatives Considered

- **Redis** — persistent, shared across multiple DEDA instances (supports HA);
  adds an operational dependency and connection management. Reserved for when HA
  is implemented.
- **SQLite on a volume** — persistent across restarts; requires a mounted volume
  in the Swarm service definition and a migration strategy.
- **Stateless design (re-derive from Swarm state each cycle)** — ignores that
  cooldown and delay-window history cannot be reconstructed from the Docker API;
  would require storing timestamps in service labels (mutating the service spec
  constantly).
- **External KV store (etcd, Consul)** — same concerns as Redis; out of scope
  for MVP.

## Consequences

- A DEDA container restart resets all cooldown timers and scale-down delay
  windows. Services may scale down faster than intended immediately after a
  restart.
- No persistent storage dependency simplifies the Swarm stack definition.
- The `IStateStore<TKey, TValue>` interface is intentionally generic so a
  Redis-backed or etcd-backed implementation can be added as a drop-in
  replacement when HA leader election is implemented (see
  [ADR-0013](0013-optional-leader-elector-seam.md)).
- Memory usage scales linearly with the number of managed services. Each
  `ServiceScaleState` holds a 60-slot `RingBuffer<double>` (~500 bytes); 1000
  services ≈ 500 KB — negligible for the target deployment scale.
