#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

pass() { printf 'ok  %s\n' "$1"; }
fail() { die "static test failed: $1"; }

DIGEST_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
DIGEST_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
DIGEST_C=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
DIGEST_D=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
PIN_DEDA="ghcr.io/mikara89/deda@sha256:${DIGEST_A}"
PIN_GH="ghcr.io/mikara89/deda-github-runner@sha256:${DIGEST_B}"
PIN_AZ="ghcr.io/mikara89/deda-azure-runner@sha256:${DIGEST_C}"
PIN_GL="ghcr.io/mikara89/deda-gitlab-runner@sha256:${DIGEST_D}"

for script in qualify.sh prepare-candidate.sh provision.sh configure-swarm.sh \
  run-deterministic.sh run-real.sh run-all.sh collect-evidence.sh \
  upload-evidence.sh destroy.sh list-runs.sh common.sh static-tests.sh; do
  bash -n "$SCRIPT_DIR/$script"
  [[ -x "$SCRIPT_DIR/$script" ]] || fail "missing executable bit on $script"
done
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck --exclude=SC1090,SC1091 "$SCRIPT_DIR"/*.sh
fi
pass 'shell syntax'

line_of() { grep -nF "$2" "$1" | head -n1 | cut -d: -f1; }
before() {
  local left right
  left=$(line_of "$1" "$2")
  right=$(line_of "$1" "$3")
  [[ -n "$left" && -n "$right" && "$left" -lt "$right" ]] || fail "$4"
}

before "$SCRIPT_DIR/provision.sh" 'Dry run validated inputs; no Hetzner resources were created.' 'hcloud_q ssh-key create' \
  'provision --dry-run must exit before creating an SSH key'
before "$SCRIPT_DIR/provision.sh" 'Dry run validated inputs; no Hetzner resources were created.' 'hcloud_q server create' \
  'provision --dry-run must exit before creating a server'
pass 'provision dry-run precedes resource creation'

DEDA_IMAGE=$PIN_DEDA
GITHUB_QUAL_RUNNER_IMAGE=$PIN_GH
AZURE_QUAL_RUNNER_IMAGE=$PIN_AZ
GITLAB_QUAL_RUNNER_IMAGE=$PIN_GL
assert_all_candidate_pins
pass 'immutable digest pins are accepted'

for bad in \
  'ghcr.io/mikara89/deda:latest' \
  'latest' \
  'ghcr.io/mikara89/deda:v0.3' \
  'ghcr.io/mikara89/deda:v0.3.0-rc.2' \
  'ghcr.io/mikara89/deda'; do
  if ( DEDA_IMAGE=$bad assert_immutable_image DEDA_IMAGE ) 2>/dev/null; then
    fail "mutable or unpinned DEDA_IMAGE was accepted: $bad"
  fi
done
pass 'mutable latest/v0.3 and unpinned DEDA tags are rejected'

for name in GITHUB_QUAL_RUNNER_IMAGE AZURE_QUAL_RUNNER_IMAGE GITLAB_QUAL_RUNNER_IMAGE; do
  if ( printf -v "$name" '%s' 'registry.example/runner:latest'; assert_immutable_image "$name" ) 2>/dev/null; then
    fail "$name accepted a mutable latest tag"
  fi
done
pass 'all three runner images must be immutable image@sha256'

RC_COMMIT=$(git -C "$REPO_ROOT" rev-parse HEAD)
assert_rc_checkout
if ( RC_COMMIT=0000000000000000000000000000000000000000 assert_rc_checkout ) 2>/dev/null; then
  fail 'source checkout mismatch was not rejected'
fi
pass 'source checkout mismatch is rejected'

assert_revisions_match "$RC_COMMIT" "$RC_COMMIT"
if ( assert_revisions_match 'ffffffffffffffffffffffffffffffffffffffff' "$RC_COMMIT" ) 2>/dev/null; then
  fail 'OCI revision mismatch was not rejected'
fi
if ( assert_revisions_match '' "$RC_COMMIT" ) 2>/dev/null; then
  fail 'missing OCI revision was not rejected'
fi
pass 'OCI revision mismatch is rejected'

if "$SCRIPT_DIR/qualify.sh" real >/tmp/deda-v03-hetzner-real.err 2>&1; then
  fail 'real qualification ran without --confirm-real-provider-tests'
fi
grep -Fq -- '--confirm-real-provider-tests' /tmp/deda-v03-hetzner-real.err
if "$SCRIPT_DIR/run-real.sh" >/tmp/deda-v03-hetzner-real2.err 2>&1; then
  fail 'run-real.sh ran without --confirm-real-provider-tests'
fi
if env GITHUB_QUAL_QUEUE_TOKEN_FILE=/etc/passwd GITHUB_QUAL_RUNNER_ADMIN_TOKEN_FILE=/etc/passwd \
  AZURE_QUAL_QUEUE_TOKEN_FILE=/etc/passwd AZURE_QUAL_AGENT_TOKEN_FILE=/etc/passwd \
  GITLAB_QUAL_QUEUE_TOKEN_FILE=/etc/passwd GITLAB_QUAL_RUNNER_TOKEN_FILE=/etc/passwd \
  "$SCRIPT_DIR/qualify.sh" run >/tmp/deda-v03-hetzner-run.err 2>&1; then
  fail 'run-all accepted credentials without --confirm-real-provider-tests'
fi
pass 'real qualification cannot run without --confirm-real-provider-tests'

if "$SCRIPT_DIR/qualify.sh" upload >/tmp/deda-v03-hetzner-upload.err 2>&1; then
  fail 'upload ran without --confirm-evidence-upload'
fi
grep -Fq -- '--confirm-evidence-upload' /tmp/deda-v03-hetzner-upload.err
if "$SCRIPT_DIR/upload-evidence.sh" >/tmp/deda-v03-hetzner-upload2.err 2>&1; then
  fail 'upload-evidence.sh ran without --confirm-evidence-upload'
fi
pass 'evidence upload cannot run without --confirm-evidence-upload'

grep -Fq 'HCLOUD_TOKEN' "$SCRIPT_DIR/common.sh"
grep -Fq 'Refusing to persist HCLOUD_TOKEN' "$SCRIPT_DIR/common.sh"
if printf '%s\n' "${STATE_KEYS[*]}" | grep -Fq HCLOUD_TOKEN; then
  fail 'STATE_KEYS must not include HCLOUD_TOKEN'
fi
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir" /tmp/deda-v03-hetzner-real.err /tmp/deda-v03-hetzner-real2.err /tmp/deda-v03-hetzner-run.err /tmp/deda-v03-hetzner-upload.err /tmp/deda-v03-hetzner-upload2.err /tmp/deda-v03-hetzner-destroy.err /tmp/deda-v03-hetzner-destroy2.err /tmp/deda-v03-hetzner-usage.err' EXIT
export DEDA_QUAL_RUNTIME_ROOT="$tmpdir/runtime"
RUNTIME_ROOT=$DEDA_QUAL_RUNTIME_ROOT
LEGACY_RUNTIME_ROOT=$DEDA_QUAL_RUNTIME_ROOT
RUN_ID=static-token-test
export RUN_ID HCLOUD_TOKEN=super-secret-hcloud-token-value
mkdir -p "$(state_dir "$RUN_ID")"
if ( save_state HCLOUD_TOKEN ) 2>/dev/null; then
  fail 'save_state accepted HCLOUD_TOKEN'
fi
persist_state
if grep -F 'super-secret-hcloud-token-value' "$(state_file "$RUN_ID")"; then
  fail 'HCLOUD_TOKEN value was written to generated state'
fi
pass 'HCLOUD_TOKEN is never written to generated state'

if grep -R --binary-files=without-match -nE 'cat "\$\{?(GITHUB|AZURE|GITLAB)_QUAL_[A-Z_]*TOKEN_FILE' "$SCRIPT_DIR"; then
  fail 'provider token files must not be catted into logs or evidence'
fi
grep -Fq 'redact_tree' "$SCRIPT_DIR/collect-evidence.sh"
grep -Fq 'HCLOUD_TOKEN' "$SCRIPT_DIR/collect-evidence.sh"
pass 'provider token contents are not written to evidence'

if "$SCRIPT_DIR/destroy.sh" >/tmp/deda-v03-hetzner-destroy.err 2>&1; then
  fail 'destroy ran without --run'
fi
grep -Fq -- '--run <RUN_ID>' /tmp/deda-v03-hetzner-destroy.err
if "$SCRIPT_DIR/destroy.sh" --run >/tmp/deda-v03-hetzner-destroy2.err 2>&1; then
  fail 'destroy accepted --run without an identity'
fi
pass 'destroy requires exact run identity'

grep -Fq 'purpose == "deda-qualification"' "$SCRIPT_DIR/destroy.sh"
grep -Fq 'version == "v0-3"' "$SCRIPT_DIR/destroy.sh"
grep -Fq '.labels.run == $run' "$SCRIPT_DIR/destroy.sh"
grep -Fq 'purpose == "deda-qualification"' "$SCRIPT_DIR/list-runs.sh"
grep -Fq 'version == "v0-3"' "$SCRIPT_DIR/list-runs.sh"
pass 'destroy/list filter by purpose, version=v0-3, and run'

if grep -nE 'hcloud[[:space:]]+server[[:space:]]+delete[[:space:]]+"?\$DEDA_QUAL_PREFIX|delete --selector|name=.*\$DEDA_QUAL_PREFIX' "$SCRIPT_DIR/destroy.sh"; then
  fail 'destroy must not perform broad prefix deletion'
fi
if grep -nE 'hcloud[[:space:]].*delete[[:space:]]+"?\$\{?DEDA_QUAL_PREFIX' "$SCRIPT_DIR"/destroy.sh "$SCRIPT_DIR"/list-runs.sh; then
  fail 'destroy/list must not delete by name prefix'
fi
pass 'no broad prefix deletion'

grep -Fq 'CANONICAL_DIR/run-deterministic.sh' "$SCRIPT_DIR/run-deterministic.sh"
grep -Fq -- '--fast' "$SCRIPT_DIR/run-deterministic.sh"
grep -Fq -- '--full' "$SCRIPT_DIR/run-deterministic.sh"
[[ ! -d "$SCRIPT_DIR/scenarios" ]] || fail 'Hetzner layer must not duplicate deterministic scenarios'
if grep -R --binary-files=without-match -nE 'github-capacity|active-job-protection|scale-to-zero' "$SCRIPT_DIR"/*.sh | grep -v static-tests.sh; then
  fail 'deterministic scenario logic must not be duplicated in the Hetzner layer'
fi
pass 'canonical deterministic script is invoked rather than duplicated'

grep -Fq 'CANONICAL_DIR/real/run-all.sh' "$SCRIPT_DIR/run-real.sh"
grep -Fq -- '--confirm-real-provider-tests' "$SCRIPT_DIR/run-real.sh"
[[ ! -e "$SCRIPT_DIR/real/github.sh" && ! -e "$SCRIPT_DIR/github.sh" ]] || fail 'Hetzner layer must not duplicate real provider scripts'
pass 'canonical real/run-all.sh is invoked rather than duplicated'

grep -Fq 'real-provider-result.json' "$SCRIPT_DIR/upload-evidence.sh"
grep -Fq 'manifest.json' "$SCRIPT_DIR/upload-evidence.sh"
grep -Fq 'release-qualification.json' "$SCRIPT_DIR/upload-evidence.sh"
grep -Fq 'qualification-manifest.json' "$SCRIPT_DIR/upload-evidence.sh"
grep -Fq 'releaseQualification == "PASS"' "$SCRIPT_DIR/upload-evidence.sh"
grep -Fq 'candidateMatched == true' "$SCRIPT_DIR/upload-evidence.sh"
pass 'upload consumes canonical evidence and requires releaseQualification PASS'

if grep -nE 'workflow_dispatch|gh workflow run' "$SCRIPT_DIR/upload-evidence.sh" "$SCRIPT_DIR/qualify.sh" "$SCRIPT_DIR/run-all.sh"; then
  fail 'upload/run must not invoke final promotion'
fi
if grep -nE 'promote-release' "$SCRIPT_DIR/qualify.sh" "$SCRIPT_DIR/run-all.sh"; then
  fail 'run/qualify must not invoke promote-release.yml'
fi
grep -Fq 'does not dispatch promote-release.yml' "$SCRIPT_DIR/upload-evidence.sh"
pass 'upload does not invoke final promotion'

if grep -nE 'Deda.Host|src/Deda.Host/Dockerfile' "$SCRIPT_DIR/prepare-candidate.sh"; then
  fail 'prepare must not rebuild DEDA'
fi
grep -Fq 'will not rebuild DEDA' "$SCRIPT_DIR/prepare-candidate.sh"
grep -Fq 'examples/ci-runners/github-actions' "$SCRIPT_DIR/prepare-candidate.sh"
grep -Fq 'examples/ci-runners/azure-pipelines' "$SCRIPT_DIR/prepare-candidate.sh"
grep -Fq 'examples/ci-runners/gitlab' "$SCRIPT_DIR/prepare-candidate.sh"
pass 'prepare does not rebuild DEDA'

grep -Fq 'ssh://' "$SCRIPT_DIR/common.sh"
grep -Fq 'DOCKER_HOST="ssh://root@${MANAGER_1_PUBLIC}"' "$SCRIPT_DIR/provision.sh"
grep -Fq 'ssh://root@' "$SCRIPT_DIR/configure-swarm.sh"
if grep -nE 'DOCKER_HOST=tcp://|2375/2376 publicly|:2375|:2376' "$SCRIPT_DIR/provision.sh"; then
  fail 'provision must not expose Docker over TCP'
fi
grep -Fq '2375' "$SCRIPT_DIR/configure-swarm.sh"
grep -Fq 'public Docker API exposure is forbidden' "$SCRIPT_DIR/configure-swarm.sh"
pass 'Docker connectivity uses SSH rather than public unauthenticated TCP'

printf '%s\n' '{"locations":[{"id":1,"name":"nbg1","available":true,"recommended":true}]}' |
  server_type_available_in_location nbg1
printf '%s\n' '{"locations":[{"location":{"name":"hel1"},"available":true,"recommended":false}]}' |
  server_type_available_in_location hel1
if printf '%s\n' '{"locations":[{"id":1,"name":"fsn1","available":false}]}' |
  server_type_available_in_location fsn1; then
  fail 'unavailable server-type fixture unexpectedly passed'
fi
expiry=$(DEDA_QUAL_EXPIRY_HOURS=12 qual_expiry_utc)
[[ "$expiry" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || fail "qual_expiry_utc produced $expiry"
pass 'shared Hetzner helpers'

mock_bin="$tmpdir/bin"
mkdir -p "$mock_bin" "$DEDA_QUAL_RUNTIME_ROOT/static-dry-run"
cat > "$mock_bin/hcloud" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${HCLOUD_MOCK_LOG:?}"
case "$1 $2" in
  "location describe") exit 0 ;;
  "server-type describe")
    printf '%s\n' '{"architecture":"x86","locations":[{"name":"nbg1","available":true}]}'
    exit 0
    ;;
  "image describe")
    printf '%s\n' '{"architecture":"x86"}'
    exit 0
    ;;
  "server list"|"network list"|"firewall list"|"ssh-key list"|"placement-group list")
    printf '%s\n' '[]'
    exit 0
    ;;
  version)
    printf '%s\n' 'hcloud mock'
    exit 0
    ;;
esac
if [[ "$*" == *create* || "$*" == *add-subnet* || "$*" == *add-rule* || "$*" == *delete* ]]; then
  printf 'FAIL: mutating hcloud invoked during dry-run: %s\n' "$*" >&2
  exit 99
fi
printf 'unexpected hcloud %s\n' "$*" >&2
exit 1
EOF
chmod 755 "$mock_bin/hcloud"
cat > "$DEDA_QUAL_RUNTIME_ROOT/static-dry-run/candidate.env" <<EOF
RC_TAG=v0.3.0-rc.2
RC_COMMIT=${RC_COMMIT}
DEDA_IMAGE=${PIN_DEDA}
GITHUB_QUAL_RUNNER_IMAGE=${PIN_GH}
AZURE_QUAL_RUNNER_IMAGE=${PIN_AZ}
GITLAB_QUAL_RUNNER_IMAGE=${PIN_GL}
EOF
export HCLOUD_MOCK_LOG="$tmpdir/hcloud.log"
: > "$HCLOUD_MOCK_LOG"
export PATH="$mock_bin:$PATH"
export RUN_ID=static-dry-run
export DEDA_QUAL_SSH_CIDR=203.0.113.10/32
export HCLOUD_TOKEN=super-secret-hcloud-token-value
"$SCRIPT_DIR/provision.sh" --dry-run >"$tmpdir/dry-run.out" 2>"$tmpdir/dry-run.err"
if grep -E 'create|add-subnet|add-rule|delete' "$HCLOUD_MOCK_LOG"; then
  fail 'provision --dry-run invoked a mutating hcloud command'
fi
if grep -F 'super-secret-hcloud-token-value' "$tmpdir/dry-run.out" "$tmpdir/dry-run.err" "$DEDA_QUAL_RUNTIME_ROOT/static-dry-run"/* 2>/dev/null; then
  fail 'dry-run leaked HCLOUD_TOKEN into output or state'
fi
[[ ! -e "$DEDA_QUAL_RUNTIME_ROOT/static-dry-run/id_ed25519" ]] || fail 'dry-run created an SSH key'
grep -Fq "$PIN_DEDA" "$tmpdir/dry-run.out" || fail 'dry-run did not print the prepared DEDA digest'
grep -Fq 'no Hetzner resources were created' "$tmpdir/dry-run.err" || fail 'dry-run did not report that no resources were created'
pass 'provision --dry-run creates no resources'

if "$SCRIPT_DIR/qualify.sh" not-a-command >/tmp/deda-v03-hetzner-usage.err 2>&1; then
  fail 'qualify.sh accepted an unknown command'
fi
grep -Fq 'Usage: qualify.sh' /tmp/deda-v03-hetzner-usage.err
pass 'qualify.sh usage errors are clear'

printf 'v0.3 Hetzner qualification static tests passed.\n'
