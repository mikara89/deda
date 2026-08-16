# v0.3 CI runner release qualification

v0.3 focuses on autoscaling self-hosted Docker Swarm runners for GitHub
Actions, Azure Pipelines, and GitLab CI. DEDA computes runner capacity from
compatible queued **plus active** jobs:

```text
required capacity = queued jobs + active jobs
```

Queue-only scaling is unsafe for ephemeral runners. After every runner claims
work the queue is empty, so a queue-only controller would scale the service
down while jobs are still running. Provider observations are cached per
controller/service for `refreshSeconds`; an API or semantic response failure
uses the service fail-safe policy rather than interpreting failure as zero work.

## Ownership

| Owner | Responsibility |
| --- | --- |
| DEDA | Observe compatible provider queues, compute required capacity, and change the Swarm service desired replica count. |
| Runner container | Register with the provider, execute the job, deregister, drain gracefully, and clean up local state. |

DEDA does not register runners, cancel jobs, or choose which Swarm task is
stopped on scale-down.

## Qualification hierarchy

These statuses are not interchangeable:

| Status field | How it is produced | What PASS means |
| --- | --- | --- |
| `fastQualification` | `run-deterministic.sh --fast` (simulator + Swarm) | Fast deterministic scenarios passed. |
| `fullDeterministicQualification` | `run-deterministic.sh --full` (real runner entrypoints + fake provider) | Full deterministic scenarios passed. |
| Real-provider GitHub Actions / Azure Pipelines / GitLab CI | Operator-run `real/*.sh --confirm-real-provider-tests` | That SaaS provider completed `0 → N → 0` with correlated jobs. |
| `releaseQualification` | Aggregate of full deterministic PASS **and** all three real-provider PASS, bound to the same commit and the same four `image@sha256:…` pins | The qualified digest may be **aliased** to v0.3.0 final. |

```text
fastQualification PASS  ≠  releaseQualification PASS
fullDeterministicQualification PASS  ≠  releaseQualification PASS
```

`NOT_RUN` is never converted into `PASS`. Deterministic evidence never implies
real-provider success.

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
service drains back to zero. Provider job identities are correlated to those
Swarm tasks rather than accepted as unrelated self-hosted capacity. Real
qualification requires digest-pinned DEDA and runner images, and `run-all.sh`
refuses `PASS` unless the deterministic and real manifests share the same
candidate commit and DEDA image ID.

## Runner lifecycle and safety

DEDA only changes desired replica count; Swarm may choose a busy task when it
scales down. The runner images therefore own graceful draining: GitHub's busy
hook preserves its ephemeral job, Azure runs one job through `run.sh --once`,
and GitLab receives `SIGQUIT` for graceful drain. Full deterministic mode runs
the runner lifecycle contract repeatedly and performs three real Swarm
`5 → 0` drain cycles per provider.

The GitHub job-started hook has a narrow dispatch race near termination. The
qualification treats any observed active-job cancellation as a failure and
records the lifecycle evidence; it does not claim a mathematical guarantee from
timing sleeps.

## Interpreting status

`RESULT.md` names every deterministic scenario and separates fast and full
deterministic statuses. A fast PASS does not imply full deterministic PASS.
The aggregate must report:

```text
RELEASE QUALIFICATION: NOT_QUALIFIED
```

until full deterministic qualification, GitHub Actions, Azure Pipelines, and
GitLab CI real-provider runs all have PASS evidence. Any mandatory provider
failure makes release qualification `FAIL`; `NOT_RUN` is never converted into
`PASS`.

## Promotion path

```text
prerelease tag v0.3.0-rc.N  (rebuilds, scans, signs)
    → check out that exact tag
    → fullDeterministicQualification PASS  (same four digest pins)
    → real GitHub Actions PASS
    → real Azure Pipelines PASS
    → real GitLab CI PASS
    → same image OCI revision + same four sha256 digests
    → releaseQualification PASS
    → Promote qualified release workflow
    → alias sha256:AAAA to :v0.3.0 / :0.3.0   (no rebuild)
    → final git tag + GitHub Release from RC artifacts
```

Do not promote from `fastQualification` alone. Do not `git tag v0.3.0` by
hand. `.github/workflows/docker-publish.yml` rebuilds only prerelease tags
(`v*.*.*-*`). Stable `vMAJOR.MINOR.PATCH` tags cannot enter that rebuild
path. If a rebuild is ever required, that new digest must go through this
path again.

