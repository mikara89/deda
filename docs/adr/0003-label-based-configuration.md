# ADR-0003: Label-Based Per-Service Configuration

**Date:** 2026-02-21 **Status:** Accepted

## Context

Autoscaling configuration must be co-located with the service definition so that
it travels with the service in the Swarm stack YAML, is independently manageable
per service, and requires no separate config file, database, or API call to
activate or update.

## Decision

All autoscaling parameters are stored as Docker Swarm service labels under the
`com.deda.autoscale.*` namespace. `LabelScaleConfigProvider` reads them on every
reconcile cycle directly from the `ServiceRef.Labels` dictionary returned by the
Docker Engine API — there is no caching or out-of-band config store.

The full `com.deda.autoscale.trigger.*` subtree is extracted as a free-form
`IReadOnlyDictionary<string, string>` called `TriggerConfig`. This allows each
trigger adapter to declare and consume its own keys (e.g. `trigger.queue`,
`trigger.query`, `trigger.credentialsSecret`) without any changes to `Deda.Core`
or `LabelScaleConfigProvider`.

Services that do not have `com.deda.autoscale.enabled=true` are silently
skipped; no error is recorded.

## Alternatives Considered

- **ConfigMap / mounted YAML file** — requires volume management and
  synchronisation between the config file and the service definition; two files
  to keep in sync instead of one.
- **Environment variables per target service** — env vars are set on the service
  being scaled, not on DEDA, so they cannot be read by the autoscaler without an
  agent per service.
- **Separate REST API / database on DEDA** — requires an operator to call the
  DEDA API explicitly after every service deployment; breaks GitOps workflows.
- **Annotations on a custom Swarm object** — Docker Swarm has no equivalent of
  Kubernetes CRDs; labels on services are the idiomatic per-service metadata
  mechanism.

## Consequences

- Configuration lives in the same `docker-compose.yml` / stack file as the
  service — a single `git diff` shows both the service change and the
  autoscaling intent.
- Labels are read-only strings; typed parsing (int, double, bool) and validation
  happens in `LabelScaleConfigProvider`. Invalid or out-of-range values fall
  back to defaults or produce a recorded error.
- Label values are visible in plain text via `docker service inspect` — this is
  intentional for non-sensitive configuration. Credentials must never go in
  labels (see [ADR-0009](0009-credentials-env-or-secrets-file.md)).
- Adding a new configuration key requires only a new `GetInt` / `GetDouble` /
  `GetString` call in `LabelScaleConfigProvider` and a corresponding field in
  `ScaleConfig`; both are in separate projects from the adapters that consume
  the value.
