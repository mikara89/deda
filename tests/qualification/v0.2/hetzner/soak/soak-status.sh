#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); source "$SCRIPT_DIR/common.sh"; load_run
remote="/var/lib/deda-qualification/$RUN_ID/soak/result.json"
if manager_exec 'systemctl is-active --quiet deda-qualification-soak.service'; then
  echo 'RUNNING'
  manager_exec "started=\$(systemctl show deda-qualification-soak.service -p ActiveEnterTimestamp --value); printf 'elapsed_seconds=%s\n' \"\$((\$(date -u +%s) - \$(date -u -d \"\$started\" +%s)))\"; tail -n 5 '/var/lib/deda-qualification/$RUN_ID/soak/driver.log' 2>/dev/null || true"
  exit 0
fi
if manager_exec "test -f '$remote'"; then manager_exec "jq -r .status '$remote'"; manager_exec "jq -r '\"elapsed_seconds=\" + (((.ended | fromdateiso8601) - (.started | fromdateiso8601)) | floor | tostring)' '$remote'; tail -n 5 '/var/lib/deda-qualification/$RUN_ID/soak/driver.log' 2>/dev/null || true"; exit 0; fi
echo NOT_FOUND; exit 3
