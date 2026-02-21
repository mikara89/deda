# ADR-0008: Optimistic Concurrency with Exponential Backoff for Swarm Updates

**Date:** 2026-02-21 **Status:** Accepted

## Context

Docker Swarm uses an optimistic concurrency model: every
`POST /services/{id}/update` call must include the current `version` index of
the service spec. If any other actor (a rolling restart, a manual
`docker service scale`, another autoscaler instance) increments the version
between the read and the write, the Engine returns HTTP 400 with
`"update out of sequence"`. Without a retry strategy, the autoscaler silently
drops the desired replica count.

Additionally, patching only the `Replicas` field while sending the rest of the
spec as-is would clobber any concurrent change to other fields (image tag,
environment variables, mount points).

## Decision

`RetryOnVersionConflictUpdateStrategy` wraps
`ISwarmServiceClient.UpdateReplicasAsync` with the following logic:

1. Call `UpdateReplicasAsync`.
2. On detecting a version-conflict exception (message contains
   `"version conflict"` or `"update out of sequence"`): a. Re-fetch the full
   service spec via `GetServiceAsync` to obtain a fresh `VersionIndex`. b. Wait
   for `baseDelay * 2^attempt ± 20% jitter` (base 150 ms, max 2 s). c. Retry
   with the new version index.
3. Give up after 6 attempts and propagate the exception, which is caught by
   `AutoscalerController` and recorded via `IAutoscalerTelemetry`.

`DockerEngineSwarmServiceClient.UpdateReplicasAsync` always fetches the full raw
service spec via `GET /services/{id}` before writing, patches only
`Spec.Mode.Replicated.Replicas`, and sends the complete object back. This
prevents clobbering unrelated spec fields.

Default parameters: 6 attempts, base delay 150 ms, max delay 2 s, ±20% jitter
multiplier.

## Alternatives Considered

- **Fire-and-forget (no retry)** — version conflicts under concurrent operations
  silently lose scale events; unacceptable for a control loop.
- **Pessimistic locking (conditional request headers)** — not supported by the
  Docker Engine API.
- **Fixed delay retry** — no jitter means multiple DEDA replicas (or concurrent
  reconcile cycles) would retry in lockstep, amplifying contention.
- **Immediate re-read + retry (no delay)** — thundering herd under high update
  frequency; backoff is strictly safer.

## Consequences

- Under normal single-instance operation, retries are rare (version conflict
  only occurs on truly concurrent updates).
- Under HA operation (two DEDA instances before leader election is implemented),
  retries will be frequent; this is an acceptable degraded-mode behaviour until
  [ADR-0013](0013-optional-leader-elector-seam.md) is implemented.
- The retry count and delay parameters are constants in
  `RetryOnVersionConflictUpdateStrategy`; they could be made configurable via
  `DedaHostOptions` in the future without interface changes.
- Fetching the full spec on every update adds one extra Docker API call per
  scale event; this is negligible compared to the poll cycle cost.
