#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); source "$SCRIPT_DIR/common.sh"
[[ "${1:-}" == --run && -n "${2:-}" ]] || die 'Usage: ./destroy.sh --run <RUN_ID> [--yes]'
RUN_ID=$2; shift 2; yes=0; [[ "${1:-}" == --yes ]] && yes=1
[[ "$RUN_ID" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || die 'RUN_ID contains unsupported characters.'
init_defaults; require_command hcloud; [[ -n "${HCLOUD_TOKEN:-}" ]] || die 'HCLOUD_TOKEN must be set.'
run=$(safe_label_value "$RUN_ID"); matches() { local kind=$1; hcloud "$kind" list -o json | jq -r --arg run "$run" '.[] | select(.labels.purpose == "deda-qualification" and .labels.version == "v0-2" and .labels.run == $run) | .name'; }
servers=$(matches server); networks=$(matches network); firewalls=$(matches firewall); groups=$(matches placement-group); keys=$(matches ssh-key)
printf 'RUN_ID: %s\nServers:\n%s\nNetwork:\n%s\nFirewall:\n%s\nPlacement group:\n%s\nSSH key:\n%s\n' "$RUN_ID" "${servers:-<none>}" "${networks:-<none>}" "${firewalls:-<none>}" "${groups:-<none>}" "${keys:-<none>}"
if [[ "$yes" != 1 ]]; then read -r -p "Delete only these exact labelled resources? [y/N] " reply; [[ "$reply" =~ ^[Yy]$ ]] || { note 'Nothing deleted.'; exit 0; }; fi
while read -r name; do [[ -z "$name" ]] || hcloud server delete "$name"; done <<< "$servers"
while read -r name; do [[ -z "$name" ]] || hcloud firewall delete "$name"; done <<< "$firewalls"
while read -r name; do [[ -z "$name" ]] || hcloud network delete "$name"; done <<< "$networks"
while read -r name; do [[ -z "$name" ]] || hcloud placement-group delete "$name"; done <<< "$groups"
while read -r name; do [[ -z "$name" ]] || hcloud ssh-key delete "$name"; done <<< "$keys"
declare -A cleaned_roots=()
for runtime_candidate in "$RUNTIME_ROOT" "$LEGACY_RUNTIME_ROOT"; do
  [[ -z "${cleaned_roots[$runtime_candidate]+present}" ]] || continue
  cleaned_roots[$runtime_candidate]=1
  if [[ -d "$runtime_candidate" ]]; then
    runtime_abs=$(cd "$runtime_candidate" && pwd -P); local_state="$runtime_abs/$RUN_ID"
    [[ "$local_state" == "$runtime_abs/"* && "$local_state" != "$runtime_abs" ]] || die 'Refusing unsafe local state cleanup target.'
    rm -rf -- "$local_state" # local ephemeral private key/state only
    [[ ! -f "$runtime_abs/current" || $(<"$runtime_abs/current") != "$RUN_ID" ]] || rm -f "$runtime_abs/current"
  fi
done
note "Destroyed (or confirmed absent) only exact qualification resources for RUN_ID $RUN_ID."
