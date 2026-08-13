# ADR-0020: Standard .NET OpenTelemetry

**Date:** 2026-08-13 **Status:** Accepted

## Context

The original metrics registry interpolated labels into metric-name strings,
could not emit canonical metric families, and used `Console.WriteLine` for
operational events. It provided no traces and no standard export path.

## Decision

DEDA uses one ASP.NET Core host for the worker and health/metrics endpoints.
`OpenTelemetryAutoscalerTelemetry` implements the existing telemetry port with:

- structured `ILogger<T>` decisions and errors;
- instruments from `System.Diagnostics.Metrics` under `Deda.Autoscaler`;
- nested `ActivitySource` operations for reconcile, discovery, service
  evaluation, trigger, policy, and update stages;
- the OpenTelemetry Prometheus exporter at `/metrics`;
- optional OTLP metrics and traces when `OTEL_EXPORTER_OTLP_ENDPOINT` is set.

Metric dimensions are restricted to bounded operational fields: service,
trigger type, direction, and result. Error text and scale-reason strings remain
logs or trace status rather than metric labels.

Snapshot measurements use observable, state-backed gauges: trigger value is the
latest successful value per service and trigger, while current and desired
replicas are the latest decision values per service. Durations remain
histograms and cumulative events remain counters.

## Alternatives Considered

- **Repair the custom registry** — could produce valid Prometheus output but
  would continue maintaining an exporter and would not add traces or OTLP.
- **OTLP only** — operationally clean but removes the existing direct
  Prometheus scrape contract.
- **Keep a second internal web host** — separates concerns superficially but
  duplicates hosting lifecycle and prevents one DI-managed telemetry pipeline.

## Consequences

- Metrics conform to the standard .NET/OpenTelemetry pipeline and can be
  exported simultaneously to Prometheus and OTLP.
- Structured log sinks and filtering use ordinary .NET configuration.
- The Prometheus ASP.NET Core exporter package is currently prerelease because
  Prometheus/OpenMetrics compatibility remains experimental upstream; OTLP is
  the preferred production export path.
- OpenTelemetry package compatibility and NativeAOT publishing are verified in
  CI and release gates.

This decision supersedes [ADR-0006](0006-hand-rolled-metrics-registry.md).
