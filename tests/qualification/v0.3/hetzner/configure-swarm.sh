#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

load_run
[[ -n "${MANAGER_1_PUBLIC:-}" ]] || die 'No server is recorded for this run; provision first.'
[[ -f "$SSH_PRIVATE_KEY" ]] || die "SSH private key is missing at $SSH_PRIVATE_KEY"

out=$(hetzner_result_dir "$RUN_ID")
mkdir -p "$out"

if ! ssh_node MANAGER_1_PUBLIC 'timeout 900 cloud-init status --wait && docker info >/dev/null'; then
  copy_from_node MANAGER_1_PUBLIC /var/log/cloud-init.log "$out/cloud-init.log" 2>/dev/null || true
  copy_from_node MANAGER_1_PUBLIC /var/log/cloud-init-output.log "$out/cloud-init-output.log" 2>/dev/null || true
  die "Cloud-init or Docker bootstrap failed on $MANAGER_1_PUBLIC; logs were copied to the Hetzner evidence directory where available."
fi

ssh_node MANAGER_1_PUBLIC 'docker info >/dev/null' || die 'Docker daemon is not available on the qualification server.'

if [[ -n "${MANAGER_1_PRIVATE:-}" && "$MANAGER_1_PRIVATE" != null ]]; then
  ssh_node MANAGER_1_PUBLIC "docker swarm init --advertise-addr '$MANAGER_1_PRIVATE' --data-path-addr '$MANAGER_1_PRIVATE'" || {
    ssh_node MANAGER_1_PUBLIC 'docker node ls' >/dev/null 2>&1 || die 'Failed to initialize Docker Swarm on the qualification server.'
  }
else
  ssh_node MANAGER_1_PUBLIC 'docker swarm init' || {
    ssh_node MANAGER_1_PUBLIC 'docker node ls' >/dev/null 2>&1 || die 'Failed to initialize Docker Swarm on the qualification server.'
  }
fi

ready=
for ((attempt=1; attempt<=60; attempt++)); do
  ready=$(ssh_node MANAGER_1_PUBLIC "docker node ls --format '{{.Status}}' | grep -c '^Ready$' || true" || true)
  [[ "$ready" == 1 ]] && break
  sleep 3
done
[[ "${ready:-0}" == 1 ]] || die 'Timed out waiting for one Ready Swarm manager.'

if ssh_node MANAGER_1_PUBLIC 'ss -lnt 2>/dev/null | grep -Eq ":2375 |:2376 " || netstat -lnt 2>/dev/null | grep -Eq ":2375 |:2376 "'; then
  die 'Remote Docker is listening on TCP 2375/2376; public Docker API exposure is forbidden.'
fi

DOCKER_HOST="ssh://root@${MANAGER_1_PUBLIC}"
SWARM_READY=1
export DOCKER_HOST SWARM_READY
write_docker_ssh_wrapper
persist_state
apply_remote_docker

docker info > "$out/docker-info.txt"
docker version > "$out/docker-version.txt"
docker node ls > "$out/docker-node-ls.txt"
printf 'DOCKER_HOST=%s\nSWARM_READY=%s\nMANAGER_1=%s\nMANAGER_1_PUBLIC=%s\nMANAGER_1_PRIVATE=%s\n' \
  "$DOCKER_HOST" "$SWARM_READY" "$MANAGER_1" "$MANAGER_1_PUBLIC" "${MANAGER_1_PRIVATE:-}" > "$out/remote-docker.txt"

if [[ -n "${DEDA_QUAL_REGISTRY_TOKEN_FILE:-}" ]]; then
  [[ -n "${DEDA_QUAL_REGISTRY_USER:-}" ]] || die 'DEDA_QUAL_REGISTRY_USER is required when DEDA_QUAL_REGISTRY_TOKEN_FILE is set.'
  require_secret_file DEDA_QUAL_REGISTRY_TOKEN_FILE
  registry=${DEDA_QUAL_REGISTRY_HOST:-${GITHUB_QUAL_RUNNER_IMAGE%%/*}}
  note "Logging the remote Docker engine into $registry (token file is not copied into evidence)."
  ssh_node MANAGER_1_PUBLIC "docker login $(printf '%q' "$registry") -u $(printf '%q' "$DEDA_QUAL_REGISTRY_USER") --password-stdin" < "$DEDA_QUAL_REGISTRY_TOKEN_FILE" >/dev/null
fi

note 'Verifying candidate images are pullable by the Hetzner Docker engine'
for image in "$DEDA_IMAGE" "$GITHUB_QUAL_RUNNER_IMAGE" "$AZURE_QUAL_RUNNER_IMAGE" "$GITLAB_QUAL_RUNNER_IMAGE"; do
  docker pull "$image" >/dev/null
  docker image inspect "$image" >/dev/null
done
revision=$(image_oci_revision "$DEDA_IMAGE")
assert_revisions_match "$revision" "$RC_COMMIT"

{
  printf 'candidate_pull\t%s\n' "$(utc_now)"
  printf 'DEDA_IMAGE\t%s\n' "$DEDA_IMAGE"
  printf 'GITHUB_QUAL_RUNNER_IMAGE\t%s\n' "$GITHUB_QUAL_RUNNER_IMAGE"
  printf 'AZURE_QUAL_RUNNER_IMAGE\t%s\n' "$AZURE_QUAL_RUNNER_IMAGE"
  printf 'GITLAB_QUAL_RUNNER_IMAGE\t%s\n' "$GITLAB_QUAL_RUNNER_IMAGE"
} > "$out/candidate-pulls.txt"

docker node ls --format '{{.Status}}' | grep -qx Ready || die 'Local docker CLI did not observe a Ready Swarm node on the Hetzner daemon.'
note 'Swarm configured: one Ready manager; local docker CLI uses Docker-over-SSH. No TCP Docker port is exposed.'
