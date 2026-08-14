#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/common.sh"
[[ ${1:-} == --run && -n ${2:-} ]] || die 'usage: collect-evidence.sh --run <RUN_ID>'
RUN_ID=$2; export RUN_ID
root=$(result_root); mkdir -p "$root"
capture_diagnostics "$root"
commit=$(git rev-parse HEAD)
printf '%s\n' "$commit" > "$root/candidate-commit.txt"
git status --short > "$root/worktree-status.txt"
jq -n --arg runId "$RUN_ID" --arg collectedAt "$(utc_now)" --arg candidateCommit "$commit" --arg candidateImage "$DEDA_IMAGE" \
  '{runId:$runId,qualification:"v0.3-ci",collectedAt:$collectedAt,candidateCommit:$candidateCommit,candidateImage:$candidateImage,containsSecrets:false}' > "$root/manifest.json"
for id in 01 02 03 04 05 06 07 08 09 10; do
  file="$root/scenario-$id/result.json"
  [[ -f "$file" ]] || jq -n --arg scenario "$id" '{scenario:$scenario,status:"NOT_RUN",startedAt:null,finishedAt:null,durationSeconds:0,assertions:[],diagnostics:["scenario was not run"]}' > "$file"
done
jq -s '{scenarios: ., deterministicQualification: (if all(.[]; .status == "PASS") then "PASS" else "FAIL" end), releaseQualification:"NOT_QUALIFIED"}' "$root"/scenario-*/result.json > "$root/result.json"
{
  printf '# DEDA v0.3 CI runner qualification\n\n'
  printf '| Scenario | Deterministic status |\n| --- | --- |\n'
  jq -r '.scenarios[] | "| \(.scenario) | \(.status) |"' "$root/result.json"
  printf '\nDETERMINISTIC QUALIFICATION: **%s**\n\n' "$(jq -r .deterministicQualification "$root/result.json")"
  printf 'RELEASE QUALIFICATION: **NOT_QUALIFIED**\n\n'
  printf 'No real-provider qualification is inferred from deterministic evidence.\n'
} > "$root/RESULT.md"
note "evidence written to $root"
