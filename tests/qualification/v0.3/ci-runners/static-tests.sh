#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
for command in bash python3 jq; do command -v "$command" >/dev/null 2>&1 || { echo "missing $command" >&2; exit 1; }; done
find "$SCRIPT_DIR" -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
for script in github-curl github-jq; do
  sh -n "$SCRIPT_DIR/simulator/real-runner/$script"
done
test -f "$SCRIPT_DIR/simulator/real-runner/gitlab-runner.c"
grep -Fq 'sigaction(SIGQUIT' "$SCRIPT_DIR/simulator/real-runner/gitlab-runner.c"
grep -Fq 'completed-after-drain' "$SCRIPT_DIR/simulator/real-runner/gitlab-runner.c"
for script in run-deterministic.sh collect-evidence.sh real/run-all.sh real/github.sh real/azure-pipelines.sh real/gitlab.sh; do
  test -x "$SCRIPT_DIR/$script" || { echo "missing executable bit on $script" >&2; exit 1; }
done
# shellcheck disable=SC2016
grep -Fq 'bash "$SCRIPT_DIR/collect-evidence.sh"' "$SCRIPT_DIR/run-deterministic.sh"
# shellcheck disable=SC2016
grep -Fq 'bash "$SCRIPT_DIR/$provider.sh"' "$SCRIPT_DIR/real/run-all.sh"
python3 -m py_compile "$SCRIPT_DIR/simulator/server.py"
python3 "$SCRIPT_DIR/simulator/test_server.py"
grep -Fq 'completed-after-drain' "$SCRIPT_DIR/simulator/runner.sh"
jq empty "$SCRIPT_DIR/stack/credential-policy.json.tpl"
for name in 01-github-capacity 02-azure-capacity 03-gitlab-capacity 04-active-job-protection 05-provider-failure 06-observation-cache 07-ha-failover 08-credential-security 09-scale-to-zero 10-lifecycle-cleanup; do
  test -f "$SCRIPT_DIR/scenarios/$name.sh"
done
grep -Fq -- '--confirm-real-provider-tests' "$SCRIPT_DIR/real/run-all.sh"
grep -Fq 'RELEASE QUALIFICATION: **NOT_QUALIFIED**' "$SCRIPT_DIR/collect-evidence.sh"
grep -Fq 'fullDeterministicQualification' "$SCRIPT_DIR/collect-evidence.sh"
grep -Fq 'fastQualification' "$SCRIPT_DIR/collect-evidence.sh"
grep -Fq 'refusing to replace an unrelated resource' "$SCRIPT_DIR/real/common.sh"
grep -Fq 'real_stack_name' "$SCRIPT_DIR/real/common.sh"
grep -Fq 'deda_ci_required_capacity' "$SCRIPT_DIR/real/common.sh"
# shellcheck disable=SC2016
grep -Fq -- 'follow_container_logs "$drain_started_at" "$log_file" "$pid_file"' "$SCRIPT_DIR/scenarios/04-active-job-protection.sh"
grep -Fq 'snapshot_container_logs' "$SCRIPT_DIR/scenarios/04-active-job-protection.sh"
# shellcheck disable=SC2016
grep -Fq -- 'head_branch == $ref' "$SCRIPT_DIR/real/github.sh"
grep -Fq 'running_task_containers' "$SCRIPT_DIR/scenarios/04-active-job-protection.sh"
grep -Fq 'latest_request_at()' "$SCRIPT_DIR/common.sh"
# shellcheck disable=SC2016
if grep -nE 'requests\[\$baseline:\]' "$SCRIPT_DIR/common.sh" "$SCRIPT_DIR/scenarios/10-lifecycle-cleanup.sh"; then
  echo 'request-log waits must use timestamps, not a capped buffer index' >&2
  exit 1
fi
grep -Fq 'reference_digest()' "$SCRIPT_DIR/common.sh"
grep -Fq 'build_runner_qualification_overlay' "$SCRIPT_DIR/common.sh"
grep -Fq 'deda.qualification.candidateBaseDigest' "$SCRIPT_DIR/common.sh"
grep -Fq 'qualificationOverlayImageId' "$SCRIPT_DIR/collect-evidence.sh"
if grep -E 'if ! docker image inspect "\$[A-Z_]*QUALIFICATION_IMAGE"' "$SCRIPT_DIR/common.sh"; then
  echo 'qualification overlays must be rebuilt from the selected candidate base every full run' >&2
  exit 1
