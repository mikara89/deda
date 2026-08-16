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
grep -Fq 'docker service update --detach=true' "$SCRIPT_DIR/common.sh" || { echo 'update_ephemeral_service must use non-blocking docker service update' >&2; exit 1; }
grep -Fq 'update_ephemeral_service()' "$SCRIPT_DIR/common.sh" || { echo 'missing update_ephemeral_service helper' >&2; exit 1; }
[[ $(grep -c 'update_ephemeral_service --label-add com.deda.autoscale.trigger.refreshSeconds=' "$SCRIPT_DIR/scenarios/06-observation-cache.sh") == 2 ]] || {
  echo 'scenario 06 must change refreshSeconds twice through update_ephemeral_service' >&2
  exit 1
}
if grep -nE 'docker service update' "$SCRIPT_DIR/scenarios/06-observation-cache.sh" | grep -v -- '--detach'; then
  echo 'scenario 06 must not issue a blocking docker service update' >&2
  exit 1
fi
if grep -nE 'docker service update' "$SCRIPT_DIR/scenarios/03-gitlab-capacity.sh" | grep -v -- '--detach'; then
  echo 'scenario 03 must not issue a blocking docker service update against the ephemeral GitLab runner' >&2
  exit 1
fi
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
if grep -nE 'dotnet publish' "$promote_workflow" || grep -nE 'docker build' "$promote_workflow" | grep -v 'docker buildx'; then
  echo 'promotion must alias a qualified digest and must not rebuild' >&2
  exit 1
fi
grep -Fq 'assert_candidate_source_binding()' "$SCRIPT_DIR/common.sh"
grep -Fq 'assert_candidate_source_binding' "$SCRIPT_DIR/run-deterministic.sh"
grep -Fq 'assert_candidate_source_binding' "$SCRIPT_DIR/real/common.sh"
grep -Fq 'org.opencontainers.image.revision' "$SCRIPT_DIR/common.sh"
grep -Fq 'candidateImageRevision' "$SCRIPT_DIR/collect-evidence.sh"
grep -Fq 'promote-preflight.sh' "$promote_workflow"
grep -Fq 'release-qualification.json' "$promote_workflow"
grep -Fq 'releaseQualification == "PASS"' "$SCRIPT_DIR/promote-preflight.sh"
grep -Fq 'candidateMatched == true' "$SCRIPT_DIR/promote-preflight.sh"
grep -Fq 'expected_final' "$SCRIPT_DIR/promote-preflight.sh"
download_line=$(grep -n 'gh release download' "$promote_workflow" | head -n1 | cut -d: -f1)
preflight_line=$(grep -n 'promote-preflight.sh' "$promote_workflow" | head -n1 | cut -d: -f1)
alias_line=$(grep -n 'imagetools create' "$promote_workflow" | head -n1 | cut -d: -f1)
[[ -n "$download_line" && -n "$preflight_line" && -n "$alias_line" ]] || { echo 'promotion workflow is missing download, preflight, or alias steps' >&2; exit 1; }
(( download_line < preflight_line && preflight_line < alias_line )) || { echo 'promotion must download and verify evidence before mutating aliases' >&2; exit 1; }
if grep -nE 'final tag .* already exists' "$promote_workflow" | grep -v 'points to'; then
  echo 'promotion must treat a correct existing final tag as success' >&2
  exit 1
fi
pass_dir="$SCRIPT_DIR/testdata/promote/pass"
fail_dir="$SCRIPT_DIR/testdata/promote/fail-not-run"
digest='sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
commit='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
bash "$SCRIPT_DIR/promote-preflight.sh" \
  --qual "$pass_dir/release-qualification.json" \
  --manifest "$pass_dir/qualification-manifest.json" \
  --digest "$digest" --commit "$commit" --revision "$commit" \
  --source-tag v0.3.0-rc.2 --final-tag v0.3.0
