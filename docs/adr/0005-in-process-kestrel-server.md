# ADR-0005: In-Process Kestrel HTTP Server as a Hosted Service

**Date:** 2026-02-21 **Status:** Accepted

## Context

DEDA needs to expose three read-only HTTP endpoints:

- `GET /metrics` — Prometheus text format for scraping
- `GET /health/live` — liveness probe for Docker Swarm health-check
- `GET /health/ready` — readiness probe (reconcile loop is running)

These endpoints must be available without running a separate sidecar process or
pulling in the full ASP.NET pipeline.

## Decision

`ApiServerHostedService` implements `IHostedService` and internally builds a
minimal `WebApplication` using `WebApplication.CreateSlimBuilder()` (minimal API
surface, AOT-compatible). It listens on `0.0.0.0:DEDA_HTTP_PORT` (default 8081).
The three endpoints are registered with `MapGet` directly on the
`WebApplication`. The lifecycle is tied to `StartAsync` / `StopAsync` so it
participates cleanly in .NET's `IHost` cancellation and shutdown sequence.

`WebApplication.CreateSlimBuilder()` is used rather than
`WebApplication.CreateBuilder()` to avoid loading MVC, Razor, and other
middleware not needed for three minimal endpoints.

## Alternatives Considered

- **Separate Prometheus exporter sidecar** — extra container to build, deploy,
  and monitor; complicates the stack definition.
- **Full ASP.NET pipeline with `UseEndpoints`** — unnecessary weight for three
  static read-only endpoints; also conflicts slightly with the outer `IHost`
  lifecycle when embedded.
- **Raw `HttpListener` / `TcpListener`** — possible but reimplements Kestrel's
  backpressure, thread management, and graceful shutdown for no benefit.
- **Unix socket for metrics** — simpler isolation but complicates Prometheus
  scrape configuration in Swarm where the scraper runs on a different node.

## Consequences

- The HTTP server runs inside the same process as the reconcile loop, sharing
  memory and lifecycle cleanly.
- `WebApplication.CreateSlimBuilder()` creates a second DI container scope
  inside the hosted service; its logger and config are independent of the outer
  `IHost`. This is a known trade-off accepted for simplicity at MVP; a future
  refactor could expose the outer `IServiceProvider` to the inner builder.
- Port is configurable via `DEDA_HTTP_PORT`; default 8081 avoids clashing with
  common application ports (80, 8080, 443).
- Kestrel's graceful shutdown is triggered by `StopAsync`; in-flight scrape
  requests are drained before the process exits.
