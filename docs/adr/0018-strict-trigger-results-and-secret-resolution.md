# ADR-0018: Strict Trigger Results and Per-Service Secret Resolution

**Date:** 2026-08-13 **Status:** Accepted

## Context

Prometheus instant queries can return scalar, vector, matrix, or string results.
Selecting the first vector entry silently makes scaling depend on response order
when a query returns multiple series. Trigger adapters also caught requested
cancellation as ordinary failure, delaying clean shutdown. RabbitMQ credentials
were process-wide even when scaled services used different brokers or tenants.

## Decision

The Prometheus adapter accepts only scalar results or vectors containing exactly
one series. An empty vector is zero work. Multiple vector series and unsupported
result types fail explicitly. Parsed values still pass through the shared
finite, non-negative `TriggerResult` validation.

RabbitMQ and Prometheus rethrow `OperationCanceledException` when the caller's
token requested cancellation. Timeout cancellation not initiated by that token
remains a trigger failure and follows the configured fail-safe policy.

RabbitMQ supports `trigger.credentialsSecret`, whose value is a Docker secret
file name. `ISecretResolver` separates secret lookup from credential parsing;
`DockerSecretFileResolver` resolves only single-file names under
`DEDA_SECRETS_DIRECTORY`. Secret contents use `username:password`, splitting on
the first colon so passwords may contain colons. Services without the label use
the existing global environment or file credentials.

## Alternatives Considered

- **Sum all Prometheus vector series** — may be valid for some workloads but is
  an implicit aggregation policy; operators should express aggregation in
  PromQL.
- **Keep selecting the first series** — response ordering is not a scaling
  contract and can produce nondeterministic decisions.
- **Put per-service credentials directly in labels** — exposes secrets through
  Docker inspection and is rejected.
- **Read arbitrary label-provided paths** — enables directory traversal and
  makes the DEDA container filesystem part of service configuration.

## Consequences

- Ambiguous Prometheus queries fail safely and must be made scalar or
  single-series by the operator.
- Shutdown cancellation is prompt and does not activate fail-safe scaling.
- Per-service RabbitMQ credentials rotate with mounted secret contents without a
  DEDA restart.
- Every referenced secret must be mounted into the DEDA service explicitly.