if bash "$SCRIPT_DIR/promote-preflight.sh" \
  --qual "$fail_dir/release-qualification.json" \
  --manifest "$fail_dir/qualification-manifest.json" \
  --digest "$digest" --commit "$commit" --revision "$commit" \
  --source-tag v0.3.0-rc.2 --final-tag v0.3.0; then
  echo 'promotion preflight must reject NOT_RUN real-provider evidence' >&2
  exit 1
fi
if bash "$SCRIPT_DIR/promote-preflight.sh" \
  --qual "$pass_dir/release-qualification.json" \
  --manifest "$pass_dir/qualification-manifest.json" \
  --digest "$digest" --commit "$commit" --revision "$commit" \
  --source-tag v0.3.0-rc.2 --final-tag v9.0.0; then
  echo 'promotion preflight must reject a final_tag from a different SemVer' >&2
  exit 1
fi
mismatch_dir="$SCRIPT_DIR/testdata/promote/fail-runner-mismatch"
if bash "$SCRIPT_DIR/promote-preflight.sh" \
  --qual "$mismatch_dir/release-qualification.json" \
  --manifest "$mismatch_dir/qualification-manifest.json" \
  --digest "$digest" --commit "$commit" --revision "$commit" \
  --source-tag v0.3.0-rc.2 --final-tag v0.3.0; then
  echo 'promotion preflight must reject runner digest mismatch between aggregate and manifest' >&2
  exit 1
fi
grep -Fq 'plan_aliases()' "$SCRIPT_DIR/promote-aliases.sh"
grep -Fq 'plan_aliases' "$promote_workflow"
grep -Fq 'gh release upload' "$promote_workflow"
[[ $(bash "$SCRIPT_DIR/promote-aliases.sh" '' '' "$digest") == CREATE ]] || { echo 'missing aliases must plan CREATE' >&2; exit 1; }
[[ $(bash "$SCRIPT_DIR/promote-aliases.sh" "$digest" "$digest" "$digest") == OK ]] || { echo 'matching aliases must plan OK' >&2; exit 1; }
if bash "$SCRIPT_DIR/promote-aliases.sh" '' 'sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff' "$digest"; then
  echo 'missing v-tag plus wrong plain tag must FAIL and not overwrite' >&2
  exit 1
fi
if grep -Fq -- "grep -F 'deda-ado-'" "$SCRIPT_DIR/real/azure-pipelines.sh"; then
  echo 'Azure qualification must not pre-filter worker identities before validation' >&2
  exit 1
fi
mock_dir=$(mktemp -d)
trap 'rm -rf "$mock_dir"; rm -f "$SCRIPT_DIR/stack/credential-policy.json"' EXIT
cat > "$mock_dir/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
log=${DEDA_QUAL_DOCKER_MOCK_LOG:?}
printf '%s\n' "$*" >> "$log"
if [[ "${1:-}" == service && "${2:-}" == update ]]; then
  detach=0
  for arg in "$@"; do
    if [[ "$arg" == --detach || "$arg" == --detach=true ]]; then
      detach=1
    fi
  done
  if (( detach == 0 )); then
    while [[ -e "${DEDA_QUAL_DOCKER_MOCK_BLOCK:-}" ]]; do
      sleep 0.1
    done
    exit 99
  fi
  if [[ -n "${DEDA_QUAL_DOCKER_MOCK_OBS:-}" ]]; then
    current=$(cat "${DEDA_QUAL_DOCKER_MOCK_OBS}.count" 2>/dev/null || printf '0')
    printf '%s\n' $((current + 1)) > "${DEDA_QUAL_DOCKER_MOCK_OBS}.count"
  fi
  exit 0
fi
if [[ "${1:-}" == service && "${2:-}" == scale ]]; then
  exit 0
fi
if [[ "${1:-}" == service && "${2:-}" == ps ]]; then
  printf '%s\n' 'Running 1 second ago'
  exit 0
