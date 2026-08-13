# v0.2 multi-node qualification

Run this release gate against a three-node Swarm (two managers and one worker) with Redis, Prometheus, RabbitMQ, and two DEDA replicas. Record the image digest, configuration, timestamps, and metrics for each case.

1. Scale a replicated workload `1 → 10 → 1` and confirm work lands across nodes.
2. Kill the active DEDA task; confirm the standby takes leadership after the lease interval and resumes scaling.
3. Stop Redis; both instances must report readiness `503` and no service update may occur. Restore Redis and confirm recovery.
4. Introduce concurrent `docker service scale` changes during a DEDA update; confirm optimistic retries preserve the service spec.
5. Add an invalid label; the affected service must be skipped while valid services continue.
6. Exercise scale-to-zero through trigger failure, grace reset, zero, and recovery from zero.
7. Restart both DEDA tasks and document the expected in-memory stabilization-state reset.

This is a release qualification runbook rather than a CI claim: it requires real multi-node infrastructure and should be attached to the release evidence before `v0.2.0` is tagged.
