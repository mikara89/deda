#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

load_run
assert_rc_checkout
assert_all_candidate_pins
require_remote_docker_configured
apply_remote_docker
docker info >/dev/null || die 'Local docker CLI cannot reach the Hetzner Docker daemon over SSH.'
revision=$(image_oci_revision "$DEDA_IMAGE")
assert_revisions_match "$revision" "$RC_COMMIT"

canonical="$CANONICAL_DIR/run-deterministic.sh"
[[ -x "$canonical" ]] || die "Canonical deterministic script is missing or not executable: $canonical"

note "Invoking canonical $canonical --fast against $DOCKER_HOST"
invoke_canonical "$canonical" --fast

note "Invoking canonical $canonical --full against $DOCKER_HOST"
invoke_canonical "$canonical" --full

root=$(canonical_result_dir "$RUN_ID")
[[ -f "$root/result.json" ]] || die "Canonical result.json was not produced at $root"
fast=$(jq -r '.fastQualification // empty' "$root/result.json")
full=$(jq -r '.fullDeterministicQualification // empty' "$root/result.json")
[[ "$fast" == PASS ]] || die "fastQualification is $fast, expected PASS"
[[ "$full" == PASS ]] || die "fullDeterministicQualification is $full, expected PASS"
release=$(jq -r '.releaseQualification // empty' "$root/result.json")
[[ "$release" != PASS ]] || die 'Canonical deterministic evidence must not report releaseQualification PASS.'
note "Deterministic qualification passed (fast=PASS full=PASS). releaseQualification remains $release."
