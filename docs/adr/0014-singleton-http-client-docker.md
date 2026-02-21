# ADR-0014: Singleton `HttpClient` for Docker Engine API

**Date:** 2026-02-21 **Status:** Accepted

## Context

Communicating with the Docker Engine over a Unix domain socket requires a custom
`SocketsHttpHandler` with a `ConnectCallback` that opens a
`UnixDomainSocketEndPoint` connection. Creating a new `HttpClient` per request —
or using `IHttpClientFactory` with its handler-lifetime recycling — would close
and reopen the Unix socket on every request or every handler rotation cycle,
causing connection errors and increased latency.

## Decision

`DockerEndpoint.CreateHttpClientFromEnvironment()` creates a single `HttpClient`
with a `SocketsHttpHandler` configured to connect via Unix socket (or
TCP/HTTP/HTTPS for remote Docker endpoints). This instance is registered as a
singleton in `Program.cs` and injected directly into
`DockerEngineSwarmServiceClient`.

The `DOCKER_HOST` environment variable is checked at startup. Supported schemes:

| Scheme              | Transport                                                  |
| ------------------- | ---------------------------------------------------------- |
| `unix://`           | Unix domain socket (Linux default: `/var/run/docker.sock`) |
| `tcp://`, `http://` | Plain TCP (used with docker-socket-proxy)                  |
| `https://`          | TLS TCP                                                    |
| `npipe://`          | **Not supported** — throws `NotSupportedException`         |

`npipe://` is explicitly rejected because the `NamedPipeClientStream` p/invoke
code required on Windows is not compatible with the NativeAOT Linux target (see
[ADR-0002](0002-nativeaot-compilation.md)).

## Alternatives Considered

- **Named `HttpClient` via `IHttpClientFactory`** — the factory recycles
  handlers on a configurable timer (default 2 minutes), which closes the Unix
  socket mid-stream; not suitable for a persistent socket connection.
- **Per-request `new HttpClient()`** — leads to socket exhaustion under high
  reconcile frequency; the underlying `SocketsHttpHandler` is not disposed
  promptly, leaving TIME_WAIT connections.
- **gRPC / Docker SDK** — the official Docker .NET SDK exists but adds a large
  transitive dependency and has AOT compatibility caveats; the Docker Engine
  REST API is straightforward enough to call directly.

## Consequences

- The singleton `HttpClient` lives for the entire process lifetime; Docker
  Engine TCP keep-alive handles connection maintenance.
- If the Docker socket path changes at runtime (e.g., context switch), DEDA must
  be restarted — the endpoint is resolved once at startup.
- When `DOCKER_HOST` is not set, the default `unix:///var/run/docker.sock` is
  used; this is the correct default for Linux Swarm manager nodes.
- The `http://` scheme (used by docker-socket-proxy on port 2375) is treated as
  plain TCP with a `http://` base address — no TLS, which is intentional for
  overlay-network-local communication.
