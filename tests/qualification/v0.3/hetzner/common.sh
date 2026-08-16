#!/usr/bin/env bash
# Shared local-orchestrator helpers for the v0.3 Hetzner release harness.
# HCLOUD_TOKEN and provider token file contents never cross SSH and are never
# persisted in run state or evidence.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
CANONICAL_DIR="$REPO_ROOT/tests/qualification/v0.3/ci-runners"
LEGACY_RUNTIME_ROOT="$SCRIPT_DIR/.runtime"
if [[ -n "${DEDA_QUAL_RUNTIME_ROOT:-}" ]]; then
  RUNTIME_ROOT=$DEDA_QUAL_RUNTIME_ROOT
elif [[ "$SCRIPT_DIR" == /mnt/* ]] && grep -Eqi '(microsoft|wsl)' /proc/sys/kernel/osrelease 2>/dev/null; then
  RUNTIME_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/deda-qualification/hetzner-v0.3"
else
  RUNTIME_ROOT=$LEGACY_RUNTIME_ROOT
fi
RESULTS_ROOT="$REPO_ROOT/tests/qualification/results"
export RUNTIME_ROOT LEGACY_RUNTIME_ROOT CANONICAL_DIR REPO_ROOT

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf '[v0.3 hetzner] %s\n' "$*" >&2; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }
utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
new_run_id() { printf '%s-%s\n' "$(date -u +%Y%m%d-%H%M%S)" "$(od -An -N3 -tx1 </dev/urandom | tr -d ' \n')"; }
safe_label_value() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9_.-' '-'; }

qual_expiry_utc() {
  local hours=${DEDA_QUAL_EXPIRY_HOURS:-12}
  [[ "$hours" =~ ^[1-9][0-9]*$ ]] || die "DEDA_QUAL_EXPIRY_HOURS must be a positive integer, got: $hours"
  if date -u -d "+${hours} hours" +%Y%m%dT%H%M%SZ 2>/dev/null; then
    return 0
  fi
  date -u -v+"${hours}H" +%Y%m%dT%H%M%SZ
}

init_defaults() {
  : "${DEDA_QUAL_LOCATION:=nbg1}" "${DEDA_QUAL_SERVER_TYPE:=cx23}" "${DEDA_QUAL_IMAGE:=ubuntu-24.04}"
  : "${DEDA_QUAL_NETWORK_CIDR:=10.42.0.0/16}" "${DEDA_QUAL_SUBNET_CIDR:=10.42.0.0/24}"
  : "${DEDA_QUAL_NETWORK_ZONE:=eu-central}" "${DEDA_QUAL_PREFIX:=deda-q}"
  : "${DEDA_QUAL_MANAGER_COUNT:=1}" "${DEDA_QUAL_EXPIRY_HOURS:=12}"
  : "${DEDA_QUAL_DEDA_REPOSITORY:=ghcr.io/mikara89/deda}"
  export DEDA_QUAL_LOCATION DEDA_QUAL_SERVER_TYPE DEDA_QUAL_IMAGE DEDA_QUAL_NETWORK_CIDR
  export DEDA_QUAL_SUBNET_CIDR DEDA_QUAL_NETWORK_ZONE DEDA_QUAL_PREFIX
  export DEDA_QUAL_MANAGER_COUNT DEDA_QUAL_EXPIRY_HOURS DEDA_QUAL_DEDA_REPOSITORY
  [[ "$DEDA_QUAL_MANAGER_COUNT" == 1 ]] || die "This v0.3 harness supports DEDA_QUAL_MANAGER_COUNT=1 only. Use tests/qualification/v0.2/hetzner for multi-manager HA qualification."
}

state_dir() { printf '%s/%s' "$RUNTIME_ROOT" "$1"; }
state_file() { printf '%s/state.env' "$(state_dir "$1")"; }
candidate_file() { printf '%s/candidate.env' "$(state_dir "$1")"; }
canonical_result_dir() { printf '%s/%s/v0.3-ci' "$RESULTS_ROOT" "$1"; }
hetzner_result_dir() { printf '%s/%s/v0.3-ci/hetzner' "$RESULTS_ROOT" "$1"; }

STATE_KEYS=(
  RUN_ID RUN_DIR SSH_PRIVATE_KEY
  NETWORK FIREWALL SSH_KEY
  MANAGER_1 MANAGER_1_PUBLIC MANAGER_1_PRIVATE
  DEDA_IMAGE GITHUB_QUAL_RUNNER_IMAGE AZURE_QUAL_RUNNER_IMAGE GITLAB_QUAL_RUNNER_IMAGE
  RC_TAG RC_COMMIT
  DEDA_QUAL_LOCATION DEDA_QUAL_SERVER_TYPE DEDA_QUAL_IMAGE DEDA_QUAL_SSH_CIDR
  DEDA_QUAL_NETWORK_CIDR DEDA_QUAL_SUBNET_CIDR DEDA_QUAL_NETWORK_ZONE DEDA_QUAL_PREFIX
  DEDA_QUAL_MANAGER_COUNT QUAL_EXPIRY_UTC QUAL_STARTED_UTC
  DOCKER_HOST SWARM_READY
)

save_state() {
  local key value file
  file=$(state_file "$RUN_ID")
  mkdir -p "$(dirname "$file")"
  umask 077
  : > "$file"
  for key in "$@"; do
    [[ "$key" != HCLOUD_TOKEN ]] || die 'Refusing to persist HCLOUD_TOKEN in run state.'
    value=${!key-}
    printf '%s=%q\n' "$key" "$value" >> "$file"
  done
  chmod 600 "$file"
}

persist_state() { save_state "${STATE_KEYS[@]}"; }

resolve_run_id() {
  if [[ -z "${RUN_ID:-}" && -f "$RUNTIME_ROOT/current" ]]; then
    RUN_ID=$(<"$RUNTIME_ROOT/current")
  fi
  [[ -n "${RUN_ID:-}" ]] || die 'RUN_ID is required; run ./qualify.sh prepare first or export RUN_ID.'
  [[ "$RUN_ID" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || die 'RUN_ID contains unsupported characters.'
  export RUN_ID
}

assert_immutable_image() {
  local name=$1 value=${!1-}
  [[ -n "$value" ]] || die "$name is required and must be an immutable image@sha256:... reference."
  if [[ "$value" == latest || "$value" == *:latest || "$value" == *:latest@* ]]; then
    die "$name must not use the mutable latest tag: $value"
  fi
  if [[ "$value" != *@sha256:* && ( "$value" == *:v0.3 || "$value" == *:v0.3.* || "$value" == v0.3 || "$value" == v0.3.* ) ]]; then
    die "$name must not use a mutable v0.3 tag: $value"
  fi
  [[ "$value" == *@sha256:* ]] || die "$name must be an immutable digest reference (image@sha256:...), got: $value"
  [[ "$value" =~ ^[a-zA-Z0-9][a-zA-Z0-9._/@:+-]+@sha256:[0-9a-f]{64}$ ]] || die "$name is not a valid image@sha256:<64-hex> reference: $value"
}

assert_all_candidate_pins() {
  assert_immutable_image DEDA_IMAGE
  assert_immutable_image GITHUB_QUAL_RUNNER_IMAGE
  assert_immutable_image AZURE_QUAL_RUNNER_IMAGE
  assert_immutable_image GITLAB_QUAL_RUNNER_IMAGE
}

assert_rc_checkout() {
  local head
  [[ -n "${RC_COMMIT:-}" ]] || die 'RC_COMMIT is not set; prepare a candidate first.'
  [[ "$RC_COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "RC_COMMIT must be a 40-character SHA, got: $RC_COMMIT"
  head=$(git -C "$REPO_ROOT" rev-parse HEAD)
  [[ "$head" == "$RC_COMMIT" ]] || die "git rev-parse HEAD ($head) != RC_COMMIT ($RC_COMMIT). Check out the exact RC tag before qualification."
}

assert_revisions_match() {
  local revision=$1 commit=$2
  [[ -n "$revision" ]] || die 'digest-pinned DEDA_IMAGE has no org.opencontainers.image.revision; cannot bind source commit'
  [[ "$revision" == "$commit" ]] || die "OCI revision $revision does not match RC commit $commit"
}

image_oci_revision() {
  local image=$1 revision
  revision=$(docker image inspect "$image" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' 2>/dev/null || true)
  printf '%s\n' "$revision"
}

load_candidate() {
  local file
  resolve_run_id
  file=$(candidate_file "$RUN_ID")
  [[ -f "$file" ]] || die "No prepared candidate exists for RUN_ID $RUN_ID. Run ./qualify.sh prepare first."
  # shellcheck disable=SC1090
  source "$file"
  export RC_TAG RC_COMMIT DEDA_IMAGE GITHUB_QUAL_RUNNER_IMAGE AZURE_QUAL_RUNNER_IMAGE GITLAB_QUAL_RUNNER_IMAGE
  assert_all_candidate_pins
  [[ -n "${RC_TAG:-}" && -n "${RC_COMMIT:-}" ]] || die "candidate.env for $RUN_ID is missing RC_TAG or RC_COMMIT."
}

load_run() {
  load_candidate
  [[ -f "$(state_file "$RUN_ID")" ]] || die "No local state exists for RUN_ID $RUN_ID."
  # shellcheck disable=SC1090
  source "$(state_file "$RUN_ID")"
  export RUN_ID
  RUN_DIR=$(state_dir "$RUN_ID")
  SSH_PRIVATE_KEY=${SSH_PRIVATE_KEY:-"$RUN_DIR/id_ed25519"}
  export RUN_DIR SSH_PRIVATE_KEY
  SAVED_DOCKER_HOST=${DOCKER_HOST:-}
  unset DOCKER_HOST
  export SAVED_DOCKER_HOST
  assert_all_candidate_pins
}

labels() { printf 'purpose=deda-qualification,version=v0-3,run=%s,expires_at=%s' "$(safe_label_value "$RUN_ID")" "${QUAL_EXPIRY_UTC:?QUAL_EXPIRY_UTC must be set}"; }

hcloud_q() { hcloud "$@"; }

server_type_available_in_location() {
  local location=$1 input=${2:--}
  jq -e --arg location "$location" '
    any(.locations[]?;
      ((.name // (if (.location | type) == "object" then .location.name else .location end)) == $location)
      and .available == true)
  ' "$input" >/dev/null
}

ssh_base() { printf '%s\0' ssh -i "$SSH_PRIVATE_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o UserKnownHostsFile="$RUN_DIR/known_hosts" -o IdentitiesOnly=yes; }
ssh_node() { local node=$1; shift; local -a base; mapfile -d '' -t base < <(ssh_base); "${base[@]}" "root@${!node}" "$@"; }
copy_from_node() { local node=$1 source=$2 target=$3; scp -i "$SSH_PRIVATE_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$RUN_DIR/known_hosts" -o IdentitiesOnly=yes "root@${!node}:$source" "$target"; }

wait_for() {
  local description=$1 attempts=$2 seconds=$3; shift 3
  local attempt
  for attempt in $(seq 1 "$attempts"); do
    if "$@"; then return 0; fi
    sleep "$seconds"
  done
  die "Timed out waiting for $description after $((attempts * seconds)) seconds."
}

write_docker_ssh_wrapper() {
  local real_ssh dest="$RUN_DIR/bin/ssh"
  [[ -n "${SSH_PRIVATE_KEY:-}" && -f "$SSH_PRIVATE_KEY" ]] || die 'SSH private key is missing; provision the run first.'
  real_ssh=$(command -v ssh)
  [[ -n "$real_ssh" && "$real_ssh" != "$dest" ]] || die 'Unable to locate the system ssh client.'
  mkdir -p "$RUN_DIR/bin"
  if [[ "$RUN_DIR" == /mnt/* ]]; then
    cat > "$dest" <<EOF
#!/usr/bin/env bash
exec $(printf '%q' "$real_ssh") \\
  -i $(printf '%q' "$SSH_PRIVATE_KEY") \\
  -o BatchMode=yes \\
  -o StrictHostKeyChecking=accept-new \\
  -o UserKnownHostsFile=$(printf '%q' "$RUN_DIR/known_hosts") \\
  -o IdentitiesOnly=yes \\
  -o ConnectTimeout=10 \\
  "\$@"
EOF
  else
    cat > "$dest" <<EOF
#!/usr/bin/env bash
exec $(printf '%q' "$real_ssh") \\
  -i $(printf '%q' "$SSH_PRIVATE_KEY") \\
  -o BatchMode=yes \\
  -o StrictHostKeyChecking=accept-new \\
  -o UserKnownHostsFile=$(printf '%q' "$RUN_DIR/known_hosts") \\
  -o IdentitiesOnly=yes \\
  -o ConnectTimeout=10 \\
  -o ControlMaster=auto \\
  -o ControlPath=$(printf '%q' "$RUN_DIR/ssh-%C") \\
  -o ControlPersist=120 \\
  "\$@"
EOF
  fi
  chmod 700 "$dest"
}

remote_docker_host() { printf '%s\n' "${DOCKER_HOST:-${SAVED_DOCKER_HOST:-}}"; }

require_remote_docker_configured() {
  [[ "${SWARM_READY:-}" == 1 && -n "${MANAGER_1_PUBLIC:-}" ]] || die 'Hetzner Docker target is not configured. Run ./qualify.sh configure first.'
}

apply_remote_docker() {
  [[ -n "${MANAGER_1_PUBLIC:-}" ]] || die 'No qualification server is recorded; run ./qualify.sh provision and ./qualify.sh configure first.'
  DOCKER_HOST=${DOCKER_HOST:-${SAVED_DOCKER_HOST:-ssh://root@${MANAGER_1_PUBLIC}}}
  [[ "$DOCKER_HOST" == ssh://* ]] || die "DOCKER_HOST must use ssh:// remote transport, got: $DOCKER_HOST"
  [[ "$DOCKER_HOST" != tcp://* && "$DOCKER_HOST" != *:2375 && "$DOCKER_HOST" != *:2376 ]] || die "Refusing public/unauthenticated Docker TCP endpoint: $DOCKER_HOST"
  write_docker_ssh_wrapper
  export PATH="$RUN_DIR/bin:$PATH"
  export DOCKER_HOST
  unset DOCKER_TLS_VERIFY DOCKER_CERT_PATH
}

require_secret_file() {
  local name=$1 path=${!1-}
  [[ -n "$path" ]] || die "$name must name a readable secret file"
  [[ -f "$path" && -r "$path" ]] || die "$name must name a readable secret file"
}

require_named_env() { [[ -n ${!1:-} ]] || die "$1 is required"; }

validate_real_provider_config() {
  local key
  for key in GITHUB_QUAL_OWNER GITHUB_QUAL_REPOSITORY GITHUB_QUAL_WORKFLOW \
    GITHUB_QUAL_QUEUE_TOKEN_FILE GITHUB_QUAL_RUNNER_ADMIN_TOKEN_FILE \
    AZURE_QUAL_ORGANIZATION_URL AZURE_QUAL_PROJECT AZURE_QUAL_PIPELINE_ID AZURE_QUAL_POOL \
    AZURE_QUAL_QUEUE_TOKEN_FILE AZURE_QUAL_AGENT_TOKEN_FILE \
    GITLAB_QUAL_URL GITLAB_QUAL_PROJECT GITLAB_QUAL_REF GITLAB_QUAL_TAGS \
    GITLAB_QUAL_QUEUE_TOKEN_FILE GITLAB_QUAL_RUNNER_TOKEN_FILE; do
    require_named_env "$key"
  done
  for key in GITHUB_QUAL_QUEUE_TOKEN_FILE GITHUB_QUAL_RUNNER_ADMIN_TOKEN_FILE \
    AZURE_QUAL_QUEUE_TOKEN_FILE AZURE_QUAL_AGENT_TOKEN_FILE \
    GITLAB_QUAL_QUEUE_TOKEN_FILE GITLAB_QUAL_RUNNER_TOKEN_FILE; do
    require_secret_file "$key"
  done
}

export_qualification_env() {
  export RUN_ID RC_TAG RC_COMMIT
  export DEDA_IMAGE
  export REAL_DEDA_IMAGE="$DEDA_IMAGE"
  export GITHUB_QUAL_RUNNER_IMAGE AZURE_QUAL_RUNNER_IMAGE GITLAB_QUAL_RUNNER_IMAGE
}

invoke_canonical() {
  apply_remote_docker
  export_qualification_env
  "$@"
}

redact_tree() {
  local root=$1
  [[ -d "$root" ]] || return 0
  while IFS= read -r -d '' file; do
    sed -Ei \
      -e 's/HCLOUD_TOKEN[[:space:]]*=[[:space:]]*[^[:space:]]+/HCLOUD_TOKEN=[REDACTED]/g' \
      -e 's/[Aa]uthorization:[[:space:]]*[^[:space:]]+/Authorization: [REDACTED]/g' \
      -e 's/[Bb]earer[[:space:]]+[A-Za-z0-9._\-+=\/]+/Bearer [REDACTED]/g' \
      -e 's/([Pp]assword|[Ss]ecret|[Tt]oken|[Pp]at)[=:][[:space:]]*[^[:space:]"]+/\1=[REDACTED]/g' \
      "$file"
  done < <(find "$root" -type f \( -name '*.txt' -o -name '*.json' -o -name '*.log' -o -name '*.md' -o -name '*.yml' -o -name '*.yaml' -o -name '*.env' \) -print0)
}

assert_no_token_leak() {
  local root=$1
  [[ -d "$root" ]] || return 0
  if grep -R --binary-files=without-match -E 'HCLOUD_TOKEN=([^[:space:][]+|".+")' "$root" | grep -v '\[REDACTED\]' | grep -v 'HCLOUD_TOKEN=$' >/dev/null; then
    die "Refusing to keep evidence that appears to contain HCLOUD_TOKEN at $root"
  fi
}