fi
if [[ "${1:-}" == run ]]; then
  if printf '%s' "$*" | grep -Fq '/metrics'; then
    count=$(cat "${DEDA_QUAL_DOCKER_MOCK_OBS}.count" 2>/dev/null || printf '1')
    printf 'deda_ci_observations_total{provider="github-actions"} %s\n' "$count"
    exit 0
  fi
  printf '%s\n' '{}'
  exit 0
fi
exit 0
EOF
chmod 755 "$mock_dir/docker"
export DEDA_QUAL_DOCKER_MOCK_LOG="$mock_dir/docker.log"
export DEDA_QUAL_DOCKER_MOCK_OBS="$mock_dir/obs"
export DEDA_QUAL_DOCKER_MOCK_BLOCK="$mock_dir/block"
printf '1\n' > "$mock_dir/obs.count"
: > "$DEDA_QUAL_DOCKER_MOCK_LOG"
: > "$DEDA_QUAL_DOCKER_MOCK_BLOCK"
saved_path=$PATH
export PATH="$mock_dir:$PATH"

update_ephemeral_service --label-add com.deda.autoscale.trigger.refreshSeconds=15 deda-v03-qual_github-runner >/dev/null
update_ephemeral_service --label-add com.deda.autoscale.trigger.refreshSeconds=1 deda-v03-qual_github-runner >/dev/null
[[ $(grep -c 'service update --detach=true' "$DEDA_QUAL_DOCKER_MOCK_LOG") == 2 ]] || {
  echo 'update_ephemeral_service did not issue two detached service updates' >&2
  exit 1
}
if grep -E 'service update' "$DEDA_QUAL_DOCKER_MOCK_LOG" | grep -v -- '--detach=true'; then
  echo 'update_ephemeral_service issued a blocking service update' >&2
  exit 1
fi

"$mock_dir/docker" service update --label-add com.deda.autoscale.trigger.refreshSeconds=15 deda-v03-qual_github-runner >/dev/null &
blocker=$!
sleep 1
if ! kill -0 "$blocker" 2>/dev/null; then
  echo 'blocking docker service update returned immediately; mock did not simulate convergence hang' >&2
  exit 1
fi
rm -f "$DEDA_QUAL_DOCKER_MOCK_BLOCK"
wait "$blocker" 2>/dev/null || true

printf '1\n' > "$mock_dir/obs.count"
baseline=$(github_observations)
update_ephemeral_service --label-add com.deda.autoscale.trigger.refreshSeconds=15 deda-v03-qual_github-runner >/dev/null
github_observation_greater_than "$baseline" || {
  echo 'detached label change did not surface a fresh mocked GitHub observation' >&2
  exit 1
}
before_invalidation=$(github_observations)
update_ephemeral_service --label-add com.deda.autoscale.trigger.refreshSeconds=1 deda-v03-qual_github-runner >/dev/null
github_observation_greater_than "$before_invalidation" || {
  echo 'detached invalidation update did not surface a fresh mocked GitHub observation' >&2
  exit 1
}

export PATH=$saved_path
unset DEDA_QUAL_DOCKER_MOCK_LOG DEDA_QUAL_DOCKER_MOCK_OBS DEDA_QUAL_DOCKER_MOCK_BLOCK

if command -v docker >/dev/null 2>&1; then
  policy="$SCRIPT_DIR/stack/credential-policy.json"
  sed -e 's/__GITHUB_SERVICE__/deda-qual-static_github-runner/g' -e 's/__AZURE_SERVICE__/deda-qual-static_azure-runner/g' -e 's/__GITLAB_SERVICE__/deda-qual-static_gitlab-runner/g' "$SCRIPT_DIR/stack/credential-policy.json.tpl" > "$policy"
  (cd "$SCRIPT_DIR/stack" && DEDA_IMAGE=deda:qualification CI_SIMULATOR_IMAGE=deda-ci-provider-simulator:qualification CI_RUNNER_SIMULATOR_IMAGE=deda-ci-runner-lifecycle-simulator:qualification QUAL_SECRET_PREFIX=deda-qual-static docker stack config -c stack.yml >/dev/null)
fi
printf 'v0.3 CI runner qualification static tests passed.\n'
