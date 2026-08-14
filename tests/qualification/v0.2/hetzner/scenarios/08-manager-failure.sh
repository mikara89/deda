#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); source "$SCRIPT_DIR/common.sh"; load_run
id=08; start_scenario "$id" 'Real Swarm manager failure'; dir=$(scenario_dir "$id")
docker_stopped=0; failed_public=''
cleanup() { if [[ "$docker_stopped" == 1 && -n "$failed_public" ]]; then ssh -i "$SSH_PRIVATE_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$RUN_DIR/known_hosts" "root@$failed_public" 'systemctl start docker.socket docker.service' >/dev/null 2>&1 || true; fi; }
trap cleanup EXIT
leader_private=$(manager_exec "docker node ls --filter role=manager --format '{{.ID}} {{.ManagerStatus}}' | awk '\$2 == \"Leader\" {print \$1}' | xargs -r docker node inspect --format '{{.Status.Addr}}'")
case "$leader_private" in "$MANAGER_1_PRIVATE") failed_public=$MANAGER_1_PUBLIC; control_public=$MANAGER_2_PUBLIC;; "$MANAGER_2_PRIVATE") failed_public=$MANAGER_2_PUBLIC; control_public=$MANAGER_1_PUBLIC;; "$MANAGER_3_PRIVATE") failed_public=$MANAGER_3_PUBLIC; control_public=$MANAGER_1_PUBLIC;; *) fail_scenario "$id" "Could not map Swarm leader private address $leader_private to a qualification node.";; esac
deda_before=$(deda_leader); printf 'swarm-leader-private-before=%s\ndeda-leader-before=%s\n' "$leader_private" "$deda_before" > "$dir/leaders.txt"
ssh_node MANAGER_1_PUBLIC true >/dev/null # establish host key before intentional outage
ssh -i "$SSH_PRIVATE_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$RUN_DIR/known_hosts" "root@$failed_public" 'systemctl stop docker.service docker.socket' > "$dir/stop-docker.txt"; docker_stopped=1
for attempt in $(seq 1 45); do new_leader=$(ssh -i "$SSH_PRIVATE_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$RUN_DIR/known_hosts" "root@$control_public" "docker node ls --format '{{.Status}} {{.ManagerStatus}}' | awk '\$1 == \"Ready\" && \$2 == \"Leader\" {print \$2}'" || true); [[ "$new_leader" == Leader ]] && break; sleep 2; done
[[ "${new_leader:-}" == Leader ]] || fail_scenario "$id" 'Swarm did not elect a replacement manager leader with one manager stopped.'
new_swarm_leader=$(ssh -i "$SSH_PRIVATE_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$RUN_DIR/known_hosts" "root@$control_public" "docker node ls --filter role=manager --format '{{.ID}} {{.ManagerStatus}}' | awk '\$2 == \"Leader\" {print \$1}' | xargs -r docker node inspect --format '{{.Status.Addr}}'")
ssh -i "$SSH_PRIVATE_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$RUN_DIR/known_hosts" "root@$control_public" "docker service update --label-add 'com.deda.autoscale.trigger.query=vector(100)' '${QUAL_STACK}_basic-worker'" > "$dir/scale-request.txt"
for attempt in $(seq 1 60); do current=$(ssh -i "$SSH_PRIVATE_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$RUN_DIR/known_hosts" "root@$control_public" "docker service inspect '${QUAL_STACK}_basic-worker' --format '{{.Spec.Mode.Replicated.Replicas}}'" || true); [[ "$current" == 10 ]] && break; sleep 2; done
[[ "${current:-}" == 10 ]] || fail_scenario "$id" 'DEDA could not complete a scale after Swarm manager failover.'
ssh -i "$SSH_PRIVATE_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$RUN_DIR/known_hosts" "root@$failed_public" 'systemctl start docker.socket docker.service' > "$dir/start-docker.txt"
docker_stopped=0
for ((attempt=1; attempt<=60; attempt++)); do ready=$(ssh -i "$SSH_PRIVATE_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$RUN_DIR/known_hosts" "root@$control_public" "docker node ls --format '{{.Status}}' | grep -c '^Ready'" || true); [[ "$ready" == 3 ]] && break; sleep 2; done
[[ "${ready:-}" == 3 ]] || fail_scenario "$id" 'Stopped manager did not rejoin in Ready state.'
printf 'swarm-leader-private-after=%s\ndeda-leader-after=%s\n' "$new_swarm_leader" "$(deda_leader)" >> "$dir/leaders.txt"; capture_cluster "$dir"; finish_scenario "$id" PASS 'One Swarm manager failed and recovered while quorum and DEDA reconciliation continued; Swarm Raft and DEDA Redis lease leadership were recorded separately.'
