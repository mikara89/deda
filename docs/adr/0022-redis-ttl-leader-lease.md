# ADR-0022: Redis TTL Leader Lease

**Status:** Accepted

## Context

Multiple DEDA replicas must not independently apply scaling decisions to the
same Swarm services. The existing `ILeaderElector` port provided the seam but
had no implementation, takeover behavior, or loss-of-leadership guard at the
Docker mutation boundary.

## Decision

When `DEDA_REDIS_CONNECTION` is configured, DEDA uses one Redis key containing
a unique instance owner ID. One Lua operation atomically acquires an absent key
or renews it only when the stored owner matches. The key has a short TTL and is
refreshed by a background heartbeat. Store failures and ownership mismatches
fail closed. A confirmed ownership mismatch is normal standby and returns
`false`; store or transport failures raise `LeaderElectionUnavailableException`
so the reconciliation health state becomes unready instead of reporting a
healthy standby.

The controller confirms the lease before discovery and again immediately before
each replica update. Graceful shutdown deletes the key only when the caller is
still its owner; crashes recover through TTL expiry. Without Redis, DEDA logs an
explicit warning and supports only the documented single-replica deployment.

## Alternatives Considered

- A Swarm service-label lock would make Docker both the controlled system and
  coordination store and would require conflict-prone spec mutations.
- A shared filesystem lock is not portable across Swarm manager nodes.
- Always relying on `replicas: 1` is operationally simple and remains supported,
  but it provides no active/standby process-level coordination.

## Consequences

- Operators can run active/standby DEDA replicas with bounded automatic
  takeover and no long-lived leader state.
- Redis becomes an optional operational dependency and should itself be made
  appropriately available and network-isolated.
- A Redis outage makes `/health/ready` unhealthy and activates bounded
  reconciliation backoff on every configured replica.
- Docker's service-update API has no fencing-token field. Lease confirmation at
  the mutation boundary minimizes stale-leader writes but cannot form a fully
  linearizable fence across every possible network partition.
