# ADR-0001: Ports-and-Adapters (Hexagonal) Architecture

**Date:** 2026-02-21 **Status:** Accepted

## Context

The autoscaler must support multiple interchangeable backends: different trigger
sources (RabbitMQ, Prometheus, future custom adapters), multiple scaling-policy
algorithms, different secret providers, and optional HA leader election.
Coupling any of these directly into the controller logic would make the system
untestable in isolation and closed to extension.

## Decision

All cross-cutting collaborations are expressed as small, single-purpose
interfaces defined in `Deda.Core` and owned by the domain — never by an adapter
or infrastructure project. The interfaces are:

| Interface                                     | Role                                            |
| --------------------------------------------- | ----------------------------------------------- |
| `ISwarmServiceClient`                         | Read services and apply replica changes         |
| `IScaleConfigProvider`                        | Read per-service autoscale configuration        |
| `ITriggerAdapter` / `ITriggerAdapterRegistry` | Poll external metric sources                    |
| `IScalePolicy`                                | Compute desired replica count from trigger data |
| `IStateStore<TKey, TValue>`                   | Persist per-service mutable state across cycles |
| `IAutoscalerTelemetry`                        | Emit decisions and errors                       |
| `ILeaderElector`                              | Optional HA coordination                        |
| `IServiceUpdateStrategy`                      | Apply updates with retry/concurrency semantics  |

`AutoscalerController` is wired exclusively against these interfaces; it holds
zero references to any concrete implementation type. All concrete
implementations live in separate projects (`Deda.Swarm`, `Deda.Triggers.*`,
`Deda.Policies`, etc.) and are wired together only in `Deda.Host`.

## Alternatives Considered

- **Base class inheritance** — tightly couples the core to a class hierarchy;
  each new backend requires subclassing.
- **Event/delegate callbacks** — functional but informally documented;
  interfaces are more explicit about contracts and discoverable by static
  analysis.
- **Monolithic single class** — used in early sketches; abandoned immediately
  because it made unit testing impossible without spinning up Docker and
  RabbitMQ.

## Consequences

- Each port can be unit-tested with a mock/fake without any infrastructure
  dependency.
- New trigger types, policies, or update strategies are added by implementing
  one interface and registering it in `Deda.Host` — zero changes to `Deda.Core`
  or `Deda.Controller`.
- The `Deda.Core` project has no external NuGet dependencies, keeping the domain
  model stable and portable.
- Contributors must understand the port-adapter split: business logic belongs in
  `Deda.Core` or `Deda.Policies`; IO belongs in adapter projects.
