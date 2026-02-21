# ADR-0013: Optional `ILeaderElector` Seam for Future HA

**Date:** 2026-02-21 **Status:** Accepted

## Context

Running multiple DEDA replicas for high availability creates the risk of
concurrent, conflicting scale decisions: two instances could read the same
service state, compute the same desired replica count, and race to apply it —
triggering version conflicts (see
[ADR-0008](0008-optimistic-concurrency-retry.md)) on every cycle. A
leader-election mechanism is needed, but implementing one for MVP adds
operational complexity before the core autoscaling logic has been validated.

## Decision

`ILeaderElector` is defined in `Deda.Core` with a single method:

```csharp
Task<bool> IsLeaderAsync(CancellationToken ct);
```

It is injected into `AutoscalerController` as a **nullable optional**
constructor parameter (`ILeaderElector? leader = null`). When null — which is
the current wiring in `Program.cs` — the controller skips the check and always
acts as leader. When a concrete implementation is registered, the controller
calls `IsLeaderAsync` at the start of every reconcile cycle and returns
immediately if it is not the leader.

The `Deda.HA` project exists as a placeholder that will contain at least one
`ILeaderElector` implementation. The two candidate approaches are documented in
[src/Deda.HA/README.md](../../src/Deda.HA/README.md).

For MVP, the recommended deployment is `replicas: 1` for the DEDA service, which
guarantees at-most-one active instance via Swarm's own restart policy.

## Alternatives Considered

- **Omit the interface for MVP** — simpler now, but would require a breaking
  refactor to `AutoscalerController` when HA is needed; the interface costs
  nothing to define.
- **Deploy leader election from day one** — adds Consul/etcd or Swarm locking
  complexity before the core algorithm is validated in production; deferred
  deliberately.
- **Rely solely on Swarm `replicas: 1`** — effectively single-instance HA with
  Swarm's restart policy as the failover mechanism; documented as the supported
  production configuration until `Deda.HA` is implemented.

## Consequences

- Running more than one DEDA replica today will function (the retry strategy
  handles version conflicts gracefully) but is wasteful and produces more Swarm
  API traffic. It is not recommended.
- The `ILeaderElector` nullable check is the only HA-related code in the
  critical path; removing the null check to require an implementation is a
  one-line change once `Deda.HA` ships.
- A startup warning when `ILeaderElector` is null is tracked in the v1.0.0
  roadmap, so operators are informed they are running without coordinated HA.
