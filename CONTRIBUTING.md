# Contributing to DEDA

Thank you for your interest in contributing! DEDA is an early-stage open source
project and contributions of all kinds are welcome — bug reports, documentation
improvements, new trigger adapters, and code fixes.

---

## Getting Started

### Prerequisites

- [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0)
- Docker (for running the example stack locally)
- A Docker Swarm cluster or single-node `docker swarm init` for end-to-end
  testing

### Run locally

```bash
git clone https://github.com/mikara89/deda.git
cd deda

dotnet restore Deda.sln
dotnet build Deda.sln
dotnet test Deda.sln
```

### Run the example stack

```bash
# Initialise a single-node swarm if you haven't already
docker swarm init

docker stack deploy -c deploy/swarm/deda-stack.yml deda-dev
```

> The example stack uses `admin`/`admin` as RabbitMQ credentials. **Do not use
> these in production.**

---

## Project Structure

```
src/
  Deda.Core/              # Domain models and port interfaces — no external dependencies
  Deda.Controller/        # Main reconciliation loop
  Deda.Swarm/             # Docker Engine HTTP client
  Deda.Config.Labels/     # Label-based config provider
  Deda.Triggers.*/        # Trigger adapters (RabbitMQ, Prometheus, …)
  Deda.Policies/          # Scaling policy logic
  Deda.Updates/           # Swarm update strategy with optimistic concurrency
  Deda.Host/              # Entry point — DI wiring, HTTP server, hosted service
  Deda.HA/                # Stub — HA leader election (not yet implemented)
  Deda.Observability/     # Stub — structured telemetry (not yet implemented)
tests/
  Deda.Core.Tests/        # Unit tests for RingBuffer and domain utilities
  Deda.Controller.Tests/  # Unit tests for scaling policy (SimpleScalePolicyMvp)
  Deda.Integration.Tests/ # Integration tests for label parsing, etc.
```

---

## How to Contribute

### Reporting bugs

Open an issue and include:

- DEDA version / commit SHA
- Docker and Swarm version (`docker version`)
- Relevant service labels
- Log output from the DEDA container (`docker service logs <deda-service>`)

### Submitting a pull request

1. Fork the repository and create a feature branch from `main`.
2. Make your changes. Keep commits focused — one logical change per commit.
3. Add or update tests for any logic you changed.
4. Run the full test suite: `dotnet test Deda.sln`
5. Push your branch and open a pull request against `main`.
6. Describe what the PR changes and why. Reference any related issues.

### Architecture decisions

Before making structural changes, read the
[Architecture Decision Records](docs/adr/README.md). Each ADR explains why a key
design choice was made and what alternatives were considered. If your
contribution involves a significant new decision (new transport, new policy
algorithm, new storage backend), add an ADR as part of the PR.

### Code style

- Follow the existing code conventions (see other files in the project).
- `Deda.Core` must remain free of external dependencies — it defines the ports,
  not the adapters.
- New trigger adapters belong in a new `Deda.Triggers.<Name>` project following
  the pattern of `Deda.Triggers.RabbitMq`.
- NativeAOT compatibility is required for the `Deda.Host` publish path. Use
  `System.Text.Json` source generation (not reflection-based serialisation) for
  any new JSON work.

---

## Good First Issues

The following areas are well-scoped for first contributions:

- **Unit tests** — `Deda.Core.Tests`, `Deda.Controller.Tests`, and
  `Deda.Integration.Tests` all need more coverage.
- **New trigger adapter** — implement `ITriggerAdapter` for HTTP endpoint
  polling, Redis list length, or similar.
- **HA leader election (`Deda.HA`)** — implement `ILeaderElector` using a
  Swarm-based distributed lock or an external store. See the stub project for
  the interface.
- **Structured observability (`Deda.Observability`)** — wire up OpenTelemetry
  metrics and/or traces.
- **Prometheus metrics model** — replace string-interpolated metric keys in
  `MetricsRegistry` with a proper `MetricFamily` abstraction.

---

## Code of Conduct

Be respectful and constructive. We follow the
[Contributor Covenant](https://www.contributor-covenant.org/version/2/1/code_of_conduct/).
