#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

[[ "${1:-}" == --run && -n "${2:-}" ]] || die 'Usage: ./migrate-wsl-runtime.sh --run <RUN_ID>'
requested_run=$2
[[ "$requested_run" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || die 'RUN_ID contains unsupported characters.'
legacy_run="$LEGACY_RUNTIME_ROOT/$requested_run"
[[ -f "$legacy_run/state.env" && -f "$legacy_run/id_ed25519" ]] || die "Legacy run state or private key was not found in $legacy_run."
[[ "$RUNTIME_ROOT" != "$LEGACY_RUNTIME_ROOT" ]] || die 'The active runtime root is still the legacy directory; run this from WSL on /mnt/c or set DEDA_QUAL_RUNTIME_ROOT to a Linux-native path.'
target_run="$RUNTIME_ROOT/$requested_run"
[[ ! -e "$target_run" ]] || die "Refusing to overwrite existing secure runtime state at $target_run."

# Load the existing state, then rewrite its path-bearing fields for the secure target.
# shellcheck disable=SC1090
source "$legacy_run/state.env"
[[ "$RUN_ID" == "$requested_run" ]] || die 'Legacy state RUN_ID does not match the requested run.'
mkdir -p "$target_run"; chmod 700 "$RUNTIME_ROOT" "$target_run"
cp -a -- "$legacy_run/." "$target_run/"
RUN_DIR=$target_run; SSH_PRIVATE_KEY="$target_run/id_ed25519"; export RUN_DIR SSH_PRIVATE_KEY
chmod 600 "$SSH_PRIVATE_KEY" "$target_run/state.env"
chmod 644 "$SSH_PRIVATE_KEY.pub"
[[ ! -f "$target_run/known_hosts" ]] || chmod 600 "$target_run/known_hosts"
ssh-keygen -y -f "$SSH_PRIVATE_KEY" >/dev/null || die 'The migrated private key could not be read by OpenSSH.'
save_state RUN_ID RUN_DIR SSH_PRIVATE_KEY NETWORK FIREWALL PLACEMENT_GROUP SSH_KEY MANAGER_1 MANAGER_2 MANAGER_3 MANAGER_1_PUBLIC MANAGER_2_PUBLIC MANAGER_3_PUBLIC MANAGER_1_PRIVATE MANAGER_2_PRIVATE MANAGER_3_PRIVATE DEDA_IMAGE DEDA_QUAL_LOCATION DEDA_QUAL_SERVER_TYPE DEDA_QUAL_IMAGE DEDA_QUAL_SSH_CIDR DEDA_QUAL_NETWORK_CIDR DEDA_QUAL_SUBNET_CIDR DEDA_QUAL_NETWORK_ZONE DEDA_QUAL_PREFIX QUAL_STACK QUAL_EXPIRY_UTC
printf '%s\n' "$RUN_ID" > "$RUNTIME_ROOT/current"; chmod 600 "$RUNTIME_ROOT/current"

# Remove only the insecure duplicate key after the secure copy and rewritten state validate.
rm -f -- "$legacy_run/id_ed25519"
note "Migrated RUN_ID $RUN_ID to secure runtime $target_run and removed the insecure /mnt copy of its private key."
note 'Continue with ./configure-swarm.sh; do not run provision.sh again.'
