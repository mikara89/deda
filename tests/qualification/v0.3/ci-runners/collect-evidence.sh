#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/common.sh"
[[ ${1:-} == --run && -n ${2:-} ]] || die 'usage: collect-evidence.sh --run <RUN_ID>'
RUN_ID=$2; export RUN_ID
root=$(result_root); mkdir -p "$root"
capture_diagnostics_to "$root"
commit=$(git rev-parse HEAD)
printf '%s\n' "$commit" > "$root/candidate-commit.txt"
git status --short > "$root/worktree-status.txt"
jq -n --arg runId "$RUN_ID" --arg collectedAt "$(utc_now)" --arg candidateCommit "$commit" \
  --arg candidateImage "$DEDA_IMAGE" --arg dedaImageDigest "$(image_digest "$DEDA_IMAGE")" \
  --arg githubRunnerImage "$GITHUB_RUNNER_CANDIDATE_IMAGE" --arg githubRunnerDigest "$(image_digest "$GITHUB_RUNNER_CANDIDATE_IMAGE")" \
  --arg githubRunnerReferenceDigest "${GITHUB_RUNNER_CANDIDATE_IMAGE##*@}" \
  --arg azureRunnerImage "$AZURE_RUNNER_CANDIDATE_IMAGE" --arg azureRunnerDigest "$(image_digest "$AZURE_RUNNER_CANDIDATE_IMAGE")" \
  --arg azureRunnerReferenceDigest "${AZURE_RUNNER_CANDIDATE_IMAGE##*@}" \
  --arg gitlabRunnerImage "$GITLAB_RUNNER_CANDIDATE_IMAGE" --arg gitlabRunnerDigest "$(image_digest "$GITLAB_RUNNER_CANDIDATE_IMAGE")" \
  --arg gitlabRunnerReferenceDigest "${GITLAB_RUNNER_CANDIDATE_IMAGE##*@}" \
  '{runId:$runId,qualification:"v0.3-ci",collectedAt:$collectedAt,candidateCommit:$candidateCommit,candidateImage:$candidateImage,dedaImageDigest:$dedaImageDigest,githubRunnerImage:$githubRunnerImage,githubRunnerDigest:$githubRunnerDigest,githubRunnerReferenceDigest:$githubRunnerReferenceDigest,azureRunnerImage:$azureRunnerImage,azureRunnerDigest:$azureRunnerDigest,azureRunnerReferenceDigest:$azureRunnerReferenceDigest,gitlabRunnerImage:$gitlabRunnerImage,gitlabRunnerDigest:$gitlabRunnerDigest,gitlabRunnerReferenceDigest:$gitlabRunnerReferenceDigest,containsSecrets:false}' > "$root/manifest.json"
for id in 01 02 03 04 05 06 07 08 09 10; do
  dir="$root/scenario-$id"
  mkdir -p "$dir"
  file="$dir/result.json"
  [[ -f "$file" ]] || jq -n --arg scenario "$id" '{scenario:$scenario,status:"NOT_RUN",startedAt:null,finishedAt:null,durationSeconds:0,assertions:[],diagnostics:["scenario was not run"]}' > "$file"
done
mode=${DEDA_QUAL_MODE:-full}
fast_pass=true
for id in 01 02 03 05 06; do
  [[ $(jq -r .status "$root/scenario-$id/result.json") == PASS ]] || fast_pass=false
done
full_pass=true
if [[ "$mode" == full ]]; then
  for id in 01 02 03 04 05 06 07 08 09 10; do
    [[ $(jq -r .status "$root/scenario-$id/result.json") == PASS ]] || full_pass=false
  done
fi
scenarios_json=$(jq -s '.' "$root"/scenario-*/result.json)
jq -n --argjson scenarios "$scenarios_json" --arg mode "$mode" --arg fast "$fast_pass" --arg full "$full_pass" '
  {
    scenarios: $scenarios,
    mode: $mode,
    fastQualification: (if $fast == "true" then "PASS" else "FAIL" end),
    fullDeterministicQualification: (if $mode != "full" then "NOT_RUN" elif $full == "true" then "PASS" else "FAIL" end),
    releaseQualification: "NOT_QUALIFIED"
  }' > "$root/result.json"
{
  printf '# DEDA v0.3 CI runner qualification\n\n'
  printf '| Scenario | Deterministic status |\n| --- | --- |\n'
  jq -r '.scenarios[] | "| \(.scenario) | \(.status) |"' "$root/result.json"
  printf 'FAST DETERMINISTIC QUALIFICATION: **%s**\n\n' "$(jq -r .fastQualification "$root/result.json")"
  printf 'FULL DETERMINISTIC QUALIFICATION: **%s**\n\n' "$(jq -r .fullDeterministicQualification "$root/result.json")"
  printf 'RELEASE QUALIFICATION: **NOT_QUALIFIED**\n\n'
  printf 'No real-provider qualification is inferred from deterministic evidence.\n'
} > "$root/RESULT.md"
note "evidence written to $root"
