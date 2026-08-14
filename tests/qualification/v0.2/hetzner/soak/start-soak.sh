#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); source "$SCRIPT_DIR/common.sh"; load_run
duration=24h; services=${DEDA_QUAL_SOAK_SERVICES:-20}
while (($#)); do
  case $1 in
    --duration) [[ -n "${2:-}" ]] || die '--duration requires a value.'; duration=$2; shift 2;;
    --services) [[ -n "${2:-}" ]] || die '--services requires a value.'; services=$2; shift 2;;
    *) die "Unknown option: $1";;
  esac
done
[[ "$duration" =~ ^([1-9][0-9]*)([hm])$ ]] || { echo 'Duration must be a positive number followed by h or m, for example 24h.' >&2; exit 2; }
[[ "$services" =~ ^[0-9]+$ && "$services" -ge 1 && "$services" -le 50 ]] || die 'Service count must be between 1 and 50.'
seconds=${BASH_REMATCH[1]}; [[ ${BASH_REMATCH[2]} == h ]] && seconds=$((seconds * 3600)) || seconds=$((seconds * 60))
remote="/var/lib/deda-qualification/$RUN_ID/soak"; local="$RUN_DIR/soak"; mkdir -p "$local"
manager_exec "! systemctl is-active --quiet deda-qualification-soak.service" || die 'A qualification soak service is already running on manager-1.'
scp_node MANAGER_1_PUBLIC "$SCRIPT_DIR/soak/soak-driver.sh" "/root/deda-qualification-soak-driver.sh"
cat > "$local/deda-qualification-soak.service" <<EOF
[Unit]
Description=DEDA qualification soak $RUN_ID
After=docker.service
[Service]
Type=simple
ExecStart=/bin/bash /root/deda-qualification-soak-driver.sh $RUN_ID $seconds $QUAL_STACK $services
Restart=no
[Install]
WantedBy=multi-user.target
EOF
scp_node MANAGER_1_PUBLIC "$local/deda-qualification-soak.service" /etc/systemd/system/deda-qualification-soak.service
manager_exec "mkdir -p '$remote'; systemctl daemon-reload; systemctl enable --now deda-qualification-soak.service; systemctl is-active --quiet deda-qualification-soak.service"
note "Soak service started for $duration with $services services. It persists on manager-1; local shell may disconnect. Check ./soak/soak-status.sh."