fi
# shellcheck disable=SC2016
if grep -nF '${IMAGE##*@}' "$SCRIPT_DIR/collect-evidence.sh" "$SCRIPT_DIR/common.sh" "$SCRIPT_DIR/real/common.sh"; then
  echo 'candidate reference digests must use reference_digest, not unquoted ##*@ parsing' >&2
  exit 1
fi
if grep -nE 'ReferenceDigest="\$\{[A-Z_]+##\*@\}"' "$SCRIPT_DIR/collect-evidence.sh" "$SCRIPT_DIR/real/common.sh"; then
  echo 'candidate reference digests must use the shared reference_digest helper' >&2
  exit 1
fi
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"
[[ $(reference_digest 'ghcr.io/x/runner@sha256:abc') == sha256:abc ]] || { echo 'reference_digest must extract sha256 pins' >&2; exit 1; }
[[ -z $(reference_digest 'deda-github-runner:ci') ]] || { echo 'reference_digest must be empty for mutable local tags' >&2; exit 1; }
[[ -z $(reference_digest 'ghcr.io/x/runner:latest') ]] || { echo 'reference_digest must be empty for mutable registry tags' >&2; exit 1; }
for file in github.Dockerfile azure.Dockerfile gitlab.Dockerfile; do
  grep -Fq 'ARG BASE_IMAGE' "$SCRIPT_DIR/simulator/real-runner/$file"
  # shellcheck disable=SC2016
  grep -Fq 'FROM ${BASE_IMAGE}' "$SCRIPT_DIR/simulator/real-runner/$file"
done
if [[ -f "$SCRIPT_DIR/../../../../.github/workflows/full-deterministic-temp.yml" ]]; then
  echo 'temporary full-deterministic workflow must not remain in the branch' >&2
  exit 1
fi
publish_workflow="$SCRIPT_DIR/../../../../.github/workflows/docker-publish.yml"
promote_workflow="$SCRIPT_DIR/../../../../.github/workflows/promote-release.yml"
grep -Fq 'tags: ["v*.*.*-*"]' "$publish_workflow" || { echo 'docker-publish must rebuild only prerelease tags' >&2; exit 1; }
if grep -Fq 'tags: ["v*.*.*"]' "$publish_workflow"; then
  echo 'docker-publish must not rebuild stable vMAJOR.MINOR.PATCH tags' >&2
  exit 1
fi
test -f "$promote_workflow"
grep -Fq 'confirm_promote' "$promote_workflow"
if grep -nE 'docker build|dotnet publish' "$promote_workflow"; then
  echo 'promotion must alias a qualified digest and must not rebuild' >&2
  exit 1
fi
grep -Fq 'assert_candidate_source_binding()' "$SCRIPT_DIR/common.sh"
grep -Fq 'assert_candidate_source_binding' "$SCRIPT_DIR/run-deterministic.sh"
grep -Fq 'assert_candidate_source_binding' "$SCRIPT_DIR/real/common.sh"
grep -Fq 'org.opencontainers.image.revision' "$SCRIPT_DIR/common.sh"
grep -Fq 'candidateImageRevision' "$SCRIPT_DIR/collect-evidence.sh"
if grep -Fq -- "grep -F 'deda-ado-'" "$SCRIPT_DIR/real/azure-pipelines.sh"; then
  echo 'Azure qualification must not pre-filter worker identities before validation' >&2
  exit 1
fi
if command -v docker >/dev/null 2>&1; then
  policy="$SCRIPT_DIR/stack/credential-policy.json"
  trap 'rm -f "$policy"' EXIT
  sed -e 's/__GITHUB_SERVICE__/deda-qual-static_github-runner/g' -e 's/__AZURE_SERVICE__/deda-qual-static_azure-runner/g' -e 's/__GITLAB_SERVICE__/deda-qual-static_gitlab-runner/g' "$SCRIPT_DIR/stack/credential-policy.json.tpl" > "$policy"
  (cd "$SCRIPT_DIR/stack" && DEDA_IMAGE=deda:qualification CI_SIMULATOR_IMAGE=deda-ci-provider-simulator:qualification CI_RUNNER_SIMULATOR_IMAGE=deda-ci-runner-lifecycle-simulator:qualification QUAL_SECRET_PREFIX=deda-qual-static docker stack config -c stack.yml >/dev/null)
fi
printf 'v0.3 CI runner qualification static tests passed.\n'
