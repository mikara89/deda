#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

load_run
root=$(canonical_result_dir "$RUN_ID")
out=$(hetzner_result_dir "$RUN_ID")
mkdir -p "$out" "$root"

if [[ "${SWARM_READY:-}" == 1 && -n "${MANAGER_1_PUBLIC:-}" && -f "${SSH_PRIVATE_KEY:-/}" ]]; then
  apply_remote_docker || true
  docker info > "$out/docker-info.txt" 2>&1 || true
  docker version > "$out/docker-version.txt" 2>&1 || true
  docker node ls > "$out/docker-node-ls.txt" 2>&1 || true
fi
recorded_docker_host=$(remote_docker_host)

start_utc=${QUAL_STARTED_UTC:-}
if [[ -z "$start_utc" && -f "$(candidate_file "$RUN_ID")" ]]; then
  start_utc=$(date -u -r "$(candidate_file "$RUN_ID")" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || utc_now)
fi
end_utc=$(utc_now)

{
  printf 'RUN_ID=%s\n' "$RUN_ID"
  printf 'start_utc=%s\n' "$start_utc"
  printf 'end_utc=%s\n' "$end_utc"
  printf 'RC_TAG=%s\n' "$RC_TAG"
  printf 'RC_COMMIT=%s\n' "$RC_COMMIT"
  printf 'DEDA_IMAGE=%s\n' "$DEDA_IMAGE"
  printf 'GITHUB_QUAL_RUNNER_IMAGE=%s\n' "$GITHUB_QUAL_RUNNER_IMAGE"
  printf 'AZURE_QUAL_RUNNER_IMAGE=%s\n' "$AZURE_QUAL_RUNNER_IMAGE"
  printf 'GITLAB_QUAL_RUNNER_IMAGE=%s\n' "$GITLAB_QUAL_RUNNER_IMAGE"
  printf 'location=%s\n' "${DEDA_QUAL_LOCATION:-}"
  printf 'server_type=%s\n' "${DEDA_QUAL_SERVER_TYPE:-}"
  printf 'manager=%s\n' "${MANAGER_1:-}"
  printf 'manager_public=%s\n' "${MANAGER_1_PUBLIC:-}"
  printf 'manager_private=%s\n' "${MANAGER_1_PRIVATE:-}"
  printf 'DOCKER_HOST=%s\n' "$recorded_docker_host"
  printf 'git_head=%s\n' "$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)"
} > "$out/environment.txt"

if command -v hcloud >/dev/null 2>&1; then
  hcloud version > "$out/hcloud-version.txt" 2>&1 || true
  if [[ -n "${HCLOUD_TOKEN:-}" && -n "${MANAGER_1:-}" ]]; then
    hcloud server describe "$MANAGER_1" -o json 2>/dev/null \
      | jq '{id,name,status,server_type:(.server_type.name // null),location:(.datacenter.location.name // null),public_ipv4:(.public_net.ipv4.ip // null),private_ip:(.private_net[0].ip // null),labels}' \
      > "$out/server.json" || true
  fi
fi

fast=NOT_RUN
full=NOT_RUN
release=NOT_QUALIFIED
matched=false
github=NOT_RUN
azure=NOT_RUN
gitlab=NOT_RUN
if [[ -f "$root/result.json" ]]; then
  fast=$(jq -r '.fastQualification // "NOT_RUN"' "$root/result.json")
  full=$(jq -r '.fullDeterministicQualification // "NOT_RUN"' "$root/result.json")
  release=$(jq -r '.releaseQualification // "NOT_QUALIFIED"' "$root/result.json")
fi
if [[ -f "$root/real-provider-result.json" ]]; then
  release=$(jq -r '.releaseQualification // "NOT_QUALIFIED"' "$root/real-provider-result.json")
  matched=$(jq -r '.candidateMatched // false' "$root/real-provider-result.json")
  full=$(jq -r --arg full "$full" '.fullDeterministicQualification // $full' "$root/real-provider-result.json")
  github=$(jq -r '[.providers[]? | select(.provider == "github") | .status] | first // "NOT_RUN"' "$root/real-provider-result.json")
  azure=$(jq -r '[.providers[]? | select(.provider == "azure-pipelines") | .status] | first // "NOT_RUN"' "$root/real-provider-result.json")
  gitlab=$(jq -r '[.providers[]? | select(.provider == "gitlab") | .status] | first // "NOT_RUN"' "$root/real-provider-result.json")
