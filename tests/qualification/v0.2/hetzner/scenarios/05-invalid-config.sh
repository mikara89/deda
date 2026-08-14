#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); source "$SCRIPT_DIR/common.sh"; load_run
id=05; start_scenario "$id" 'Fail-closed invalid label configuration'; dir=$(scenario_dir "$id")
invalid="${QUAL_STACK}_invalid-config"; cleanup() { manager_exec "docker service rm '$invalid'" >/dev/null 2>&1 || true; }; trap cleanup EXIT
valid="${QUAL_STACK}_basic-worker"; manager_exec "docker service update --label-add 'com.deda.autoscale.trigger.query=vector(10)' '$valid'" >/dev/null; wait_replicas "$valid" 1
manager_exec "docker service rm '$invalid' >/dev/null 2>&1 || true; docker service create --name '$invalid' --network '$(network_name)' --replicas 1 --label com.deda.autoscale.enabled=true --label com.deda.autoscale.min=1 --label com.deda.autoscale.max=5O --label com.deda.autoscale.targetPerReplica=10 --label com.deda.autoscale.trigger.type=prometheus --label com.deda.autoscale.trigger.url=http://prometheus:9090 --label 'com.deda.autoscale.trigger.query=vector(100)' alpine:3.22 sleep infinity" > "$dir/create-invalid.txt"
sleep 12; [[ $(service_replicas "$invalid") == 1 ]] || fail_scenario "$id" 'Invalid service was mutated instead of skipped.'
manager_exec "docker service update --label-add 'com.deda.autoscale.trigger.query=vector(100)' '$valid'" >/dev/null; wait_replicas "$valid" 10
manager_exec "timeout 30s docker service logs --tail 300 '${QUAL_STACK}_deda'" > "$dir/deda-logs.txt" 2>&1 || true
grep -Eqi 'max|configuration|invalid' "$dir/deda-logs.txt" || fail_scenario "$id" 'Expected invalid-label configuration error was not present in DEDA logs.'
manager_exec "docker service rm '$invalid'" >/dev/null; capture_cluster "$dir"; finish_scenario "$id" PASS 'Malformed label was skipped while valid service continued to reconcile.'
