#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); source "$SCRIPT_DIR/common.sh"; load_run
id=01; start_scenario "$id" 'Basic multi-node scale'
service="${QUAL_STACK}_basic-worker"; dir=$(scenario_dir "$id")
network_curl 'http://prometheus:9090/api/v1/query?query=sum(deda_reconcile_failures_total)' > "$dir/reconcile-failures-before.json"
manager_exec "docker service update --label-add 'com.deda.autoscale.trigger.query=vector(10)' '$service'" > "$dir/baseline-request.txt"
wait_replicas "$service" 1; wait_service_running "$service" 1
manager_exec "docker service inspect '$service'" > "$dir/service-at-one.json"
manager_exec "docker service update --label-add 'com.deda.autoscale.trigger.query=vector(100)' '$service'" > "$dir/request-up.txt"
wait_replicas "$service" 10; wait_service_running "$service" 10
manager_exec "docker service ps '$service' --format '{{.Node}} {{.CurrentState}}'" > "$dir/task-placement.txt"
[[ $(awk '/^.* Running/{print $1}' "$dir/task-placement.txt" | sort -u | wc -l) -ge 2 ]] || fail_scenario "$id" 'Ten workload tasks were not scheduled across at least two nodes.'
network_curl 'http://prometheus:9090/api/v1/query?query=deda_scale_events_total' > "$dir/deda-metrics.json"
manager_exec "docker service update --label-add 'com.deda.autoscale.trigger.query=vector(10)' '$service'" > "$dir/request-down.txt"
wait_replicas "$service" 1
network_curl 'http://prometheus:9090/api/v1/query?query=sum(deda_reconcile_failures_total)' > "$dir/reconcile-failures-after.json"
before_failures=$(jq -r '([.data.result[]?.value[1] | tonumber] | add) // 0' "$dir/reconcile-failures-before.json"); after_failures=$(jq -r '([.data.result[]?.value[1] | tonumber] | add) // 0' "$dir/reconcile-failures-after.json")
awk -v before="$before_failures" -v after="$after_failures" 'BEGIN { exit !(after <= before) }' || fail_scenario "$id" "Reconciliation failures increased during basic scaling ($before_failures to $after_failures)."
capture_cluster "$dir"; finish_scenario "$id" PASS 'Scaled 1 to 10 across multiple nodes and back to 1 without increasing reconciliation failures.'
