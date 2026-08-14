#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); source "$SCRIPT_DIR/common.sh"; load_run
id=06; start_scenario "$id" 'Scale-to-zero grace reset'; dir=$(scenario_dir "$id"); service="${QUAL_STACK}_zero-worker"
manager_exec "docker service update --label-add 'com.deda.autoscale.trigger.query=vector(100)' '$service'" >/dev/null; wait_replicas "$service" 5
manager_exec "docker service update --label-add 'com.deda.autoscale.trigger.query=vector(0)' '$service'" >/dev/null; printf 'valid-zero-start=%s\n' "$(utc_now)" > "$dir/timeline.txt"; sleep 15
manager_exec "docker service update --label-add 'com.deda.autoscale.trigger.url=http://missing-prometheus:9090' '$service'" >/dev/null; printf 'trigger-failure=%s\n' "$(utc_now)" >> "$dir/timeline.txt"; sleep 12
[[ $(service_replicas "$service") == 5 ]] || fail_scenario "$id" 'Scale-to-zero grace was not reset by trigger failure.'
manager_exec "docker service update --label-add 'com.deda.autoscale.trigger.url=http://prometheus:9090' '$service'" >/dev/null; printf 'valid-zero-recovery=%s\n' "$(utc_now)" >> "$dir/timeline.txt"; sleep 15
[[ $(service_replicas "$service") == 5 ]] || fail_scenario "$id" 'Service reached zero before the full restarted grace interval elapsed.'
wait_replicas "$service" 0; printf 'scaled-zero=%s\n' "$(utc_now)" >> "$dir/timeline.txt"
manager_exec "docker service update --label-add 'com.deda.autoscale.trigger.query=vector(20)' '$service'" >/dev/null; wait_replicas "$service" 2; printf 'recovered-from-zero=%s\n' "$(utc_now)" >> "$dir/timeline.txt"
capture_cluster "$dir"; finish_scenario "$id" PASS 'Trigger failure reset inactivity evidence; valid zero completed grace and later scaled from zero.'
