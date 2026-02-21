# ADR-0002: .NET NativeAOT Compilation

**Date:** 2026-02-21 **Status:** Accepted

## Context

DEDA runs as a sidecar daemon alongside a Docker Swarm cluster. A sidecar should
have the smallest possible memory footprint, start in milliseconds (not
seconds), and not carry a JIT compiler into production. The standard .NET
runtime image is ~200 MB and introduces JIT warm-up latency on a freshly
scheduled container.

## Decision

The `Deda.Host` project is published with:

```xml
<PublishAot>true</PublishAot>
<SelfContained>true</SelfContained>
<StripSymbols>true</StripSymbols>
<InvariantGlobalization>true</InvariantGlobalization>
```

The final Docker image is based on `mcr.microsoft.com/dotnet/runtime-deps`
(native OS dependencies only, ~10 MB). The multi-stage Dockerfile installs
`clang` and `zlib1g-dev` in the build stage as required by the NativeAOT
toolchain.

All JSON serializers use `[JsonSerializable]` source-generated contexts
(`DockerEngineJsonContext`, `PrometheusJsonContext`) to satisfy AOT's
no-reflection constraint. No `JsonSerializer` reflection-based calls exist
anywhere in the codebase.

The `npipe://` (Windows named pipe) Docker host scheme is explicitly rejected in
`DockerEndpoint.cs` with a `NotSupportedException`, because the named-pipe
p/invoke code needed for `NamedPipeClientStream` is not compatible with the
NativeAOT Linux target.

## Alternatives Considered

- **Standard JIT runtime** — viable, but the final image would be ~200 MB and
  cold-start latency increases.
- **ReadyToRun (R2R)** — partially ahead-of-time compiled, still falls back to
  JIT at edges; does not eliminate the runtime dependency.
- **Trimmed self-contained (non-AOT)** — reduces image size but still carries
  the runtime and JIT; ~80 MB.
- **Go / Rust rewrite** — native by default; rejected because the team uses .NET
  and the ports-and-adapters model is well-served by C# interfaces and DI.

## Consequences

- Final image is self-contained and <20 MB, making it suitable as a Swarm
  sidecar.
- All new JSON serialization must use source-generated contexts —
  reflection-based `JsonSerializer.Serialize<T>(obj)` will fail at runtime if
  `T` is not registered.
- Libraries that rely on `System.Reflection.Emit` or dynamic code generation
  (e.g., most ORM and serialization libraries) cannot be used.
- NativeAOT trim warnings during build must be treated as errors; contributors
  should run `dotnet publish` locally and resolve any new warnings before
  merging.
- Windows debugging is possible with the standard `dotnet run` path (JIT); AOT
  is only exercised in the published Linux container.
