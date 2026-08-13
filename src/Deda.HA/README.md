# Deda.HA

`Deda.HA` provides a fail-closed Redis TTL lease for active/standby DEDA
replicas. The leader renews the lease in the background. A standby performs no
Docker discovery or replica updates, and the controller checks leadership again
immediately before every mutating Docker call.

Enable it with `DEDA_REDIS_CONNECTION`, for example `redis:6379,ssl=false`.
Each task should have a unique `DEDA_INSTANCE_ID`; Docker task hostnames are
unique and are used with the process ID when the variable is omitted.

The defaults are a 30-second TTL and 10-second renewal interval. Override them
with `DEDA_LEADER_LEASE_SECONDS`, `DEDA_LEADER_RENEW_SECONDS`, and
`DEDA_LEADER_LOCK_KEY`. A Redis outage fails closed and makes all instances
unready; a replica that successfully confirms another owner is a healthy
standby. On graceful shutdown the leader releases its lock; after an ungraceful
failure, another instance can take over after TTL expiry.

Redis should itself be deployed with the durability and network isolation
appropriate to the cluster. The lease prevents normal concurrent updates but
Docker Swarm has no fencing-token field, so it cannot provide a mathematically
linearizable fence across an arbitrary network partition.
