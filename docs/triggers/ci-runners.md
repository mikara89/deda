# CI runner triggers

CI runner triggers scale from **queued plus active** compatible jobs. This keeps
running jobs represented after the queue drains, preventing DEDA from scaling a
runner service down solely because every runner has picked up work.

Use `targetPerReplica: "1"` when each runner executes one job concurrently.
The runner image remains responsible for runner registration, deregistration,
job lifecycle, and cleanup; DEDA only owns the Swarm service replica count.

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
the secret can be used.

## GitHub Actions

```yaml
com.deda.autoscale.trigger.type: "github-actions"
com.deda.autoscale.trigger.owner: "example-org"
com.deda.autoscale.trigger.repos: "api,web"
com.deda.autoscale.trigger.labels: "self-hosted,linux,deda"
com.deda.autoscale.trigger.credentialsRef: "github-build"
```

The polling implementation lists queued and in-progress workflow runs, reads
their jobs, and filters jobs by runner labels. Repository names are required for
both repository and organization deployments so API usage remains explicit.

## Azure Pipelines

```yaml
com.deda.autoscale.trigger.type: "azure-pipelines"
com.deda.autoscale.trigger.organizationUrl: "https://dev.azure.com/example"
com.deda.autoscale.trigger.poolId: "12"
com.deda.autoscale.trigger.demands: "docker,dotnet"
com.deda.autoscale.trigger.credentialsRef: "ado-build"
```

`poolName` may replace `poolId`. The trigger uses Azure DevOps' distributed-task
job-request endpoint; DEDA isolates its response format within the provider.

## GitLab CI

```yaml
com.deda.autoscale.trigger.type: "gitlab-ci"
com.deda.autoscale.trigger.url: "https://gitlab.com"
com.deda.autoscale.trigger.projects: "group/api,group/web"
com.deda.autoscale.trigger.tags: "docker,linux,deda"
com.deda.autoscale.trigger.runUntagged: "false"
com.deda.autoscale.trigger.credentialsRef: "gitlab-build"
```

The project Jobs API is queried for `pending` and `running` jobs. Jobs with tags
must match the configured runner tags; `runUntagged=true` includes untagged jobs.
Self-managed GitLab is supported by setting `trigger.url`.
