#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
case "${1:-}" in
  provision) exec "$SCRIPT_DIR/provision.sh" "${@:2}";;
  configure) exec "$SCRIPT_DIR/configure-swarm.sh" "${@:2}";;
  deploy) exec "$SCRIPT_DIR/deploy-stack.sh" "${@:2}";;
  run) exec "$SCRIPT_DIR/run-all.sh" "${@:2}";;
  collect) exec "$SCRIPT_DIR/collect-evidence.sh" "${@:2}";;
  destroy) exec "$SCRIPT_DIR/destroy.sh" "${@:2}";;
  *) echo 'Usage: qualify.sh {provision|configure|deploy|run|collect|destroy}' >&2; exit 2;;
esac
