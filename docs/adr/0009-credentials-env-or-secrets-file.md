# ADR-0009: Credentials via Environment Variable or Docker Secrets File

**Date:** 2026-02-21 **Status:** Accepted

## Context

RabbitMQ trigger calls require a username and password for the Management HTTP
API. Credentials must not be hardcoded, must not appear in service labels
(visible via `docker service inspect`), and must work both in local development
(env vars) and in production Swarm deployments (Docker secrets mounted as
files).

## Decision

`EnvOrFileRabbitMqCredentialsProvider` resolves credentials in priority order:

1. **Direct env var** (`RABBITMQ_USER`, `RABBITMQ_PASS`) — used in local
   development and CI.
2. **File path env var** (`RABBITMQ_USER_FILE`, `RABBITMQ_PASS_FILE`) — the
   value is treated as a filesystem path; the file contents are read and
   trimmed. This is the standard Docker secrets pattern: Swarm mounts secrets at
   `/run/secrets/<name>` and the `StackTemplate` sets
   `RABBITMQ_USER_FILE=/run/secrets/rabbitmq_user`.

If neither source is configured, credential resolution fails explicitly before
the HTTP request is sent.

### Per-service credentials

A `trigger.credentialsSecret` label allows individual services to reference a
named Docker secret containing `username:password`. The secret name is resolved
under `DEDA_SECRETS_DIRECTORY` (default `/run/secrets`) and overrides global
credentials for that service's trigger call only. Path separators and traversal
are rejected. See
[README.md per-service credentials](../../README.md#per-service-rabbitmq-credentials)
for the intended design.

## Alternatives Considered

- **Credentials in service labels** — visible in plain text via
  `docker service inspect`; rejected for all production use.
- **Hardcoded default credentials** — never acceptable.
- **Vault / external secrets manager** — valid long-term; adds an operational
  dependency; out of scope for Swarm-native v1 deployment.
- **Per-service label credentials (plain text)** — same visibility concern as
  label-based config; explicitly rejected in favour of the `credentialsSecret`
  name-reference approach.

## Consequences

- Local development works without Docker secrets by setting `RABBITMQ_USER` and
  `RABBITMQ_PASS` env vars.
- Production deployments use `RABBITMQ_USER_FILE` / `RABBITMQ_PASS_FILE`
  pointing to Swarm secrets, so credentials are never visible in
  `docker service inspect` output.
- Services can use independent credentials without exposing credential values in
  Docker service labels; labels contain only mounted secret names.
- File reads happen on every reconcile cycle (credentials are not cached) — this
  ensures secret rotation takes effect without a container restart, at the cost
  of one `File.ReadAllText` call per cycle.
