#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/common.sh"
begin_scenario 08 'Credential policy fail-closed and runner secret isolation'
dotnet test "$REPO_ROOT/Deda.sln" --configuration Release --no-build --filter 'FullyQualifiedName~Credential|FullyQualifiedName~CiProviderHardeningTests' > "$SCENARIO_DIR/credential-tests.txt" 2>&1 || fail_scenario 'credential policy unit qualification failed'
set_state '{"github":{"runs":[{"id":1,"status":"queued"}],"jobs":[{"status":"queued","labels":["self-hosted","linux","deda"]}]}}'
wait_replicas github-runner 1
wait_replicas invalid-github-runner 0
set_state '{"github":{"runs":[],"jobs":[]}}'; wait_replicas github-runner 0
bash "$REPO_ROOT/tests/ci-runners/security-tests.sh" > "$SCENARIO_DIR/secret-isolation.txt" 2>&1 || fail_scenario 'runner job-user secret isolation failed'
finish_scenario PASS 'unknown/wrong credential policy cases fail closed; a separately configured valid GitHub runner continued to scale'
