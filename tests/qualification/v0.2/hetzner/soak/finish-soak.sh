#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); source "$SCRIPT_DIR/common.sh"; load_run
wait_requested=0; [[ "${1:-}" == --wait ]] && wait_requested=1
if [[ "$wait_requested" == 1 ]]; then while manager_exec 'systemctl is-active --quiet deda-qualification-soak.service'; do sleep 30; done; fi
if manager_exec 'systemctl is-active --quiet deda-qualification-soak.service'; then echo RUNNING; exit 0; fi
out="$(result_dir "$RUN_ID")/soak"; mkdir -p "$out"
copy_from_node MANAGER_1_PUBLIC "/var/lib/deda-qualification/$RUN_ID/soak/result.json" "$out/result.json" 2>/dev/null || { echo '{"status":"NOT_RUN"}' > "$out/result.json"; }
copy_from_node MANAGER_1_PUBLIC "/var/lib/deda-qualification/$RUN_ID/soak/driver.log" "$out/driver.log" 2>/dev/null || true
copy_from_node MANAGER_1_PUBLIC "/var/lib/deda-qualification/$RUN_ID/soak/samples.txt" "$out/samples.txt" 2>/dev/null || true
copy_from_node MANAGER_1_PUBLIC "/var/lib/deda-qualification/$RUN_ID/soak/deda-metrics.txt" "$out/deda-metrics.txt" 2>/dev/null || true
copy_from_node MANAGER_1_PUBLIC "/var/lib/deda-qualification/$RUN_ID/soak/deda-service.log" "$out/deda-service.log" 2>/dev/null || true
copy_from_node MANAGER_1_PUBLIC "/var/lib/deda-qualification/$RUN_ID/soak/node-stats.log" "$out/node-stats.log" 2>/dev/null || true
copy_from_node MANAGER_1_PUBLIC "/var/lib/deda-qualification/$RUN_ID/soak/recovery-failures.txt" "$out/recovery-failures.txt" 2>/dev/null || true
status=$(jq -r .status "$out/result.json")
if [[ "$status" == PASS ]] && grep -Eqi 'out of memory|oomkilled|dual leadership|panic|fatal' "$out/driver.log" "$out/deda-service.log" "$out/samples.txt" 2>/dev/null; then jq '.status="FAIL" | .reason="failure signal in soak evidence"' "$out/result.json" > "$out/result.tmp" && mv "$out/result.tmp" "$out/result.json"; status=FAIL; fi
echo "$status"
