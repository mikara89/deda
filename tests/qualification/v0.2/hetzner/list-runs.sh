#!/usr/bin/env bash
set -euo pipefail
command -v hcloud >/dev/null 2>&1 || { echo 'hcloud is required.' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo 'jq is required.' >&2; exit 1; }
[[ -n "${HCLOUD_TOKEN:-}" ]] || { echo 'HCLOUD_TOKEN must be set.' >&2; exit 1; }
for kind in server network firewall placement-group ssh-key; do
  echo "$kind"
  hcloud "$kind" list -o json | jq -r '.[] | select(.labels.purpose == "deda-qualification" and .labels.version == "v0-2") | [.name, .labels.run, (.labels.expires_at // "no-expiry-label")] | @tsv' || true
done
