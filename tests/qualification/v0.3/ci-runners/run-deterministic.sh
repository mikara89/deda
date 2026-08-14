#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

mode=${1:---full}
[[ "$mode" == --fast || "$mode" == --full ]] || die 'usage: run-deterministic.sh [--fast|--full]'
init_run
on_exit() {
  local status=$?
  capture_diagnostics_to "$(result_root)"
  if (( status != 0 )); then "$SCRIPT_DIR/collect-evidence.sh" --run "$RUN_ID" || true; fi
  cleanup_stack
  exit "$status"
}
trap on_exit EXIT
if [[ "$mode" == --full ]]; then
  ensure_runner_qualification_images
  export GITHUB_RUNNER_IMAGE="$GITHUB_RUNNER_QUALIFICATION_IMAGE"
  export AZURE_RUNNER_IMAGE="$AZURE_RUNNER_QUALIFICATION_IMAGE"
  export GITLAB_RUNNER_IMAGE="$GITLAB_RUNNER_QUALIFICATION_IMAGE"
fi
prepare_stack

scenarios=(01-github-capacity 02-azure-capacity 03-gitlab-capacity 05-provider-failure 06-observation-cache)
if [[ "$mode" == --full ]]; then
  scenarios+=(04-active-job-protection 07-ha-failover 08-credential-security 09-scale-to-zero 10-lifecycle-cleanup)
fi
for scenario in "${scenarios[@]}"; do bash "$SCRIPT_DIR/scenarios/$scenario.sh"; done
"$SCRIPT_DIR/collect-evidence.sh" --run "$RUN_ID"
note "deterministic v0.3 qualification complete: $(result_root)"
