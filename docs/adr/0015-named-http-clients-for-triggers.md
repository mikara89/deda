# ADR-0015: Named `IHttpClientFactory` Clients per Trigger Type

**Date:** 2026-02-21 **Status:** Accepted

## Context

Trigger adapters (RabbitMQ management API, Prometheus query API, and generic
HTTP metric API) each issue
outbound HTTP calls to external services. They need:

- Their own timeout policy (different from the Docker Engine client — see
  [ADR-0014](0014-singleton-http-client-docker.md)).
- Handler lifetime management (connections to external services should be
  recycled, unlike the persistent Docker socket).
- The ability to add per-trigger retry policies or headers in the future without
  touching core code.

They must not share the singleton Docker Engine `HttpClient`.

## Decision

`Program.cs` registers three named `HttpClient` instances via
`builder.Services.AddHttpClient(...)`:

```csharp
builder.Services.AddHttpClient("rabbitmq")
    .ConfigureHttpClient(c => c.Timeout = TimeSpan.FromSeconds(opts.DefaultHttpTimeoutSeconds));

builder.Services.AddHttpClient("prometheus")
    .ConfigureHttpClient(c => c.Timeout = TimeSpan.FromSeconds(opts.DefaultHttpTimeoutSeconds));

builder.Services.AddHttpClient("http")
    .ConfigureHttpClient(c => c.Timeout = TimeSpan.FromSeconds(opts.DefaultHttpTimeoutSeconds));
```

Each trigger adapter receives `IHttpClientFactory` and calls
`_httpClientFactory.CreateClient("rabbitmq")`, `CreateClient("prometheus")`, or
`CreateClient("http")` to obtain its client. The timeout can also be overridden per-service via
`trigger.timeoutSeconds` in the service label, which sets `client.Timeout` after
creation.

The named-client baseline is driven by
`DedaHostOptions.DefaultHttpTimeoutSeconds` (env var
`DEDA_HTTP_TIMEOUT_SECONDS`, default 5 s, range 1–120 s). Current adapters set
`client.Timeout` after creation to the service value or their own 5-second
fallback, so the current fallback remains 5 seconds even when the global
baseline is changed. Prometheus and HTTP overrides are capped at 120 seconds;
RabbitMQ accepts any positive integer representable by `TimeSpan`.

## Alternatives Considered

- **Shared singleton `HttpClient` for all triggers** — different timeout
  requirements for RabbitMQ and Prometheus make a single shared timeout a poor
  fit; also intermingles connection pools for unrelated backends.
- **`new HttpClient()` per adapter instance** — bypasses `IHttpClientFactory`'s
  handler lifetime management, leading to DNS staleness and socket exhaustion
  over time.
- **Per-trigger singleton `HttpClient`** — equivalent to named factory clients
  but bypasses the DI lifetime management and is harder to extend with Polly
  policies later.

## Consequences

- Adding a new trigger type requires registering a new named client in
  `Program.cs` and calling `CreateClient("<name>")` in the adapter — a two-line
  change.
- `IHttpClientFactory` recycles `HttpMessageHandler` instances on a 2-minute
  default interval, ensuring DNS changes to trigger endpoints are picked up
  without a DEDA restart.
- Polly retry or circuit-breaker policies can be added per named client in
  `Program.cs` without touching trigger adapter code — a clean extension point
  for v1.0.0.
- `trigger.timeoutSeconds` is the effective request timeout. The named-client
  baseline is currently overwritten by each adapter; making the global setting
  the shared fallback would require passing it into adapter configuration.