After `releaseQualification` PASS, attach the sanitized aggregate to the RC
GitHub Release, then dispatch `.github/workflows/promote-release.yml` with
`confirm_promote=true`, the qualified RC tag, the qualified `sha256` digest,
and a `final_tag` whose base SemVer matches the RC (`v0.3.0-rc.2` →
`v0.3.0`):

```bash
gh release upload v0.3.0-rc.2 \
  tests/qualification/results/$RUN_ID/v0.3-ci/real-provider-result.json#release-qualification.json \
  tests/qualification/results/$RUN_ID/v0.3-ci/manifest.json#qualification-manifest.json
```

The workflow downloads those files **before** any image alias or tag
mutation. It refuses unless `releaseQualification` is `PASS`, all three
real providers are `PASS`, `candidateMatched` is true, the manifest pin
equals the supplied digest, runner reference digests are present, and the
image OCI revision equals the RC commit. Existing `:v0.3.0` tags, git tags,
or GitHub Releases are accepted only when they already identify that same
digest and commit. It does not run `docker build` or `dotnet publish`.

## Operator prerequisites

- A Swarm manager with Docker CLI access for deterministic mode.
- Four immutable candidate images (`image@sha256:…`): DEDA plus the GitHub
  Actions, Azure Pipelines, and GitLab CI runner images. Never qualify
  `latest`, `v0.3`, or any other mutable tag.
- For real mode: dedicated existing GitHub repository/workflow, Azure
  organization/project/pipeline/agent pool, and GitLab project/ref/runner
  target, with differing-duration jobs already defined by the target workflow.
- Queue and registration tokens supplied only as readable files; do not place
  them in labels, result files, or command output.

## Publish operator-owned runner images

This repository does not publish the three runner images. Operators build and
push them to a registry they control, then pin the resulting manifest digests.
Use the checksums from the example Dockerfiles / CI job:

```bash
# GitHub Actions
docker buildx build --platform linux/amd64,linux/arm64 \
  --build-arg RUNNER_SHA256_AMD64=048024cd2c848eb6f14d5646d56c13a4def2ae7ee3ad12122bee960c56f3d271 \
  --build-arg RUNNER_SHA256_ARM64=f44255bd3e80160eb25f71bc83d06ea025f6908748807a584687b3184759f7e4 \
  -t REGISTRY/deda-github-runner:v0.3.0-rc.2 \
  --push examples/ci-runners/github-actions

# Azure Pipelines
docker buildx build --platform linux/amd64,linux/arm64 \
  --build-arg AGENT_SHA256_AMD64=828220fc662131f8d6bd427c8d8b9bffae064a9b1532b7e448d58766276b31fa \
  --build-arg AGENT_SHA256_ARM64=bd61a2526333403a6d76243a49846887a1dd8eb115bbce6b037c950c2118f138 \
  -t REGISTRY/deda-azure-runner:v0.3.0-rc.2 \
  --push examples/ci-runners/azure-pipelines

# GitLab CI
docker buildx build --platform linux/amd64,linux/arm64 \
  -t REGISTRY/deda-gitlab-runner:v0.3.0-rc.2 \
  --push examples/ci-runners/gitlab
```

Capture each immutable digest (do not keep using the mutable `:v0.3.0-rc.2` tag):

```bash
digest_of() {
  docker buildx imagetools inspect "$1" --format '{{json .Manifest}}' | jq -r .digest
}
export GITHUB_QUAL_RUNNER_IMAGE="REGISTRY/deda-github-runner@$(digest_of REGISTRY/deda-github-runner:v0.3.0-rc.2)"
export AZURE_QUAL_RUNNER_IMAGE="REGISTRY/deda-azure-runner@$(digest_of REGISTRY/deda-azure-runner:v0.3.0-rc.2)"
export GITLAB_QUAL_RUNNER_IMAGE="REGISTRY/deda-gitlab-runner@$(digest_of REGISTRY/deda-gitlab-runner:v0.3.0-rc.2)"
```

## Deterministic commands

Build a local candidate only for development. A release-bound run must use
the RC tag checkout whose commit equals the image
`org.opencontainers.image.revision`. Qualifying a digest from a later `main`
checkout fails closed.

