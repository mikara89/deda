# Deda.HA — High Availability (Not Yet Implemented)

This project is a **planned stub**. It will contain an implementation of
`ILeaderElector` from `Deda.Core`, enabling multiple DEDA instances to run
across Swarm manager nodes without conflicting on scale updates.

## Planned behaviour

- One DEDA instance acts as the **active leader** and runs the reconciliation
  loop.
- Other instances remain on standby and take over automatically if the leader
  goes away.
- Leader election will use a distributed locking mechanism suitable for Docker
  Swarm. Two approaches are being considered:
  - **Shared store lock** — use an external key-value store (e.g., Redis or
    etcd) to hold a TTL-based leader key. Each DEDA instance tries to atomically
    acquire the key; the one that holds it is the active leader and must renew
    it on a heartbeat interval. If the leader process dies the TTL expires and
    another instance can take over. This approach requires an extra dependency
    but is battle-tested and straightforward to reason about.
  - **Swarm-native lock** — use the Docker Swarm API itself as the coordination
    primitive (e.g., write a well-known service label or config object that acts
    as a lock, or restrict DEDA to `replicas: 1` with Swarm's own restart policy
    guaranteeing at-most-one active instance at any time). This requires no
    external dependency but gives less control over failover timing and
    split-brain scenarios.

## Contributing

If you are interested in implementing this, open an issue to discuss the
approach before starting. See [CONTRIBUTING.md](../../CONTRIBUTING.md) for
general guidelines. The `ILeaderElector` interface is defined in `Deda.Core`.
