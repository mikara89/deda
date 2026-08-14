#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/common.sh"
load_run
stage="$RUN_DIR/stack"; mkdir -p "$stage"
cp "$SCRIPT_DIR/stack.yml" "$SCRIPT_DIR/prometheus.yml" "$SCRIPT_DIR/credential-policy.json.tpl" "$stage/"
jq --arg service "${QUAL_STACK}_rabbit-worker" '."qualification-rabbitmq".allowedServices = [$service]' \
  "$stage/credential-policy.json.tpl" > "$stage/credential-policy.json"
rm "$stage/credential-policy.json.tpl"
# Generate disposable secret values locally; only their secret objects reach Swarm.
umask 077
rabbit_user="dedaqual"; rabbit_pass=$(od -An -N24 -tx1 </dev/urandom | tr -d ' \n'); credentials="$rabbit_user:$rabbit_pass"
QUAL_SECRET_PREFIX="$(safe_label_value "$QUAL_STACK-$RUN_ID")"
for pair in "rabbitmq_user:$rabbit_user" "rabbitmq_pass:$rabbit_pass" "qualification_rabbitmq_credentials:$credentials"; do
  name=${pair%%:*}; value=${pair#*:}; secret_name="${QUAL_SECRET_PREFIX}_${name#qualification_}"; printf '%s' "$value" | manager_exec "docker secret create '$secret_name' - >/dev/null" || die "Unable to create Docker secret $secret_name."
done
manager_exec "mkdir -p /root/deda-qualification/$RUN_ID"
scp_node MANAGER_1_PUBLIC "$stage/stack.yml" "/root/deda-qualification/$RUN_ID/stack.yml"
scp_node MANAGER_1_PUBLIC "$stage/prometheus.yml" "/root/deda-qualification/$RUN_ID/prometheus.yml"
scp_node MANAGER_1_PUBLIC "$stage/credential-policy.json" "/root/deda-qualification/$RUN_ID/credential-policy.json"
manager_exec "cd /root/deda-qualification/$RUN_ID && DEDA_IMAGE='$DEDA_IMAGE' QUAL_SECRET_PREFIX='$QUAL_SECRET_PREFIX' docker stack deploy --resolve-image always -c stack.yml '$QUAL_STACK'"
wait_service_running "${QUAL_STACK}_deda" 2
wait_for 'RabbitMQ queue initialization' 90 2 manager_exec "docker service ps '${QUAL_STACK}_rabbit-init' --no-trunc --format '{{.CurrentState}}' | grep -q '^Complete'"
wait_for 'DEDA readiness' 90 2 network_curl --output /dev/null 'http://deda:8080/health/ready'
mkdir -p "$(result_dir "$RUN_ID")"
resolved_image=$(manager_exec "docker service inspect '${QUAL_STACK}_deda' --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}'" | tr -d '\r')
image_file="$(result_dir "$RUN_ID")/image-digests.txt"
printf 'candidate\t%s\nresolved\t%s\n' "$DEDA_IMAGE" "$resolved_image" > "$image_file"
for n in 1 2 3; do
  public_var="MANAGER_${n}_PUBLIC"
  ssh_node "$public_var" "docker pull --quiet '$resolved_image' >/dev/null"
  image_id=$(ssh_node "$public_var" "docker image inspect '$resolved_image' --format '{{.Id}} {{.Os}}/{{.Architecture}}'" | tr -d '\r')
  printf 'manager-%s\t%s\n' "$n" "$image_id" >> "$image_file"
done
[[ $(awk -F '\t' '$1 ~ /^manager-/ { print $2 }' "$image_file" | sort -u | wc -l) == 1 ]] || die 'DEDA resolved to different platform image IDs across nodes.'
manager_exec 'docker version' > "$(result_dir "$RUN_ID")/docker-versions.txt"
manager_exec 'docker service ls' > "$(result_dir "$RUN_ID")/initial-services.txt"
note 'Qualification HA stack deployed with two DEDA replicas and a private socket-proxy control network.'
