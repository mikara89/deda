#!/usr/bin/env bash
set -euo pipefail
command -v hcloud >/dev/null 2>&1 || { echo 'hcloud is required.' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo 'jq is required.' >&2; exit 1; }
[[ -n "${HCLOUD_TOKEN:-}" ]] || { echo 'HCLOUD_TOKEN must be set.' >&2; exit 1; }

printf 'Outstanding v0.3 Hetzner qualification resources (purpose=deda-qualification version=v0-3)\n\n'
for kind in server network firewall ssh-key placement-group; do
  printf '%s\n' "$kind"
  hcloud "$kind" list -o json | jq -r '
    .[]
    | select(.labels.purpose == "deda-qualification" and .labels.version == "v0-3")
    | [
        (.labels.run // "no-run-label"),
        .name,
        (if .public_net.ipv4.ip then .public_net.ipv4.ip else "-" end),
        (.labels.expires_at // "no-expiry-label")
      ]
    | @tsv
  ' || true
  printf '\n'
done
