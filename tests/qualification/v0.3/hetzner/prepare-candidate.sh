#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

RUNNER_SHA256_AMD64=048024cd2c848eb6f14d5646d56c13a4def2ae7ee3ad12122bee960c56f3d271
RUNNER_SHA256_ARM64=f44255bd3e80160eb25f71bc83d06ea025f6908748807a584687b3184759f7e4
AGENT_SHA256_AMD64=828220fc662131f8d6bd427c8d8b9bffae064a9b1532b7e448d58766276b31fa
AGENT_SHA256_ARM64=bd61a2526333403a6d76243a49846887a1dd8eb115bbce6b037c950c2118f138

RC_TAG=${DEDA_QUAL_RC_TAG:-}
RUNNER_REGISTRY=${DEDA_QUAL_RUNNER_REGISTRY:-}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rc) RC_TAG=$2; shift 2 ;;
    --runner-registry) RUNNER_REGISTRY=$2; shift 2 ;;
    -h|--help)
      printf '%s\n' 'Usage: prepare-candidate.sh --rc <prerelease-tag> --runner-registry <registry>'
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

init_defaults
for command in git docker jq od; do require_command "$command"; done
docker buildx version >/dev/null 2>&1 || die 'docker buildx is required.'
[[ -n "$RC_TAG" ]] || die 'Provide --rc <tag> or set DEDA_QUAL_RC_TAG (example: v0.3.0-rc.2).'
[[ -n "$RUNNER_REGISTRY" ]] || die 'Provide --runner-registry <registry> or set DEDA_QUAL_RUNNER_REGISTRY.'
[[ "$RC_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-.+$ ]] || die "RC tag must be a prerelease such as v0.3.0-rc.2, got: $RC_TAG"
[[ "$RC_TAG" != *latest* && "$RC_TAG" != v0.3 ]] || die "Refusing mutable RC tag: $RC_TAG"
[[ "$RUNNER_REGISTRY" =~ ^[a-zA-Z0-9][a-zA-Z0-9._/-]*$ ]] || die "Runner registry contains unsupported characters: $RUNNER_REGISTRY"
[[ "$DEDA_QUAL_DEDA_REPOSITORY" =~ ^[a-zA-Z0-9][a-zA-Z0-9._/-]*$ ]] || die "DEDA_QUAL_DEDA_REPOSITORY contains unsupported characters."

resolve_tag_commit() {
  local tag=$1 commit
  commit=$(git -C "$REPO_ROOT" rev-parse --verify --quiet "${tag}^{commit}" || true)
  if [[ -z "$commit" ]]; then
    note "Fetching tags to resolve $tag"
    git -C "$REPO_ROOT" fetch --tags --force origin || true
    commit=$(git -C "$REPO_ROOT" rev-parse --verify --quiet "${tag}^{commit}" || true)
  fi
  [[ -n "$commit" ]] || die "Source tag $tag does not exist locally. Fetch tags from the repository first."
  printf '%s\n' "$commit"
}

resolve_manifest_digest() {
  local ref=$1 digest
  digest=$(docker buildx imagetools inspect "$ref" --format '{{.Manifest.Digest}}' 2>/dev/null || true)
  if [[ -z "$digest" || "$digest" == '<no value>' ]]; then
    digest=$(docker buildx imagetools inspect "$ref" 2>/dev/null | awk '/^Digest:/{print $2; exit}')
  fi
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "Unable to resolve an immutable manifest digest for $ref"
  printf '%s\n' "$digest"
}

write_candidate_env() {
  local file
  file=$(candidate_file "$RUN_ID")
  mkdir -p "$(dirname "$file")"
  umask 077
  cat > "$file" <<EOF
RC_TAG=$RC_TAG
RC_COMMIT=$RC_COMMIT
DEDA_IMAGE=$DEDA_IMAGE
GITHUB_QUAL_RUNNER_IMAGE=$GITHUB_QUAL_RUNNER_IMAGE
AZURE_QUAL_RUNNER_IMAGE=$AZURE_QUAL_RUNNER_IMAGE
GITLAB_QUAL_RUNNER_IMAGE=$GITLAB_QUAL_RUNNER_IMAGE
EOF
  chmod 600 "$file"
}

RC_COMMIT=$(resolve_tag_commit "$RC_TAG")
assert_rc_checkout

if command -v gh >/dev/null 2>&1; then
  gh release view "$RC_TAG" >/dev/null 2>&1 || note "gh could not view release $RC_TAG; continuing with local tag + published image inspect."
fi

if [[ -z "${RUN_ID:-}" && -f "$RUNTIME_ROOT/current" ]]; then
  existing=$(<"$RUNTIME_ROOT/current")
  if [[ -n "$existing" && ! -f "$(candidate_file "$existing")" ]]; then
    RUN_ID=$existing
  fi
fi
RUN_ID=${RUN_ID:-$(new_run_id)}
export RUN_ID
[[ "$RUN_ID" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || die 'RUN_ID contains unsupported characters.'
if [[ -f "$(candidate_file "$RUN_ID")" ]]; then
  die "Candidate already prepared for RUN_ID $RUN_ID. Start a new RUN_ID to prepare a different candidate."
fi

mkdir -p "$(state_dir "$RUN_ID")" "$RUNTIME_ROOT"
chmod 700 "$RUNTIME_ROOT" "$(state_dir "$RUN_ID")"

deda_tag_ref="${DEDA_QUAL_DEDA_REPOSITORY}:${RC_TAG}"
note "Resolving published DEDA candidate $deda_tag_ref (will not rebuild DEDA)"
deda_digest=$(resolve_manifest_digest "$deda_tag_ref")
DEDA_IMAGE="${DEDA_QUAL_DEDA_REPOSITORY}@${deda_digest}"
export DEDA_IMAGE
assert_immutable_image DEDA_IMAGE

note "Pulling and inspecting $DEDA_IMAGE"
docker pull "$DEDA_IMAGE" >/dev/null
revision=$(image_oci_revision "$DEDA_IMAGE")
assert_revisions_match "$revision" "$RC_COMMIT"

github_tag="${RUNNER_REGISTRY}/deda-github-runner:${RC_TAG}"
azure_tag="${RUNNER_REGISTRY}/deda-azure-runner:${RC_TAG}"
gitlab_tag="${RUNNER_REGISTRY}/deda-gitlab-runner:${RC_TAG}"

note "Publishing operator-owned runner images from checkout $RC_COMMIT"
docker buildx inspect --bootstrap >/dev/null
docker buildx build --platform linux/amd64,linux/arm64 \
  --build-arg RUNNER_SHA256_AMD64="$RUNNER_SHA256_AMD64" \
  --build-arg RUNNER_SHA256_ARM64="$RUNNER_SHA256_ARM64" \
  -t "$github_tag" --push "$REPO_ROOT/examples/ci-runners/github-actions"
docker buildx build --platform linux/amd64,linux/arm64 \
  --build-arg AGENT_SHA256_AMD64="$AGENT_SHA256_AMD64" \
  --build-arg AGENT_SHA256_ARM64="$AGENT_SHA256_ARM64" \
  -t "$azure_tag" --push "$REPO_ROOT/examples/ci-runners/azure-pipelines"
docker buildx build --platform linux/amd64,linux/arm64 \
  -t "$gitlab_tag" --push "$REPO_ROOT/examples/ci-runners/gitlab"

github_digest=$(resolve_manifest_digest "$github_tag")
azure_digest=$(resolve_manifest_digest "$azure_tag")
gitlab_digest=$(resolve_manifest_digest "$gitlab_tag")
GITHUB_QUAL_RUNNER_IMAGE="${RUNNER_REGISTRY}/deda-github-runner@${github_digest}"
AZURE_QUAL_RUNNER_IMAGE="${RUNNER_REGISTRY}/deda-azure-runner@${azure_digest}"
GITLAB_QUAL_RUNNER_IMAGE="${RUNNER_REGISTRY}/deda-gitlab-runner@${gitlab_digest}"
export GITHUB_QUAL_RUNNER_IMAGE AZURE_QUAL_RUNNER_IMAGE GITLAB_QUAL_RUNNER_IMAGE
assert_all_candidate_pins

QUAL_STARTED_UTC=$(utc_now)
export QUAL_STARTED_UTC
write_candidate_env
persist_state
printf '%s\n' "$RUN_ID" > "$RUNTIME_ROOT/current"
chmod 600 "$RUNTIME_ROOT/current"

note "Prepared RUN_ID $RUN_ID"
note "RC_TAG=$RC_TAG"
note "RC_COMMIT=$RC_COMMIT"
note "DEDA_IMAGE=$DEDA_IMAGE"
note "GITHUB_QUAL_RUNNER_IMAGE=$GITHUB_QUAL_RUNNER_IMAGE"
note "AZURE_QUAL_RUNNER_IMAGE=$AZURE_QUAL_RUNNER_IMAGE"
note "GITLAB_QUAL_RUNNER_IMAGE=$GITLAB_QUAL_RUNNER_IMAGE"
note 'Later phases will consume these exact pins and will not rebuild them.'
