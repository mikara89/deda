# Deda.Observability — Structured Telemetry (Not Yet Implemented)

This project is a **planned stub**. It will replace the current
`ConsoleTelemetryMvp` with a proper OpenTelemetry-based implementation of
`IAutoscalerTelemetry`.

## Planned behaviour

- Emit structured **metrics** (scale events, replica counts, trigger values) via
  OpenTelemetry SDK.
- Emit **distributed traces** covering the reconciliation loop and trigger
  calls.
- Export to any OTLP-compatible backend (Prometheus, Grafana, Jaeger, etc.).

## Contributing

If you are interested in implementing this, open an issue to discuss the
approach before starting. See [CONTRIBUTING.md](../../CONTRIBUTING.md) for
general guidelines. The `IAutoscalerTelemetry` interface is defined in
`Deda.Core`.
