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
overlay="$root/overlay-identity.json"
if [[ ! -f "$overlay" ]]; then
  write_overlay_identity "$overlay" 2>/dev/null || printf '%s\n' '{}' > "$overlay"
fi
if [[ ${DEDA_QUAL_MODE:-} == full ]]; then
  jq -e '
    .github.candidateBaseDigest != ""
    and .github.labeledBaseDigest == .github.candidateBaseDigest
    and .azure.candidateBaseDigest != ""
    and .azure.labeledBaseDigest == .azure.candidateBaseDigest
    and .gitlab.candidateBaseDigest != ""
    and .gitlab.labeledBaseDigest == .gitlab.candidateBaseDigest
  ' "$overlay" >/dev/null || die 'qualification overlays are not bound to the selected candidate bases'
fi
jq -n --arg runId "$RUN_ID" --arg collectedAt "$(utc_now)" --arg candidateCommit "$commit" \
  --arg candidateImage "$DEDA_IMAGE" --arg dedaImageDigest "$(image_digest "$DEDA_IMAGE")" \
  --arg githubRunnerImage "$GITHUB_RUNNER_CANDIDATE_IMAGE" --arg githubRunnerDigest "$(image_digest "$GITHUB_RUNNER_CANDIDATE_IMAGE")" \
  --arg githubRunnerReferenceDigest "$(reference_digest "$GITHUB_RUNNER_CANDIDATE_IMAGE")" \
  --arg azureRunnerImage "$AZURE_RUNNER_CANDIDATE_IMAGE" --arg azureRunnerDigest "$(image_digest "$AZURE_RUNNER_CANDIDATE_IMAGE")" \
  --arg azureRunnerReferenceDigest "$(reference_digest "$AZURE_RUNNER_CANDIDATE_IMAGE")" \
  --arg gitlabRunnerImage "$GITLAB_RUNNER_CANDIDATE_IMAGE" --arg gitlabRunnerDigest "$(image_digest "$GITLAB_RUNNER_CANDIDATE_IMAGE")" \
  --arg gitlabRunnerReferenceDigest "$(reference_digest "$GITLAB_RUNNER_CANDIDATE_IMAGE")" \
  --slurpfile overlayIdentity "$overlay" \
  '{
    runId:$runId,qualification:"v0.3-ci",collectedAt:$collectedAt,candidateCommit:$candidateCommit,
    candidateImage:$candidateImage,dedaImageDigest:$dedaImageDigest,
    githubRunnerImage:$githubRunnerImage,githubRunnerDigest:$githubRunnerDigest,
    githubRunnerReferenceDigest:(if $githubRunnerReferenceDigest == "" then null else $githubRunnerReferenceDigest end),
    azureRunnerImage:$azureRunnerImage,azureRunnerDigest:$azureRunnerDigest,
    azureRunnerReferenceDigest:(if $azureRunnerReferenceDigest == "" then null else $azureRunnerReferenceDigest end),
    gitlabRunnerImage:$gitlabRunnerImage,gitlabRunnerDigest:$gitlabRunnerDigest,
    gitlabRunnerReferenceDigest:(if $gitlabRunnerReferenceDigest == "" then null else $gitlabRunnerReferenceDigest end),
    github:{candidateBaseImage:$githubRunnerImage,candidateBaseDigest:$githubRunnerDigest,qualificationOverlayImageId:($overlayIdentity[0].github.qualificationOverlayImageId // null)},
    azure:{candidateBaseImage:$azureRunnerImage,candidateBaseDigest:$azureRunnerDigest,qualificationOverlayImageId:($overlayIdentity[0].azure.qualificationOverlayImageId // null)},
    gitlab:{candidateBaseImage:$gitlabRunnerImage,candidateBaseDigest:$gitlabRunnerDigest,qualificationOverlayImageId:($overlayIdentity[0].gitlab.qualificationOverlayImageId // null)},
    overlayIdentity:($overlayIdentity[0] // null),
    containsSecrets:false
  }' > "$root/manifest.json"
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