fi

jq -n \
  --arg runId "$RUN_ID" --arg rcTag "$RC_TAG" --arg rcCommit "$RC_COMMIT" \
  --arg dedaImage "$DEDA_IMAGE" \
  --arg githubRunner "$GITHUB_QUAL_RUNNER_IMAGE" \
  --arg azureRunner "$AZURE_QUAL_RUNNER_IMAGE" \
  --arg gitlabRunner "$GITLAB_QUAL_RUNNER_IMAGE" \
  --arg dockerHost "$recorded_docker_host" \
  --arg server "${MANAGER_1:-}" \
  --arg publicIp "${MANAGER_1_PUBLIC:-}" \
  --arg collectedAt "$end_utc" \
  --arg startedAt "$start_utc" \
  --arg fast "$fast" --arg full "$full" --arg release "$release" --arg matched "$matched" \
  --arg github "$github" --arg azure "$azure" --arg gitlab "$gitlab" \
  '{
    runId:$runId,rcTag:$rcTag,rcCommit:$rcCommit,collectedAt:$collectedAt,startedAt:$startedAt,
    dedaImage:$dedaImage,githubRunnerImage:$githubRunner,azureRunnerImage:$azureRunner,gitlabRunnerImage:$gitlabRunner,
    dockerHost:$dockerHost,server:$server,publicIp:$publicIp,
    canonical:{
      fastQualification:$fast,
      fullDeterministicQualification:$full,
      github:$github,
      azurePipelines:$azure,
      gitlab:$gitlab,
      candidateMatched:($matched == "true"),
      releaseQualification:$release
    },
    containsSecrets:false
  }' > "$out/summary.json"

{
  printf '# DEDA v0.3 Hetzner release qualification\n\n'
  printf 'This summary does not recalculate provider PASS. Canonical files remain\n'
  printf '`result.json`, `manifest.json`, and `real-provider-result.json`.\n\n'
  printf '| Field | Value |\n| --- | --- |\n'
  printf '| RUN_ID | `%s` |\n' "$RUN_ID"
  printf '| RC tag | `%s` |\n' "$RC_TAG"
  printf '| RC commit | `%s` |\n' "$RC_COMMIT"
  printf '| DEDA image | `%s` |\n' "$DEDA_IMAGE"
  printf '| GitHub runner | `%s` |\n' "$GITHUB_QUAL_RUNNER_IMAGE"
  printf '| Azure runner | `%s` |\n' "$AZURE_QUAL_RUNNER_IMAGE"
  printf '| GitLab runner | `%s` |\n' "$GITLAB_QUAL_RUNNER_IMAGE"
  printf '| Server | `%s` |\n' "${MANAGER_1:-}"
  printf '| Docker endpoint | `%s` |\n' "$recorded_docker_host"
  printf '| Started | %s |\n' "$start_utc"
  printf '| Collected | %s |\n' "$end_utc"
  printf '\n| Gate | Status |\n| --- | --- |\n'
  printf '| fastQualification | %s |\n' "$fast"
  printf '| fullDeterministicQualification | %s |\n' "$full"
  printf '| GitHub real-provider | %s |\n' "$github"
  printf '| Azure Pipelines real-provider | %s |\n' "$azure"
  printf '| GitLab CI real-provider | %s |\n' "$gitlab"
  printf '| candidateMatched | %s |\n' "$matched"
  printf '| releaseQualification | %s |\n\n' "$release"
  printf 'Qualification is not promotion. Upload and `promote-release.yml` remain explicit.\n'
} > "$out/RESULT.md"
cp "$out/RESULT.md" "$root/HETZNER.md"

redact_tree "$out"
redact_tree "$root"
assert_no_token_leak "$out"
assert_no_token_leak "$root"
note "Hetzner evidence written to $out. Canonical evidence remains the source of truth under $root."
