# ADR-0006: Hand-Rolled In-Process Prometheus Metrics Registry

**Date:** 2026-02-21 **Status:** Accepted

## Context

DEDA must expose a `/metrics` endpoint in Prometheus text exposition format.
Most .NET metrics libraries (`prometheus-net`, OpenTelemetry exporters) rely on
`System.Reflection.Emit` or dynamic IL generation that is incompatible with
NativeAOT compilation (see [ADR-0002](0002-nativeaot-compilation.md)).

## Decision

`MetricsRegistry` is a hand-written, zero-dependency implementation using three
`ConcurrentDictionary<string, double>` maps for counters, gauges, and "summary"
values. Metric keys are pre-formatted strings that include the label set inline,
for example:

```
deda_scale_events_total{service="my-worker",direction="up"}
```

`RenderPrometheus()` serialises the dictionaries to Prometheus text format 0.0.4
using a `StringBuilder`, grouping entries by type (`# TYPE counter`,
`# TYPE gauge`).

## Alternatives Considered

- **prometheus-net** — the most widely used .NET Prometheus library; relies on
  reflection and `Emit` internally; incompatible with NativeAOT at the time of
  this decision.
- **OpenTelemetry SDK + Prometheus exporter** — comprehensive but heavyweight;
  same NativeAOT concerns for the exporter; also brings a large transitive
  dependency graph that would need AOT trimming annotations throughout.
- **StatsD / push-based metrics** — would require a StatsD agent running in the
  Swarm network; Prometheus pull is simpler for scraping in a Swarm topology
  where DEDA's IP may change.

## Consequences

- **Known limitation:** Inline label keys mean that iterating counters does not
  produce a canonical Prometheus `MetricFamily` with shared `# HELP` and
  `# TYPE` headers per metric name. Each unique `{name}{labels}` string is an
  independent key. The format is valid for scraping but violates the Prometheus
  data model conventions, making aggregation across label dimensions impractical
  without PromQL workarounds.
- **Roadmap:** Replacing this with a proper `MetricFamily` abstraction (separate
  metric name from label map) is tracked in the v1.0.0 roadmap. The
  `IAutoscalerTelemetry` interface and `MetricsRegistry` are internal to
  `Deda.Host`, so the refactor does not affect any other project.
- The implementation is trivially AOT-compatible and has no third-party
  dependencies.
- Adding a new metric requires only a `_registry.IncrementCounter(...)` or
  `_registry.SetGauge(...)` call — no registration boilerplate.
