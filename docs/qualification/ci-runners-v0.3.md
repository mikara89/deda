# v0.3 CI runner release qualification

v0.3 focuses on autoscaling self-hosted Docker Swarm runners for GitHub
Actions, Azure Pipelines, and GitLab CI. DEDA computes runner capacity from
compatible queued **plus active** jobs. Provider observations are cached per
controller/service for `refreshSeconds`; an API or semantic response failure
uses the service fail-safe policy rather than interpreting failure as zero work.

## Two qualification levels

`tests/qualification/v0.3/ci-runners/run-deterministic.sh` uses a local,
stateful provider simulator and a real Docker Swarm deployment of DEDA, Redis
HA, socket proxy, and runner test services. It covers capacity and compatibility
matching, scale from/to zero, provider failure hold behavior, cache expiry and
invalidation, Redis failover, lifecycle cleanup, and credential policy cases.
Full mode replaces the generic sleep simulator with qualification images
derived from the real PR10 runner images; Swarm signals the actual runner
entrypoint while fake provider binaries keep the API interaction deterministic.
It records bounded, sanitized evidence below
`tests/qualification/results/<RUN_ID>/v0.3-ci/`.

The simulator has no SaaS credentials and does not record request headers. It
is suitable for ordinary CI. The full suite is exposed only through an explicit
`workflow_dispatch`; it does not run when credentials happen to be present.

Real-provider qualification is a separate operator activity in
[`tests/qualification/v0.3/ci-runners/real`](../../tests/qualification/v0.3/ci-runners/real/README.md).
It requires `--confirm-real-provider-tests`, dedicated pre-existing provider
targets, and file paths for queue and runner registration credentials. It never
creates random SaaS resources or deletes the supplied project, repository, or
pool. The harness polls the submitted workflow/pipeline job conclusions and
retains sanitized IDs, timestamps, statuses, and runner/task identifiers; a
successful dispatch alone is not evidence of a PASS. Each real-provider harness
also deploys a dedicated Swarm stack with the runner registration file,
verifies the DEDA-managed runner service starts at zero, observes `0 → N`,
captures running tasks while provider jobs are active, and then verifies the
service drains back to zero.

## Runner lifecycle and safety

DEDA only changes desired replica count; Swarm may choose a busy task when it
scales down. The runner images therefore own graceful draining: GitHub's busy
hook preserves its ephemeral job, Azure runs one job through `run.sh --once`,
and GitLab receives `SIGQUIT` for graceful drain. The deterministic suite runs
the runner lifecycle contract repeatedly and retains the logs as evidence.

The GitHub job-started hook has a narrow dispatch race near termination. The
qualification treats any observed active-job cancellation as a failure and
records the lifecycle evidence; it does not claim a mathematical guarantee from
timing sleeps.

## Interpreting status

`RESULT.md` names every deterministic scenario and writes both aggregate
statuses. A deterministic PASS means only that the deterministic qualification
passed. It must report:

```text
RELEASE QUALIFICATION: NOT_QUALIFIED
```

until GitHub Actions, Azure Pipelines, and GitLab CI real-provider runs all
have PASS evidence, and every mandatory deterministic scenario has passed. Any
mandatory provider failure makes release qualification `FAIL`; `NOT_RUN` is
never converted into `PASS`.

## Operator prerequisites

- A Swarm manager with Docker CLI access for deterministic mode.
- An immutable candidate `DEDA_IMAGE`; never qualify `latest`.
- For real mode: dedicated existing GitHub repository/workflow, Azure
  organization/project/pipeline/agent pool, and GitLab project/ref/runner
  target, with differing-duration jobs already defined by the target workflow.
- Queue and registration tokens supplied only as readable files; do not place
  them in labels, result files, or command output.

The v0.2 Hetzner harness remains the approved reusable foundation for an
explicit, dry-run-capable multi-manager cloud qualification. It does not run
because `HCLOUD_TOKEN` exists and never sends that token to VMs.
