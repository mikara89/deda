#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

dry_run=${DEDA_QUAL_DRY_RUN:-0}
[[ "${1:-}" != '--dry-run' ]] || dry_run=1
[[ $# -eq 0 || ( $# -eq 1 && "$1" == '--dry-run' ) ]] || die 'Usage: ./provision.sh [--dry-run]'

init_defaults
for command in hcloud ssh scp ssh-keygen jq curl od; do require_command "$command"; done
[[ -n "${HCLOUD_TOKEN:-}" ]] || die 'HCLOUD_TOKEN must be set locally. It is never uploaded to Hetzner VMs.'
[[ -n "${DEDA_QUAL_SSH_CIDR:-}" && "$DEDA_QUAL_SSH_CIDR" =~ ^[0-9a-fA-F:.]+/[0-9]{1,3}$ ]] || die 'DEDA_QUAL_SSH_CIDR must look like a CIDR.'

if [[ -z "${RUN_ID:-}" && -f "$RUNTIME_ROOT/current" ]]; then
  RUN_ID=$(<"$RUNTIME_ROOT/current")
fi
[[ -n "${RUN_ID:-}" ]] || die 'RUN_ID is required. Run ./qualify.sh prepare first so the candidate identity is known.'
load_candidate
export RUN_ID
RUN_DIR=$(state_dir "$RUN_ID")
SSH_PRIVATE_KEY="$RUN_DIR/id_ed25519"
export RUN_DIR SSH_PRIVATE_KEY
mkdir -p "$RUNTIME_ROOT"
chmod 700 "$RUNTIME_ROOT"

QUAL_EXPIRY_UTC=${DEDA_QUAL_EXPIRY_UTC:-$(qual_expiry_utc)}
export QUAL_EXPIRY_UTC
RESOURCE_LABEL_ARGS=(
  --label purpose=deda-qualification
  --label version=v0-3
  --label "run=$(safe_label_value "$RUN_ID")"
  --label "expires_at=$QUAL_EXPIRY_UTC"
)

hcloud_q location describe "$DEDA_QUAL_LOCATION" >/dev/null || die "Hetzner location $DEDA_QUAL_LOCATION does not exist."
hcloud_q server-type describe "$DEDA_QUAL_SERVER_TYPE" -o json > "$RUN_DIR.server-type.json" 2>/dev/null || die "Hetzner server type $DEDA_QUAL_SERVER_TYPE does not exist."
jq -e '.architecture == "x86"' "$RUN_DIR.server-type.json" >/dev/null || die "Server type $DEDA_QUAL_SERVER_TYPE is not an x86 server type."
if ! server_type_available_in_location "$DEDA_QUAL_LOCATION" "$RUN_DIR.server-type.json"; then
  rm -f "$RUN_DIR.server-type.json"
  die "Server type $DEDA_QUAL_SERVER_TYPE is unavailable in $DEDA_QUAL_LOCATION. Choose another type with DEDA_QUAL_SERVER_TYPE."
fi
rm -f "$RUN_DIR.server-type.json"
hcloud_q image describe "$DEDA_QUAL_IMAGE" -o json > "$RUN_DIR.image.json" 2>/dev/null || die "Image $DEDA_QUAL_IMAGE is unavailable."
jq -e '.architecture == "x86"' "$RUN_DIR.image.json" >/dev/null || die "Image $DEDA_QUAL_IMAGE is not compatible with x86 servers."
rm -f "$RUN_DIR.image.json"

for kind in server network firewall ssh-key; do
  if hcloud_q "$kind" list -o json | jq -e --arg run "$(safe_label_value "$RUN_ID")" 'any(.[]; .labels.purpose == "deda-qualification" and .labels.version == "v0-3" and .labels.run == $run)' >/dev/null; then
    die "Conflicting qualification resources exist for RUN_ID $RUN_ID."
  fi
done

NETWORK="${DEDA_QUAL_PREFIX}-${RUN_ID}-network"
FIREWALL="${DEDA_QUAL_PREFIX}-${RUN_ID}-firewall"
SSH_KEY="${DEDA_QUAL_PREFIX}-${RUN_ID}-ssh"
MANAGER_1="${DEDA_QUAL_PREFIX}-${RUN_ID}-manager-1"

printf 'Planned RUN_ID: %s\nLocation/type: %s / %s\nManagers: %s\nNetwork: %s (%s, %s)\nFirewall: %s (SSH only from %s)\nServer: %s\nSSH key: %s\nExpires: %s\nRC_TAG: %s\nRC_COMMIT: %s\nDEDA_IMAGE: %s\nGITHUB_QUAL_RUNNER_IMAGE: %s\nAZURE_QUAL_RUNNER_IMAGE: %s\nGITLAB_QUAL_RUNNER_IMAGE: %s\n' \
  "$RUN_ID" "$DEDA_QUAL_LOCATION" "$DEDA_QUAL_SERVER_TYPE" "$DEDA_QUAL_MANAGER_COUNT" \
  "$NETWORK" "$DEDA_QUAL_NETWORK_CIDR" "$DEDA_QUAL_SUBNET_CIDR" \
  "$FIREWALL" "$DEDA_QUAL_SSH_CIDR" "$MANAGER_1" "$SSH_KEY" "$QUAL_EXPIRY_UTC" \
  "$RC_TAG" "$RC_COMMIT" "$DEDA_IMAGE" \
  "$GITHUB_QUAL_RUNNER_IMAGE" "$AZURE_QUAL_RUNNER_IMAGE" "$GITLAB_QUAL_RUNNER_IMAGE"

if [[ "$dry_run" == 1 ]]; then
  note 'Dry run validated inputs; no Hetzner resources were created.'
  exit 0
fi

mkdir -p "$RUN_DIR" "$(hetzner_result_dir "$RUN_ID")"
chmod 700 "$RUN_DIR"
umask 077
ssh-keygen -q -t ed25519 -N '' -f "$SSH_PRIVATE_KEY" -C "deda-qualification-v0.3-$RUN_ID"
chmod 600 "$SSH_PRIVATE_KEY"
chmod 644 "$SSH_PRIVATE_KEY.pub"

hcloud_q ssh-key create --name "$SSH_KEY" --public-key-from-file "$SSH_PRIVATE_KEY.pub" "${RESOURCE_LABEL_ARGS[@]}" >/dev/null
hcloud_q network create --name "$NETWORK" --ip-range "$DEDA_QUAL_NETWORK_CIDR" "${RESOURCE_LABEL_ARGS[@]}" >/dev/null
hcloud_q network add-subnet "$NETWORK" --type cloud --ip-range "$DEDA_QUAL_SUBNET_CIDR" --network-zone "$DEDA_QUAL_NETWORK_ZONE"
hcloud_q firewall create --name "$FIREWALL" "${RESOURCE_LABEL_ARGS[@]}" >/dev/null
hcloud_q firewall add-rule "$FIREWALL" --direction in --protocol tcp --port 22 --source-ips "$DEDA_QUAL_SSH_CIDR"
hcloud_q server create --name "$MANAGER_1" --type "$DEDA_QUAL_SERVER_TYPE" --image "$DEDA_QUAL_IMAGE" --location "$DEDA_QUAL_LOCATION" --ssh-key "$SSH_KEY" --network "$NETWORK" --firewall "$FIREWALL" --user-data-from-file "$SCRIPT_DIR/cloud-init.yaml" "${RESOURCE_LABEL_ARGS[@]}" >/dev/null

MANAGER_1_PUBLIC=$(hcloud_q server ip "$MANAGER_1")
MANAGER_1_PRIVATE=$(hcloud_q server describe "$MANAGER_1" -o json | jq -r '.private_net[0].ip')
DOCKER_HOST="ssh://root@${MANAGER_1_PUBLIC}"
QUAL_STARTED_UTC=${QUAL_STARTED_UTC:-$(utc_now)}
export MANAGER_1 MANAGER_1_PUBLIC MANAGER_1_PRIVATE NETWORK FIREWALL SSH_KEY DOCKER_HOST QUAL_STARTED_UTC
persist_state
printf '%s\n' "$RUN_ID" > "$RUNTIME_ROOT/current"
chmod 600 "$RUNTIME_ROOT/current"

wait_for "SSH to $MANAGER_1_PUBLIC" 60 5 ssh -i "$SSH_PRIVATE_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$RUN_DIR/known_hosts" -o IdentitiesOnly=yes "root@$MANAGER_1_PUBLIC" true
note "Provisioned RUN_ID $RUN_ID. Next: ./qualify.sh configure"
note 'HCLOUD_TOKEN was not uploaded to the server.'
