# Changelog

All notable changes to DEDA are documented here. Releases follow
[Semantic Versioning](https://semver.org/) and this file follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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

### Security

- GitHub Actions are pinned to immutable commit SHAs.
- Example socket-proxy images are pinned by digest.
