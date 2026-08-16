#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

[[ "${1:-}" == --confirm-real-provider-tests ]] || die 'qualify.sh run requires --confirm-real-provider-tests; credentials alone are never authorization.'
[[ $# -eq 1 ]] || die 'Usage: ./run-all.sh --confirm-real-provider-tests'

load_run
assert_rc_checkout
assert_all_candidate_pins
require_remote_docker_configured
apply_remote_docker
docker info >/dev/null || die 'Local docker CLI cannot reach the Hetzner Docker daemon over SSH.'
validate_real_provider_config

note 'Running canonical deterministic fast + full qualification'
"$SCRIPT_DIR/run-deterministic.sh"

root=$(canonical_result_dir "$RUN_ID")
fast=$(jq -r '.fastQualification // empty' "$root/result.json")
full=$(jq -r '.fullDeterministicQualification // empty' "$root/result.json")
[[ "$fast" == PASS && "$full" == PASS ]] || die "Deterministic qualification did not PASS (fast=$fast full=$full)."

note 'Running canonical real-provider qualification'
"$SCRIPT_DIR/run-real.sh" --confirm-real-provider-tests

note 'Collecting Hetzner evidence around canonical results'
"$SCRIPT_DIR/collect-evidence.sh"

aggregate="$root/real-provider-result.json"
[[ -f "$aggregate" ]] || die 'Canonical real-provider-result.json is missing after the real run.'
release=$(jq -r '.releaseQualification // empty' "$aggregate")
matched=$(jq -r '.candidateMatched // empty' "$aggregate")
printf 'fullDeterministicQualification=%s\ncandidateMatched=%s\nreleaseQualification=%s\n' \
  "$(jq -r '.fullDeterministicQualification // empty' "$aggregate")" "$matched" "$release"
[[ "$release" == PASS && "$matched" == true ]] || die "Aggregate is not a release qualification PASS (releaseQualification=$release candidateMatched=$matched)."
note 'Release qualification PASS. Upload and promotion remain explicit operator actions.'
