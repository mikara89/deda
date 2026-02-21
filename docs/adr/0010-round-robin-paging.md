# ADR-0010: Round-Robin Paging for Large Service Fleets

**Date:** 2026-02-21 **Status:** Accepted

## Context

When a Swarm cluster has hundreds of services, a single reconcile cycle that
iterates all of them sequentially can exceed the configured poll interval. This
would cause the cycle to "stack" (each cycle starts before the previous one
finishes), starve later services of their reconcile slot, and make cycle
duration unbounded. Simply truncating the list to the first N services would
permanently ignore the rest.

## Decision

`AutoscalerController.ReconcileOnceAsync` implements time-bucketed round-robin
paging when `DEDA_MAX_SERVICES_PER_CYCLE > 0`:

1. **Stable sort** (when `DEDA_JITTER_ENABLED=true`): the service list is sorted
   by `StableHash(serviceId)` — a deterministic hash of the service ID string.
   This ensures that "page 0" always contains the same set of services
   regardless of the order returned by the Docker API.

2. **Time-bucket selection**: a bucket index is computed as
   `bucket = unixSeconds / pollSeconds`. The starting index for this cycle is
   `start = (bucket * maxServicesPerCycle) % serviceCount`. This advances the
   window by exactly one page per poll cycle, visiting every service in
   round-robin order.

3. **Wrap-around slice**: `TakeWrap` slices `maxServicesPerCycle` entries
   starting at `start`, wrapping around the end of the list so the last page
   includes services from the beginning if needed.

When `DEDA_MAX_SERVICES_PER_CYCLE = 0` (the default), paging is disabled and all
services are processed every cycle.

## Alternatives Considered

- **Process all services every cycle** — acceptable for small fleets; unbounded
  cycle time for large ones; the default remains "all services" because most
  deployments are small.
- **Random subset** — stochastic; some services could be skipped for extended
  periods by chance; deterministic round-robin is more predictable and
  auditable.
- **Queue-based scheduling** — introduces stateful ordering that complicates the
  in-memory store and makes the controller harder to reason about.
- **Fixed truncation (first N)** — permanently ignores high-index services;
  unacceptable.

## Consequences

- With `maxServicesPerCycle = M` and `count = C` services, every service is
  visited once every `ceil(C / M)` cycles.
- The stable-hash sort means the paging order is consistent across container
  restarts — a recreated DEDA container continues from the "same" page it would
  have been on.
- `DEDA_MAX_SERVICES_PER_CYCLE = 0` (default) means no cap; operators managing
  large fleets should tune this based on their average per-service reconcile
  latency.
- The time-bucket calculation uses wall-clock seconds; if the host clock skips
  (NTP correction), the bucket index may jump, potentially repeating or skipping
  a page once. This is accepted as a negligible edge case.
