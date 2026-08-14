#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); source "$SCRIPT_DIR/common.sh"; load_run
id=07; start_scenario "$id" 'DEDA restart and documented state reset'; dir=$(scenario_dir "$id")
service="${QUAL_STACK}_basic-worker"
delay_restored=0
cleanup() {
  if [[ "$delay_restored" == 0 ]]; then
    manager_exec "docker service update --label-add 'com.deda.autoscale.scaleDownDelaySeconds=0' '$service'" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# Use a window much longer than the restart so persisted recommendation history
# would keep the service at 10. A fresh in-memory store has no high recommendation
# and therefore reconciles directly to the current recommendation of 1.
manager_exec "docker service update --label-add 'com.deda.autoscale.scaleDownDelaySeconds=600' --label-add 'com.deda.autoscale.trigger.query=vector(100)' '$service'" >/dev/null; wait_replicas "$service" 10
manager_exec "docker service update --label-add 'com.deda.autoscale.trigger.query=vector(10)' '$service'" >/dev/null
printf 'scale-down-delay-started=%s\n' "$(utc_now)" > "$dir/timeline.txt"; sleep 10
[[ $(service_replicas "$service") == 10 ]] || fail_scenario "$id" 'Scale-down delay did not hold the pre-restart recommendation state.'
before=$(deda_leader); manager_exec "docker service update --force --update-parallelism 2 --update-order stop-first '${QUAL_STACK}_deda'" > "$dir/restart.txt"
wait_service_running "${QUAL_STACK}_deda" 2
for ((attempt=1; attempt<=45; attempt++)); do after=$(deda_leader); [[ -n "$after" ]] && break; sleep 2; done
[[ -n "${after:-}" ]] || fail_scenario "$id" 'Redis leadership did not stabilize after restarting both DEDA replicas.'
network_curl 'http://deda:8080/health/ready' > "$dir/readiness.txt" || fail_scenario "$id" 'DEDA readiness did not recover after restart.'
printf 'restart-ready=%s\n' "$(utc_now)" >> "$dir/timeline.txt"
actual=''
for ((attempt=1; attempt<=30; attempt++)); do
  actual=$(service_replicas "$service" 2>/dev/null || true)
  [[ "$actual" == 1 ]] && break
  sleep 2
done
[[ "$actual" == 1 ]] || fail_scenario "$id" 'Pre-restart scale-down history survived unexpectedly; the documented in-memory state did not reset.'
printf 'scale-down-after-reset=%s\n' "$(utc_now)" >> "$dir/timeline.txt"
manager_exec "docker service update --label-add 'com.deda.autoscale.scaleDownDelaySeconds=0' '$service'" >/dev/null
delay_restored=1
printf 'leader-before=%s\nleader-after=%s\n' "$before" "$after" > "$dir/leadership.txt"; capture_cluster "$dir"; finish_scenario "$id" PASS 'DEDA restarted, regained leadership/readiness, discarded its in-memory stabilization history, and reconciled to the current recommendation.'