```bash
git fetch --tags
git checkout --detach v0.3.0-rc.2
test "$(git rev-parse HEAD)" = "$(git rev-parse 'v0.3.0-rc.2^{commit}')"
```

A release-bound full run must export **all four** digest pins **before**
`--full`. Omitting the runner pins builds local `:ci` tags, records null
runner reference digests, and makes later real-provider `candidateMatched`
fail even if every SaaS run PASSes.

```bash
export RUN_ID=v0.3.0-rc.2
export DEDA_IMAGE=ghcr.io/mikara89/deda@sha256:<rc-manifest-digest>
export GITHUB_QUAL_RUNNER_IMAGE=REGISTRY/deda-github-runner@sha256:<digest>
export AZURE_QUAL_RUNNER_IMAGE=REGISTRY/deda-azure-runner@sha256:<digest>
export GITLAB_QUAL_RUNNER_IMAGE=REGISTRY/deda-gitlab-runner@sha256:<digest>

bash tests/qualification/v0.3/ci-runners/run-deterministic.sh --fast
bash tests/qualification/v0.3/ci-runners/run-deterministic.sh --full
```

Dispatching `.github/workflows/ci-runner-qualification.yml` with `mode=fast`
or `mode=full` and `confirm_real_provider_tests=false` never calls SaaS. That
workflow builds a local `deda:qualification` image and is **not** release
evidence: it does not bind the published RC digest or the three runner
digests.

## Real-provider readiness (do not run accidentally)

Real GitHub Actions, Azure Pipelines, and GitLab CI qualification is
operator-only. Credentials alone are not authorization. Every command requires
`--confirm-real-provider-tests`. This repository's v0.3.0-rc.1 preparation
**must not** execute these commands.

Reuse the **same** `RUN_ID` and the **same** four digest pins as the full
deterministic run (`REAL_DEDA_IMAGE` must equal `DEDA_IMAGE`):

```bash
export REAL_DEDA_IMAGE="$DEDA_IMAGE"
# GITHUB_QUAL_RUNNER_IMAGE, AZURE_QUAL_RUNNER_IMAGE, GITLAB_QUAL_RUNNER_IMAGE,
# and RUN_ID remain set from the full deterministic run.
```

Required secret files (never labels or environment token values):

| Provider | Queue observer file | Runner registration file | Other required env |
| --- | --- | --- | --- |
| GitHub Actions | `GITHUB_QUAL_QUEUE_TOKEN_FILE` | `GITHUB_QUAL_RUNNER_ADMIN_TOKEN_FILE` | `GITHUB_QUAL_OWNER`, `GITHUB_QUAL_REPOSITORY`, `GITHUB_QUAL_WORKFLOW` |
| Azure Pipelines | `AZURE_QUAL_QUEUE_TOKEN_FILE` | `AZURE_QUAL_AGENT_TOKEN_FILE` | `AZURE_QUAL_ORGANIZATION_URL`, `AZURE_QUAL_PROJECT`, `AZURE_QUAL_PIPELINE_ID`, `AZURE_QUAL_POOL` |
| GitLab CI | `GITLAB_QUAL_QUEUE_TOKEN_FILE` | `GITLAB_QUAL_RUNNER_TOKEN_FILE` | `GITLAB_QUAL_URL`, `GITLAB_QUAL_PROJECT`, `GITLAB_QUAL_REF`, `GITLAB_QUAL_TAGS` |

```bash
# Operator-only. Do not run during RC preparation.
bash tests/qualification/v0.3/ci-runners/real/run-all.sh --confirm-real-provider-tests
```

Individual providers: `real/github.sh`, `real/azure-pipelines.sh`,
`real/gitlab.sh`, each with the same confirmation flag.

The v0.3 Hetzner wrapper in
[`tests/qualification/v0.3/hetzner`](../../tests/qualification/v0.3/hetzner/README.md)
is the operator path for release qualification of a published RC on one
temporary Swarm manager. It invokes the canonical scripts in this directory
over Docker-over-SSH and does not rebuild DEDA or promote a release.

The v0.2 Hetzner harness remains the approved reusable foundation for
explicit, dry-run-capable multi-manager / HA cloud qualification. Neither
harness runs because `HCLOUD_TOKEN` exists, and neither sends that token to
VMs.
