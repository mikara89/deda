#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/common.sh"
begin_scenario 01 'GitHub Actions capacity and compatible labels'
set_state '{"reset":true,"github":{"runs":[{"id":1,"status":"queued"}],"jobs":[]}}'
wait_replicas github-runner 0
set_state '{"github":{"runs":[{"id":1,"status":"queued"}],"jobs":[{"status":"queued","labels":["self-hosted","linux","deda"]},{"status":"queued","labels":["self-hosted","linux","deda"]},{"status":"queued","labels":["self-hosted","linux","deda"]},{"status":"queued","labels":["self-hosted","linux","deda"]},{"status":"queued","labels":["self-hosted","linux","deda"]},{"status":"queued","labels":["self-hosted","linux","deda","gpu"]}]}}'
wait_replicas github-runner 5
set_state '{"github":{"runs":[{"id":1,"status":"in_progress"}],"jobs":[{"status":"in_progress","labels":["self-hosted","linux","deda"]},{"status":"in_progress","labels":["self-hosted","linux","deda"]},{"status":"in_progress","labels":["self-hosted","linux","deda"]},{"status":"in_progress","labels":["self-hosted","linux","deda"]},{"status":"in_progress","labels":["self-hosted","linux","deda"]}]}}'
wait_replicas github-runner 5
set_state '{"github":{"runs":[],"jobs":[]}}'
wait_replicas github-runner 0
finish_scenario PASS 'queued plus active demand scaled 0→5→0; incompatible gpu label was excluded'
