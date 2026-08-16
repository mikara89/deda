#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
usage() {
  printf '%s\n' \
    'Usage: qualify.sh <command> [args]' \
    '' \
    'Commands:' \
    '  prepare         Pin an already-published RC and publish runner images' \
    '  provision       Create the temporary Hetzner Swarm manager (--dry-run supported)' \
    '  configure       Wait for Docker, init one-node Swarm, set Docker-over-SSH' \
    '  deterministic   Run canonical fast + full deterministic qualification' \
    '  real            Run canonical real-provider qualification (requires --confirm-real-provider-tests)' \
    '  run             Deterministic + real + collect (requires --confirm-real-provider-tests)' \
    '  collect         Add Hetzner metadata around canonical v0.3 evidence' \
    '  upload          Attach PASS evidence to the RC GitHub Release (requires --confirm-evidence-upload)' \
    '  destroy         Delete only exact labelled resources for --run <RUN_ID>' \
    '' \
    'Individual scripts remain runnable for diagnosis. This harness does not' \
    'promote a release, create tags, or run real SaaS tests from credentials alone.' >&2
  exit 2
}
case "${1:-}" in
  prepare) exec "$SCRIPT_DIR/prepare-candidate.sh" "${@:2}";;
  provision) exec "$SCRIPT_DIR/provision.sh" "${@:2}";;
  configure) exec "$SCRIPT_DIR/configure-swarm.sh" "${@:2}";;
  deterministic) exec "$SCRIPT_DIR/run-deterministic.sh" "${@:2}";;
  real) exec "$SCRIPT_DIR/run-real.sh" "${@:2}";;
  run) exec "$SCRIPT_DIR/run-all.sh" "${@:2}";;
  collect) exec "$SCRIPT_DIR/collect-evidence.sh" "${@:2}";;
  upload) exec "$SCRIPT_DIR/upload-evidence.sh" "${@:2}";;
  destroy) exec "$SCRIPT_DIR/destroy.sh" "${@:2}";;
  -h|--help|help) usage;;
  *) printf 'ERROR: unknown command: %s\n\n' "${1:-}" >&2; usage;;
esac
