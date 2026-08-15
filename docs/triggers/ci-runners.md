# CI runner triggers

CI runner triggers scale from **queued plus active** compatible jobs. This keeps
running jobs represented after the queue drains, preventing DEDA from scaling a
runner service down solely because every runner has picked up work.

Use `targetPerReplica: "1"` when each runner executes one job concurrently.
The runner image remains responsible for runner registration, deregistration,
job lifecycle, and cleanup; DEDA only owns the Swarm service replica count.

Production-oriented Swarm references, including separate observer and runner
credentials plus bounded drain behavior, are in the
[CI runner examples](../../examples/ci-runners/README.md).

## Credentials

Mount the provider token as a Docker secret into DEDA and define an
operator-owned policy file. Tokens never belong in service labels.

```json
{
  "github-build": {
    "type": "github",
    "secret": "github-actions-token",
    "allowedHosts": ["api.github.com"],
    "allowedServices": ["github-runner"]
  }
}
```

Set `DEDA_CREDENTIAL_POLICY_FILE` to the mounted file. `type` is `github`,
`azure-devops`, or `gitlab`; `allowedHosts` and `allowedServices` restrict where
the secret can be used. `allowedHosts` is mandatory: an empty or omitted list
fails closed rather than allowing a service label to redirect a token.

## GitHub Actions

```yaml
com.deda.autoscale.trigger.type: "github-actions"
com.deda.autoscale.trigger.owner: "example-org"
com.deda.autoscale.trigger.repos: "api,web"
com.deda.autoscale.trigger.labels: "self-hosted,linux,deda"
com.deda.autoscale.trigger.credentialsRef: "github-build"
com.deda.autoscale.trigger.refreshSeconds: "15"
```

The polling implementation lists queued and in-progress workflow runs, reads
their jobs, and counts only jobs whose required labels are a subset of this
runner type's labels. Labels are mandatory so GitHub-hosted jobs are not counted.
The observation cache uses `refreshSeconds` (default: 15; range: 1–3600), so
reconciliations between refreshes do not repeat GitHub API calls.

## Azure Pipelines

```yaml
com.deda.autoscale.trigger.type: "azure-pipelines"
com.deda.autoscale.trigger.organizationUrl: "https://dev.azure.com/example"
com.deda.autoscale.trigger.poolId: "12"
com.deda.autoscale.trigger.demands: "docker,dotnet,Agent.OS=Linux"
com.deda.autoscale.trigger.credentialsRef: "ado-build"
```

`poolName` may replace `poolId`. `demands` describes this runner type's
capabilities: a bare name supports Azure `Exists`; `name=value` supports
`-equals`. The trigger uses Azure DevOps' distributed-task job-request endpoint;
DEDA isolates its response format within the provider.

## GitLab CI

```yaml
com.deda.autoscale.trigger.type: "gitlab-ci"
com.deda.autoscale.trigger.url: "https://gitlab.com"
com.deda.autoscale.trigger.projects: "group/api,group/web"
com.deda.autoscale.trigger.tags: "docker,linux,deda"
com.deda.autoscale.trigger.runUntagged: "false"
com.deda.autoscale.trigger.credentialsRef: "gitlab-build"
```

The project Jobs API is queried for `pending` and `running` jobs. A job's tags
must be a subset of the configured runner tags, using GitLab's case-sensitive
matching; `runUntagged=true` includes untagged jobs.
Self-managed GitLab is supported by setting `trigger.url`.

## Runner shutdown contract for PR6

DEDA controls only the desired Swarm replica count. Swarm may choose any task
when scaling down, including one that is currently executing a job. Runner
images must therefore implement job-aware draining and graceful deregistration,
and their service examples must configure a stop grace period long enough for
that shutdown path.

PR6 qualification must exercise downscaling while a job is active and prove
that the job is not interrupted or abandoned. A runner example is not qualified
solely because registration, idle scale-up, and idle scale-down succeed.

## v0.3 release qualification

The v0.3 harness runs these trigger implementations against a deterministic
provider simulator and an actual Swarm deployment. It checks compatible queued
plus active capacity, observation caching, fail-safe hold behavior, HA
continuity, scale-to-zero recovery, and the runner drain contracts. Real GitHub,
Azure, and GitLab runs are explicit operator actions and remain separate from
normal CI. See [v0.3 CI runner qualification](../qualification/ci-runners-v0.3.md).
