#!/usr/bin/env bash
# Shared local-orchestrator helpers. HCLOUD_TOKEN deliberately never crosses SSH.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../../" && pwd)
LEGACY_RUNTIME_ROOT="$SCRIPT_DIR/.runtime"
if [[ -n "${DEDA_QUAL_RUNTIME_ROOT:-}" ]]; then
  RUNTIME_ROOT=$DEDA_QUAL_RUNTIME_ROOT
elif [[ "$SCRIPT_DIR" == /mnt/* ]] && grep -Eqi '(microsoft|wsl)' /proc/sys/kernel/osrelease 2>/dev/null; then
  RUNTIME_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/deda-qualification/hetzner"
else
  RUNTIME_ROOT=$LEGACY_RUNTIME_ROOT
fi
RESULTS_ROOT="$REPO_ROOT/tests/qualification/results"
QUAL_STACK=${DEDA_QUAL_STACK:-deda-qual}
[[ "$QUAL_STACK" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || { printf 'ERROR: DEDA_QUAL_STACK contains unsupported characters.\n' >&2; exit 1; }
export RUNTIME_ROOT LEGACY_RUNTIME_ROOT

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf '[qualification] %s\n' "$*" >&2; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }
utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
new_run_id() { printf '%s-%s\n' "$(date -u +%Y%m%d-%H%M%S)" "$(od -An -N3 -tx1 </dev/urandom | tr -d ' \n')"; }
safe_label_value() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9_.-' '-'; }
duration_to_seconds() {
  local duration=$1 value unit
  [[ "$duration" =~ ^([1-9][0-9]*)([hm])$ ]] || return 1
  value=${BASH_REMATCH[1]}
  unit=${BASH_REMATCH[2]}
  if [[ "$unit" == h ]]; then
    printf '%s\n' "$((value * 3600))"
  else
    printf '%s\n' "$((value * 60))"
  fi
}

init_defaults() {
  : "${DEDA_QUAL_LOCATION:=nbg1}" "${DEDA_QUAL_SERVER_TYPE:=cx23}" "${DEDA_QUAL_IMAGE:=ubuntu-24.04}"
  : "${DEDA_QUAL_NETWORK_CIDR:=10.42.0.0/16}" "${DEDA_QUAL_SUBNET_CIDR:=10.42.0.0/24}"
  : "${DEDA_QUAL_NETWORK_ZONE:=eu-central}" "${DEDA_QUAL_PREFIX:=deda-q}"
  export DEDA_QUAL_LOCATION DEDA_QUAL_SERVER_TYPE DEDA_QUAL_IMAGE DEDA_QUAL_NETWORK_CIDR DEDA_QUAL_SUBNET_CIDR DEDA_QUAL_NETWORK_ZONE DEDA_QUAL_PREFIX
}

state_dir() { printf '%s/%s' "$RUNTIME_ROOT" "$1"; }
state_file() { printf '%s/state.env' "$(state_dir "$1")"; }
result_dir() { printf '%s/%s' "$RESULTS_ROOT" "$1"; }

save_state() {
  local key value file
  file=$(state_file "$RUN_ID")
  mkdir -p "$(dirname "$file")"
  : > "$file"
  for key in "$@"; do
    value=${!key-}
    printf '%s=%q\n' "$key" "$value" >> "$file"
  done
}

load_run() {
  if [[ -z "${RUN_ID:-}" && -f "$RUNTIME_ROOT/current" ]]; then RUN_ID=$(<"$RUNTIME_ROOT/current"); fi
  [[ -n "${RUN_ID:-}" ]] || die 'RUN_ID is required; run provision.sh first or export RUN_ID.'
  [[ -f "$(state_file "$RUN_ID")" ]] || die "No local state exists for RUN_ID $RUN_ID."
  # shellcheck disable=SC1090
  source "$(state_file "$RUN_ID")"
  [[ "${DEDA_IMAGE:-}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._/@:-]+$ ]] || die 'Saved DEDA_IMAGE contains unsupported image-reference characters.'
  export RUN_ID
}

labels() { printf 'purpose=deda-qualification,version=v0-2,run=%s,expires_at=%s' "$(safe_label_value "$RUN_ID")" "${QUAL_EXPIRY_UTC:?QUAL_EXPIRY_UTC must be set}"; }
quote_remote_args() { local arg quoted; for arg in "$@"; do printf -v quoted '%q' "$arg"; printf ' %s' "$quoted"; done; }
network_http_status() { local args; args=$(quote_remote_args "$@"); manager_exec "docker run --rm --network '$(network_name)' curlimages/curl:8.10.1 --silent --output /dev/null --write-out '%{http_code}'${args}"; }
hcloud_q() { hcloud "$@"; }
server_type_available_in_location() {
  local location=$1 input=${2:--}
  jq -e --arg location "$location" '
    any(.locations[]?;
      ((.name // (if (.location | type) == "object" then .location.name else .location end)) == $location)
      and .available == true)
  ' "$input" >/dev/null
}

ssh_base() { printf '%s\0' ssh -i "$SSH_PRIVATE_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o UserKnownHostsFile="$RUN_DIR/known_hosts"; }
ssh_node() { local node=$1; shift; local -a base; mapfile -d '' -t base < <(ssh_base); "${base[@]}" "root@${!node}" "$@"; }
scp_node() { local node=$1 source=$2 target=$3; scp -i "$SSH_PRIVATE_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$RUN_DIR/known_hosts" "$source" "root@${!node}:$target"; }
copy_from_node() { local node=$1 source=$2 target=$3; scp -i "$SSH_PRIVATE_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$RUN_DIR/known_hosts" "root@${!node}:$source" "$target"; }

wait_for() {
  local description=$1 attempts=$2 seconds=$3; shift 3
  local attempt
  for attempt in $(seq 1 "$attempts"); do
    if "$@"; then return 0; fi
    sleep "$seconds"
  done
  die "Timed out waiting for $description after $((attempts * seconds)) seconds."
}

manager_exec() { ssh_node MANAGER_1_PUBLIC "$@"; }
manager_shell() { ssh_node MANAGER_1_PUBLIC "bash -s"; }
service_replicas() { manager_exec "docker service inspect '$1' --format '{{.Spec.Mode.Replicated.Replicas}}'"; }
wait_replicas() { local service=$1 expected=$2 actual attempt; for attempt in $(seq 1 90); do actual=$(service_replicas "$service" 2>/dev/null || true); [[ "$actual" == "$expected" ]] && return 0; sleep 2; done; die "Timed out waiting for $service desired replicas=$expected (actual=${actual:-missing})."; }
wait_service_running() { local service=$1 expected=$2 actual attempt; for ((attempt=1; attempt<=90; attempt++)); do actual=$(manager_exec "docker service ps '$service' --filter desired-state=running --format '{{.CurrentState}}' | grep -c '^Running' || true" 2>/dev/null || true); [[ "$actual" == "$expected" ]] && return 0; sleep 2; done; die "Timed out waiting for $service running tasks=$expected (actual=${actual:-0})."; }
network_name() { printf '%s_control' "$QUAL_STACK"; }
redis_cli() { local args; args=$(quote_remote_args "$@"); manager_exec "docker run --rm --network '$(network_name)' redis:7-alpine redis-cli -h redis${args}"; }
network_curl() { local args; args=$(quote_remote_args "$@"); manager_exec "docker run --rm --network '$(network_name)' curlimages/curl:8.10.1 --fail --silent --show-error${args}"; }
deda_leader() {
  local owner
  owner=$(redis_cli --raw GET deda-qualification:leader | tr -d '\r')
  [[ "$owner" != ERR\ * && "$owner" != '(error)'* ]] || return 1
  printf '%s\n' "$owner"
}

scenario_dir() { printf '%s/scenario-%s' "$(result_dir "$RUN_ID")" "$1"; }
start_scenario() { local id=$1 name=$2 dir; dir=$(scenario_dir "$id"); mkdir -p "$dir"; printf '{"id":"%s","name":"%s","started":"%s","status":"RUNNING"}\n' "$id" "$name" "$(utc_now)" > "$dir/result.json"; }
finish_scenario() { local id=$1 status=$2 message=$3 dir; dir=$(scenario_dir "$id"); jq -n --arg id "$id" --arg status "$status" --arg message "$message" --arg ended "$(utc_now)" '{id:$id,status:$status,message:$message,ended:$ended}' > "$dir/result.json"; }
capture_cluster() { local dir=$1; manager_exec 'docker node ls' > "$dir/docker-node-ls.txt"; manager_exec 'docker service ls' > "$dir/docker-service-ls.txt"; manager_exec "docker service ps '${QUAL_STACK}_deda' --no-trunc" > "$dir/deda-service-ps.txt" || true; manager_exec "timeout 30s docker service logs --tail 300 '${QUAL_STACK}_deda'" > "$dir/deda-logs.txt" 2>&1 || true; }
fail_scenario() { local id=$1 message=$2; capture_cluster "$(scenario_dir "$id")" || true; finish_scenario "$id" FAIL "$message"; die "Scenario $id failed: $message"; }
