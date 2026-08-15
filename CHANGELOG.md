# Changelog

All notable changes to DEDA are documented here. Releases follow
[Semantic Versioning](https://semver.org/) and this file follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

v0.3.0 release-candidate content. Tag `v0.3.0-rc.1` is a prerelease; it is not
v0.3.0 final. Promotion requires `releaseQualification` PASS, then aliasing the
**same** qualified `sha256` digest to `v0.3.0`. Tagging `v0.3.0` rebuilds a new
unverified image and is not the promotion path. See
[v0.3 CI runner qualification](docs/qualification/ci-runners-v0.3.md).

### Added

- GitHub Actions, Azure Pipelines, and GitLab CI queue triggers that observe
  compatible provider work and scale a Swarm runner service.
- Generic CI trigger abstraction shared by the three providers, including
  observation caching (`refreshSeconds`) and fail-safe hold on API or semantic
  failure.
- Capacity model `required capacity = queued jobs + active jobs`. Queue-only
  scaling is unsafe for ephemeral runners: once every runner has claimed work
  the queue is empty, so a queue-only controller would scale the service down
  while jobs are still running.
- CI telemetry for queued jobs, active jobs, required capacity, observation
  age, and provider API request volume.
- Deterministic v0.3 qualification harness (fast and full) plus an explicit
  opt-in real-provider path that stays `NOT_RUN` unless
  `--confirm-real-provider-tests` is supplied.
- Production Swarm runner examples with separate queue-observer and runner
  registration credentials.

### Changed

- Lifecycle cleanup, HA failover continuity, and active-job-safe downscaling
  for CI runner services. DEDA only changes desired replica count; runner
  images own registration, deregistration, graceful drain, and local cleanup.
- Runner examples use a 30-minute stop grace and job-aware drain so Swarm can
  remove a busy task without abandoning the in-flight job.

### Security

- Credential policy bindings separate observer tokens from runner registration
  tokens. Tokens are Docker secrets, never service labels.
- `allowedHosts` is mandatory and fail-closed so a label cannot redirect a
  token to an unexpected host.
- GitHub Actions remain pinned to immutable commit SHAs. Qualification plans
  must pin DEDA and all three runner images by `sha256` digest before both the
  full deterministic run and the real-provider run, never `latest` or a
  mutable tag such as `v0.3`.
- Image publish sets `flavor: latest=false` so a prerelease tag cannot move
  `latest`; `latest` is applied only from `main`.

## v0.2.0 - 2026-08-14

### Changed

- Reorganized user documentation into a five-minute start, task-oriented
  guides, full configuration reference, production guidance, troubleshooting,
  and independently documented Swarm examples.

### Added

- Resilient reconciliation with health-based readiness and bounded backoff.
- Strict Prometheus and RabbitMQ trigger validation with per-service secret resolution.
- Real Docker Swarm integration scenarios for discovery and scale decisions.
- OpenTelemetry metrics and traces with Prometheus and optional OTLP export.
- Multi-architecture container publishing, NativeAOT CLI release artifacts, SBOMs,
  provenance attestations, vulnerability scanning, and signed release images.
- Optional active/standby operation using a fail-closed Redis TTL leader lease.
- Generic HTTP scalar metrics, scale-to-zero grace, and efficient bounded
  recommendation history.
- Operator-owned RabbitMQ credential bindings, per-attempt HA mutation guards,
  lifecycle telemetry cleanup, bounded reconciliation, cycle timeouts, and
  readiness freshness.
- Direct Docker socket rendering through
  `docker deda install --docker-access direct`.

### Security

- GitHub Actions are pinned to immutable commit SHAs.
- Example socket-proxy images are pinned by digest.
- Public image tags are created only after every architecture digest passes the
  vulnerability gate; release signatures target the verified manifest digest.

### Fixed

- Fail closed on malformed explicit autoscaling labels and invalid failsafe values.
- Trigger failures reset scale-to-zero inactivity evidence before the next
  valid zero observation starts a new grace window.
- Redis leader-store outages now make reconciliation readiness unhealthy rather
  than appearing as a healthy standby.
- Current replicas, desired replicas, and trigger value use observable gauges
  instead of histograms.
