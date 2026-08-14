# v0.2 multi-node qualification

Run this release gate against a three-node Swarm with **three managers**, Redis, Prometheus, RabbitMQ, and two DEDA replicas. Three managers are intentional: a two-manager Swarm cannot lose a manager and retain Raft quorum. Record the image digest, configuration, timestamps, and metrics for each case.

1. Scale a replicated workload `1 → 10 → 1` and confirm work lands across nodes.
2. Kill the active DEDA task; confirm the standby takes leadership after the lease interval and resumes scaling.
3. Stop Redis; both instances must report readiness `503` and no service update may occur. Restore Redis and confirm recovery.
4. Introduce repeated harmless service-spec version churn during a DEDA-requested update; confirm optimistic retries reach the requested replica count and preserve unrelated spec fields.
5. Add an invalid label; the affected service must be skipped while valid services continue.
6. Exercise scale-to-zero through trigger failure, grace reset, zero, and recovery from zero.
7. Restart both DEDA tasks and document the expected in-memory stabilization-state reset.

The executable Hetzner Cloud harness is in [tests/qualification/v0.2/hetzner](../../tests/qualification/v0.2/hetzner/README.md). It provisions a labelled, ephemeral private-network Swarm in a Spread Placement Group; SSH is CIDR-restricted and no control-plane services are publicly published.

It also covers a controlled one-manager Swarm failure and a direct-Docker-socket smoke test, then has an optional persistent 24-hour soak mode. This is release qualification infrastructure, not PR CI: it requires real multi-node infrastructure and should be attached to the release evidence before `v0.2.0` is tagged. A harness implementation or dry run is never by itself a release PASS.
