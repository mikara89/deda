#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

[[ "${1:-}" == --confirm-real-provider-tests ]] || die 'Real-provider qualification requires --confirm-real-provider-tests; credentials alone are never authorization.'
[[ $# -eq 1 ]] || die 'Usage: ./run-real.sh --confirm-real-provider-tests'

load_run
assert_rc_checkout
assert_all_candidate_pins
require_remote_docker_configured
validate_real_provider_config

export REAL_DEDA_IMAGE="$DEDA_IMAGE"
[[ "$REAL_DEDA_IMAGE" == "$DEDA_IMAGE" ]] || die 'REAL_DEDA_IMAGE must equal the prepared DEDA_IMAGE.'
apply_remote_docker
revision=$(image_oci_revision "$DEDA_IMAGE")
assert_revisions_match "$revision" "$RC_COMMIT"

canonical="$CANONICAL_DIR/real/run-all.sh"
[[ -x "$canonical" ]] || die "Canonical real-provider script is missing or not executable: $canonical"

note "Invoking canonical $canonical --confirm-real-provider-tests against $DOCKER_HOST"
invoke_canonical "$canonical" --confirm-real-provider-tests
