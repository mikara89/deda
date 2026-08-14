#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/common.sh"
begin_scenario 07 'Redis HA failover during active CI demand'
set_state '{"gitlab":{"jobs":[{"status":"running","tag_list":["linux","deda"]},{"status":"running","tag_list":["linux","deda"]}]}}'
wait_replicas gitlab-runner 2
before=$(redis_leader); [[ -n "$before" && "$before" != '(nil)' ]] || fail_scenario 'no Redis lease owner was recorded'
leader_task=$(deda_leader_task "$before") || fail_scenario 'could not map the Redis lease owner to a running DEDA task'
docker rm -f "$leader_task" >/dev/null
wait_until 'a different DEDA leader after the old task was killed' 60 bash -c "value=\$(docker run --rm --network '${DEDA_QUAL_STACK}_control' redis:7-alpine redis-cli -h '$(service redis)' --raw GET deda-v03-qualification:leader); [[ -n \"\$value\" && \"\$value\" != '(nil)' && \"\$value\" != '$before' ]]" || fail_scenario 'standby did not acquire the lease after the old leader task was killed'
after=$(redis_leader); [[ -n "$after" && "$after" != '(nil)' && "$after" != "$before" ]] || fail_scenario 'new Redis leader was not different from the killed leader'
wait_replicas gitlab-runner 2
set_state '{"gitlab":{"jobs":[{"status":"running","tag_list":["linux","deda"]},{"status":"running","tag_list":["linux","deda"]},{"status":"running","tag_list":["linux","deda"]}]}}'
wait_replicas gitlab-runner 3
set_state '{"gitlab":{"jobs":[]}}'; wait_replicas gitlab-runner 0
printf 'leader-before=%s\nleader-after=%s\nkilled-task=%s\n' "$before" "$after" "$leader_task" > "$SCENARIO_DIR/redis-leadership.txt"
finish_scenario PASS 'active CI demand survived killing the actual DEDA lease owner and scaling continued under the standby'
