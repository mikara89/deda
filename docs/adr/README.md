# Architecture Decision Records

This directory contains the Architecture Decision Records (ADRs) for DEDA. Each
ADR documents a significant design decision: the context that prompted it, what
was decided, the alternatives considered, and the consequences.

## Format

Each ADR follows the lightweight
[Nygard format](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions):

- **Context** — the problem or constraint that prompted the decision
- **Decision** — what was chosen and how it is implemented
- **Alternatives Considered** — what else was evaluated and why it was rejected
- **Consequences** — trade-offs, known limitations, and what this decision
  enables

## Adding a new ADR

1. Copy the next sequential number (e.g. `0016`).
2. Create `docs/adr/NNNN-short-title.md`.
3. Fill in all four sections.
4. Set **Status** to `Accepted`.
5. Add a row to the index table below.
6. If the new decision supersedes an older one, update the old ADR's status to
   `Superseded by ADR-NNNN`.

---

## Index

| #                                               | Title                                                             | Status   |
| ----------------------------------------------- | ----------------------------------------------------------------- | -------- |
| [0001](0001-ports-and-adapters.md)              | Ports-and-Adapters (Hexagonal) Architecture                       | Accepted |
| [0002](0002-nativeaot-compilation.md)           | .NET NativeAOT Compilation                                        | Accepted |
| [0003](0003-label-based-configuration.md)       | Label-Based Per-Service Configuration                             | Accepted |
| [0004](0004-docker-socket-proxy.md)             | Docker Socket Proxy for Least-Privilege API Access                | Accepted |
| [0005](0005-in-process-kestrel-server.md)       | In-Process Kestrel HTTP Server as a Hosted Service                | Superseded by 0020 |
| [0006](0006-hand-rolled-metrics-registry.md)    | Hand-Rolled In-Process Prometheus Metrics Registry                | Superseded by 0020 |
| [0007](0007-in-memory-state-store.md)           | In-Memory Ephemeral State Store (MVP)                             | Accepted |
| [0008](0008-optimistic-concurrency-retry.md)    | Optimistic Concurrency with Exponential Backoff for Swarm Updates | Accepted |
| [0009](0009-credentials-env-or-secrets-file.md) | Credentials via Environment Variable or Docker Secrets File       | Accepted |
| [0010](0010-round-robin-paging.md)              | Round-Robin Paging for Large Service Fleets                       | Accepted |
| [0011](0011-scale-down-delay-ring-buffer.md)    | Scale-Down Delay Window Using a Ring Buffer                       | Superseded by 0016 |
| [0012](0012-failsafe-modes.md)                  | FailSafe Modes (Hold / Min / Max) on Trigger Failure              | Accepted |
| [0013](0013-optional-leader-elector-seam.md)    | Optional `ILeaderElector` Seam for Future HA                      | Accepted |
| [0014](0014-singleton-http-client-docker.md)    | Singleton `HttpClient` for Docker Engine API                      | Accepted |
| [0015](0015-named-http-clients-for-triggers.md) | Named `IHttpClientFactory` Clients per Trigger Type               | Accepted |
| [0016](0016-timestamped-recommendation-stabilization.md) | Timestamped Desired-Replica Recommendation Stabilization | Accepted |
| [0017](0017-resilient-reconciliation-health.md) | Resilient Reconciliation and Health-Based Readiness | Accepted |
| [0018](0018-strict-trigger-results-and-secret-resolution.md) | Strict Trigger Results and Per-Service Secret Resolution | Accepted |
| [0019](0019-real-swarm-ci-verification.md) | Real Docker Swarm Verification in CI | Accepted |
| [0020](0020-standard-dotnet-opentelemetry.md) | Standard .NET OpenTelemetry | Accepted |
| [0021](0021-reproducible-signed-releases.md) | Reproducible and Signed Release Pipeline | Accepted |
| [0022](0022-redis-ttl-leader-lease.md) | Redis TTL Leader Lease | Accepted |
| [0023](0023-http-trigger-and-bounded-advanced-scaling.md) | HTTP Trigger and Bounded Advanced Scaling | Accepted |
