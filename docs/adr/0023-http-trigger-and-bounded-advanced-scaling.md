# ADR-0023: HTTP Trigger and Bounded Advanced Scaling

**Status:** Accepted

## Context

After the production foundation, DEDA needs a low-complexity extension point
for application-specific metrics and safer scale-to-zero behavior. The original
recommendation history also retained every in-window sample in a list and
rescanned the full list each cycle, making high-frequency, long-window settings
unnecessarily expensive.

## Decision

Add an `http` trigger that performs an HTTP(S) GET and reads either a plain
numeric body, a JSON root/`value` property, or a dot-separated `valuePath`.
Responses are limited to 64 KiB, timeouts are capped at 120 seconds, caller
cancellation propagates, and all values use the common finite/non-negative
validation.

Add `scaleToZeroGraceSeconds`. When `min=0`, inactive work must remain inactive
for the configured period before zero can be recommended; active work resets
the timer. Failed or invalid trigger observations also reset the timer because
they are not evidence of continuous inactivity. An explicit `failsafe=min`
decision may still choose zero immediately; it does not preserve inactivity
evidence for a later valid observation. The existing scale-down stabilization
and cooldown policies still apply, so their delays can be cumulative by design.

Recommendation state uses an expiry queue plus a monotonic maximum deque. This
keeps insertion and expiry amortized O(1) and reads the conservative maximum in
O(1). Both scale-down stabilization and scale-to-zero grace are capped at 86,400
seconds to bound per-service state and configuration mistakes.

## Alternatives Considered

- A plugin scripting model is more flexible but expands the security and
  NativeAOT surface substantially.
- Full JSONPath adds another parser and a much broader query language; dotted
  object properties cover the intended scalar metric use case.
- Retaining the list and imposing only a cap bounds memory but still performs a
  full maximum scan on every reconciliation.

## Consequences

- Applications can expose a tiny metric endpoint without deploying Prometheus.
- HTTP endpoints are operator-controlled network dependencies and should be
  authenticated or isolated outside DEDA; credentials must not be placed in
  service labels.
- Scale-to-zero can be deliberately slower than an ordinary downscale.
- Very long windows above one day are rejected instead of creating excessive
  retained state.
