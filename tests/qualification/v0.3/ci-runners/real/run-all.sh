#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/common.sh"
confirm_real "${1:-}"
init_run
overall=0
for provider in github azure-pipelines gitlab; do
  "$SCRIPT_DIR/$provider.sh" --confirm-real-provider-tests || overall=1
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
jq -s --arg deterministic "$deterministic" '
  {providers: ., deterministicQualification:$deterministic}
  | .providerStatuses = [.providers[] | .status]
  | .releaseQualification =
      (if any(.providerStatuses[]; . == "FAIL") then "FAIL"
       elif .deterministicQualification != "PASS" then "NOT_QUALIFIED"
       elif all(.providerStatuses[]; . == "PASS") then "PASS"
       else "NOT_QUALIFIED" end)
  | del(.providerStatuses)' "$root"/real-*/result.json > "$root/real-provider-result.json"
printf 'Real-provider evidence: %s\n' "$root"
[[ $(jq -r .releaseQualification "$root/real-provider-result.json") == PASS && $overall -eq 0 ]] || exit 1
