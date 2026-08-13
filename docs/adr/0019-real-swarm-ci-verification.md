# ADR-0019: Real Docker Swarm Verification in CI

**Date:** 2026-08-13 **Status:** Accepted

## Context

Label-provider tests called integration tests did not exercise Docker Engine,
Swarm service specs, optimistic version indexes, published trigger endpoints,
or the complete controller/adapter/update path. Unit tests cannot prove that the
Docker API DTOs and real Swarm behavior agree.

## Decision

CI has a dedicated `swarm-integration` job after unit tests. It initializes a
single-node Swarm, deploys contract services, Prometheus, and RabbitMQ, and runs:

1. `Deda.Swarm.Tests` against the manager socket to verify discovery, service
   labels, replicated/global mode mapping, replica updates, and global-mode
   rejection.
2. The DEDA host against real labeled worker services.
3. Prometheus `vector(100)` scale-up followed by `vector(0)` scale-down.
4. RabbitMQ queue publishing scale-up followed by queue purge scale-down.

The shell harness uses bounded waits, emits DEDA diagnostics on failure, and
always removes services and leaves the test swarm. Real tests are opt-in outside
CI through `DEDA_SWARM_TESTS=1` so ordinary unit-test runs do not require Docker.

## Alternatives Considered

- **Mock Docker HTTP responses only** — fast but cannot catch daemon contract or
  Swarm update behavior changes.
- **Run all tests against Docker** — makes local development and fast CI feedback
  depend on a daemon and registry access.
- **Docker Compose** — does not expose Swarm service modes, versions, or service
  update semantics.

## Consequences

- CI proves the primary RabbitMQ and Prometheus user journeys on a real manager.
- The integration job downloads container images and is slower and more
  susceptible to external registry availability than unit tests.
- Docker daemon interruption is not simulated because restarting the hosted
  runner daemon would destabilize the job; controller-level outage/recovery is
  covered deterministically in `Deda.Controller.Tests`.
