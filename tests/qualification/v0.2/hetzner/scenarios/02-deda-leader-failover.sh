#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); source "$SCRIPT_DIR/common.sh"; load_run
id=02; start_scenario "$id" 'DEDA Redis-lease leader failover'; dir=$(scenario_dir "$id";)
before=$(deda_leader); [[ -n "$before" ]] || fail_scenario "$id" 'No active DEDA Redis lease owner was found.'
printf 'leader-before=%s\nstarted=%s\n' "$before" "$(utc_now)" > "$dir/leadership.txt"
leader_container=''; standby_hostname=''
for node in MANAGER_1_PUBLIC MANAGER_2_PUBLIC MANAGER_3_PUBLIC; do
  while read -r container; do
    [[ -n "$container" ]] || continue
    hostname=$(ssh_node "$node" "docker inspect '$container' --format '{{.Config.Hostname}}'" 2>/dev/null || true)
    if [[ "$before" == "$hostname"* ]]; then leader_container="$node:$container"; else standby_hostname=$hostname; fi
  done < <(ssh_node "$node" "docker ps --filter label=com.docker.swarm.service.name=${QUAL_STACK}_deda --format '{{.ID}}'" || true)
done
[[ -n "$leader_container" ]] || fail_scenario "$id" "Could not map Redis lease owner $before to a DEDA task."
[[ -n "$standby_hostname" ]] || fail_scenario "$id" 'Could not identify the existing standby DEDA task.'
node=${leader_container%%:*}; container=${leader_container#*:}; ssh_node "$node" "docker kill '$container'" > "$dir/killed-task.txt"
manager_exec "docker service update --label-add 'com.deda.autoscale.trigger.query=vector(100)' '${QUAL_STACK}_basic-worker'" >/dev/null
for attempt in $(seq 1 45); do after=$(deda_leader); [[ -n "$after" && "$after" != "$before" ]] && break; sleep 2; done
[[ "${after:-}" != "$before" && -n "${after:-}" ]] || fail_scenario "$id" 'Standby did not acquire a different Redis lease after the expected interval.'
[[ "$after" == "$standby_hostname"* ]] || fail_scenario "$id" "Lease moved to $after instead of the existing standby $standby_hostname."
wait_replicas "${QUAL_STACK}_basic-worker" 10
printf 'leader-after=%s\nended=%s\nfailover-seconds=%s\n' "$after" "$(utc_now)" "$((attempt * 2))" >> "$dir/leadership.txt"
capture_cluster "$dir"; finish_scenario "$id" PASS 'Killed only the active DEDA task; standby acquired the lease and reconciled.'
