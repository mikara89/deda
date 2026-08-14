#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/common.sh"
confirm_real "${1:-}"
export_real_candidate_images
init_run
overall=0
for provider in github azure-pipelines gitlab; do
  bash "$SCRIPT_DIR/$provider.sh" --confirm-real-provider-tests || overall=1
done
root=$(result_root)
for provider in github azure-pipelines gitlab; do
  result="$root/real-$provider/result.json"
  if [[ ! -f "$result" ]]; then
    mkdir -p "$(dirname "$result")"
    jq -n --arg provider "$provider" --arg at "$(utc_now)" '{provider:$provider,status:"FAIL",at:$at,detail:"Provider harness exited before it produced evidence."}' > "$result"
    overall=1
  fi
done
deterministic=NOT_RUN
[[ -f "$root/result.json" ]] && deterministic=$(jq -r .deterministicQualification "$root/result.json")
candidate_matched=1
manifest="$root/manifest.json"
if [[ ! -f "$manifest" ]]; then
  candidate_matched=0
else
  deterministic_commit=$(jq -r .candidateCommit "$manifest")
  deterministic_image=$(jq -r .candidateImage "$manifest")
  deterministic_digest=$(jq -r .dedaImageDigest "$manifest")
  [[ -n "$deterministic_commit" && -n "$deterministic_image" && -n "$deterministic_digest" ]] || candidate_matched=0
  candidate_reference=""
  for provider in github azure-pipelines gitlab; do
    [[ $candidate_matched -eq 1 ]] || break
    candidate="$root/real-$provider/candidate.json"
    if [[ ! -f "$candidate" ]] \
      || [[ $(jq -r .candidateCommit "$candidate") != "$deterministic_commit" ]] \
      || [[ $(jq -r .dedaImage "$candidate") != "$deterministic_image" ]] \
      || [[ $(jq -r .dedaDigest "$candidate") != "$deterministic_digest" ]]; then
      candidate_matched=0
    fi
    if [[ $candidate_matched -eq 1 ]]; then
      if [[ -z "$candidate_reference" ]]; then
        candidate_reference="$candidate"
      fi
      for field in githubRunnerImage githubRunnerReferenceDigest azureRunnerImage azureRunnerReferenceDigest gitlabRunnerImage gitlabRunnerReferenceDigest; do
        [[ -n "$(jq -r ."$field" "$candidate")" ]] || candidate_matched=0
        [[ $(jq -r ."$field" "$candidate") == "$(jq -r ."$field" "$candidate_reference")" ]] || candidate_matched=0
        [[ $candidate_matched -eq 1 ]] || break
      done
    fi
  done
fi
candidate_matched_arg=false
[[ $candidate_matched -eq 1 ]] && candidate_matched_arg=true
candidate_json='{}'
if [[ $candidate_matched -eq 1 ]]; then
  candidate_json=$(jq -s '.[0] | {commit:.candidateCommit,deda:.dedaDigest,githubRunner:.githubRunnerReferenceDigest,azureRunner:.azureRunnerReferenceDigest,gitlabRunner:.gitlabRunnerReferenceDigest}' "$root"/real-*/candidate.json)
fi
jq -s --arg deterministic "$deterministic" --arg candidateMatched "$candidate_matched_arg" --argjson candidate "$candidate_json" '
  {providers: ., deterministicQualification:$deterministic, candidateMatched:($candidateMatched == "true"), candidate:$candidate}
  | .providerStatuses = [.providers[] | .status]
  | .releaseQualification =
      (if any(.providerStatuses[]; . == "FAIL") then "FAIL"
       elif .candidateMatched != true then "NOT_QUALIFIED"
       elif .deterministicQualification != "PASS" then "NOT_QUALIFIED"
       elif all(.providerStatuses[]; . == "PASS") then "PASS"
       else "NOT_QUALIFIED" end)
  | del(.providerStatuses)' "$root"/real-*/result.json > "$root/real-provider-result.json"
printf 'Real-provider evidence: %s\n' "$root"
[[ $(jq -r .releaseQualification "$root/real-provider-result.json") == PASS && $overall -eq 0 ]] || exit 1
