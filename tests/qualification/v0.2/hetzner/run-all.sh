#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); source "$SCRIPT_DIR/common.sh"; load_run
suite_status=0
for scenario in "$SCRIPT_DIR"/scenarios/[0-9][0-9]-*.sh; do
  note "Running $(basename "$scenario")"
  if ! "$scenario"; then
    id=$(basename "$scenario"); id=${id%%-*}
    current_status=$(jq -r '.status // "RUNNING"' "$(scenario_dir "$id")/result.json" 2>/dev/null || printf RUNNING)
    [[ "$current_status" != RUNNING ]] || finish_scenario "$id" FAIL 'Scenario script exited non-zero.'
    suite_status=1
    break
  fi
done
"$SCRIPT_DIR/collect-evidence.sh" || suite_status=1
exit "$suite_status"
