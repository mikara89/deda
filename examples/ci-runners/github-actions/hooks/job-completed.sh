#!/usr/bin/env bash
set -Eeuo pipefail
state_dir=${DEDA_RUNNER_STATE_DIR:?DEDA_RUNNER_STATE_DIR is required}
rm -f "$state_dir/busy"
