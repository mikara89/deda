# Azure Pipelines agent

Build the agent with an Azure-published archive checksum supplied by your release process, publish it, create distinct observer and registration secrets, and deploy the fixed stack name:

```bash
docker buildx build --platform linux/amd64,linux/arm64 --build-arg AGENT_SHA256_AMD64=... --build-arg AGENT_SHA256_ARM64=... -t REGISTRY/deda-azure-runner:v0.3.0 --push .
docker secret create ado-queue-reader - < ado-queue-reader.txt
docker secret create ado-agent-registration - < ado-agent-registration.txt
docker stack deploy -c stack.yml ci-azure
```

The DEDA credential is a least-privilege reader for the distributed-task job-request endpoint. The separate `ado-agent-registration` secret is a PAT (or supported service-principal token) authorized to manage agents in only the `deda-swarm` pool. The agent uses unattended configuration, a unique task-derived name, and `run.sh --once`.

Queue a pipeline based on `pipeline.example.yml`. Its pool demands are exactly `Agent.OS -equals Linux` and `deda`, matching `trigger.demands`; `DEDA=true` is deliberately present in the runner environment so the agent publishes that custom capability. DEDA should show `0 → N → 0` in `docker service ls`. Use DEDA `deda_ci_*` metrics and its 15-second observation cache to understand API volume, failures, and observation age.

On TERM the wrapper intentionally does not kill `run.sh`: Azure's documented removal operation fails while a job is active, so cleanup retries until the one-job agent finishes. This bounds draining by Swarm's 30-minute grace period and avoids deliberately interrupting work. A job that outlives that period can still be force-killed by Swarm; choose and qualify the grace period for your workload. Logs remain in `docker service logs`; ship them to central retention.
