# Azure Pipelines agent

Build the agent with an Azure-published archive checksum supplied by your release process, publish it, create distinct observer and registration secrets, and deploy the fixed stack name:

```bash
docker buildx build --platform linux/amd64,linux/arm64 --build-arg AGENT_SHA256_AMD64=828220fc662131f8d6bd427c8d8b9bffae064a9b1532b7e448d58766276b31fa --build-arg AGENT_SHA256_ARM64=bd61a2526333403a6d76243a49846887a1dd8eb115bbce6b037c950c2118f138 -t REGISTRY/deda-azure-runner:v0.3.0 --push .
docker secret create ado-queue-reader - < ado-queue-reader.txt
docker secret create ado-agent-registration - < ado-agent-registration.txt
docker stack deploy -c stack.yml ci-azure
```

The DEDA credential is a least-privilege reader for the distributed-task job-request endpoint. The separate `ado-agent-registration` secret is a PAT (or supported service-principal token) authorized to manage agents in only the `deda-swarm` pool. The agent uses unattended configuration, a unique task-derived name, and `run.sh --once`.

Queue a pipeline based on `pipeline.example.yml`. Its pool demands are exactly `Agent.OS -equals Linux` and `deda`, matching `trigger.demands`; `DEDA=true` is deliberately present in the runner environment so the agent publishes that custom capability. DEDA should show `0 → N → 0` in `docker service ls`. Use DEDA `deda_ci_*` metrics and its 15-second observation cache to understand API volume, failures, and observation age.

The root supervisor alone can read the registration PAT, configures the agent, and starts `run.sh --once` as unprivileged `azp`. On TERM the wrapper intentionally does not kill `run.sh`: Azure's documented removal operation fails while a job is active, so cleanup retries every 15 seconds for 120 attempts—matching the 30-minute Swarm grace period—until the one-job agent finishes. A job that outlives that period can still be force-killed by Swarm; choose and qualify the grace period for your workload. Logs remain in `docker service logs`; ship them to central retention.
