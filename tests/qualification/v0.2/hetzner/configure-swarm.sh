#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/common.sh"
load_run

mkdir -p "$(result_dir "$RUN_ID")/docker-info"
for node in MANAGER_1_PUBLIC MANAGER_2_PUBLIC MANAGER_3_PUBLIC; do
  if ! ssh_node "$node" 'timeout 900 cloud-init status --wait && docker info >/dev/null'; then
    copy_from_node "$node" /var/log/cloud-init.log "$(result_dir "$RUN_ID")/docker-info/cloud-init-${node}.log" 2>/dev/null || true
    copy_from_node "$node" /var/log/cloud-init-output.log "$(result_dir "$RUN_ID")/docker-info/cloud-init-output-${node}.log" 2>/dev/null || true
    die "Cloud-init or Docker bootstrap failed on ${!node}; logs were copied to the run evidence directory where available."
  fi
done
manager_exec "docker swarm init --advertise-addr '$MANAGER_1_PRIVATE' --data-path-addr '$MANAGER_1_PRIVATE'" || {
  manager_exec 'docker node ls' >/dev/null 2>&1 || die 'Failed to initialize Docker Swarm on manager-1.'
}
join_token=$(manager_exec 'docker swarm join-token -q manager')
for node in MANAGER_2_PUBLIC MANAGER_3_PUBLIC; do
  private_var=${node/_PUBLIC/_PRIVATE}; private_ip=${!private_var}
  ssh_node "$node" "docker swarm join --token '$join_token' --advertise-addr '$private_ip' --data-path-addr '$private_ip' '$MANAGER_1_PRIVATE:2377'" || true
done
for ((attempt=1; attempt<=60; attempt++)); do
  ready=$(manager_exec "docker node ls --filter role=manager --format '{{.Status}}' | grep -c '^Ready$' || true" || true)
  [[ "$ready" == 3 ]] && break
  sleep 3
done
[[ "${ready:-0}" == 3 ]] || die 'Timed out waiting for three Ready Swarm managers.'
mkdir -p "$(result_dir "$RUN_ID")"
manager_exec 'docker node ls' > "$(result_dir "$RUN_ID")/docker-node-ls.txt"
manager_exec 'docker info' > "$(result_dir "$RUN_ID")/docker-info-manager-1.txt"
note 'Swarm configured: three Ready manager nodes; private addresses are used for Raft and data traffic.'
