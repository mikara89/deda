#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

[[ "${1:-}" == --confirm-evidence-upload ]] || die 'Evidence upload requires --confirm-evidence-upload; refusing to upload without explicit confirmation.'
[[ $# -eq 1 ]] || die 'Usage: ./upload-evidence.sh --confirm-evidence-upload'

require_command gh
require_command jq
require_command docker
docker buildx version >/dev/null 2>&1 || die 'docker buildx is required to re-verify the published DEDA digest.'

load_run
assert_rc_checkout
assert_all_candidate_pins

root=$(canonical_result_dir "$RUN_ID")
qual="$root/real-provider-result.json"
manifest="$root/manifest.json"
[[ -f "$qual" ]] || die "Canonical real-provider-result.json is missing at $qual"
[[ -f "$manifest" ]] || die "Canonical manifest.json is missing at $manifest"

jq -e '
  .releaseQualification == "PASS"
  and .candidateMatched == true
  and .fullDeterministicQualification == "PASS"
  and ([.providers[]? | select(.provider == "github") | .status] | first) == "PASS"
  and ([.providers[]? | select(.provider == "azure-pipelines") | .status] | first) == "PASS"
  and ([.providers[]? | select(.provider == "gitlab") | .status] | first) == "PASS"
' "$qual" >/dev/null || die 'Upload requires canonical releaseQualification PASS, candidateMatched true, full deterministic PASS, and PASS from GitHub, Azure Pipelines, and GitLab.'

tag_commit=$(git -C "$REPO_ROOT" rev-parse --verify --quiet "${RC_TAG}^{commit}" || true)
[[ "$tag_commit" == "$RC_COMMIT" ]] || die "RC tag $RC_TAG now resolves to ${tag_commit:-<missing>}, not prepared RC_COMMIT $RC_COMMIT"

deda_tag_ref="${DEDA_QUAL_DEDA_REPOSITORY:-ghcr.io/mikara89/deda}:${RC_TAG}"
published_digest=$(docker buildx imagetools inspect "$deda_tag_ref" --format '{{.Manifest.Digest}}' 2>/dev/null || true)
if [[ -z "$published_digest" || "$published_digest" == '<no value>' ]]; then
  published_digest=$(docker buildx imagetools inspect "$deda_tag_ref" 2>/dev/null | awk '/^Digest:/{print $2; exit}')
fi
[[ "$DEDA_IMAGE" == *"@${published_digest}" ]] || die "Published $deda_tag_ref digest ${published_digest:-<missing>} does not match prepared $DEDA_IMAGE"

if ! docker image inspect "$DEDA_IMAGE" >/dev/null 2>&1; then
  docker pull "$DEDA_IMAGE" >/dev/null
fi
revision=$(image_oci_revision "$DEDA_IMAGE")
assert_revisions_match "$revision" "$RC_COMMIT"

note "Uploading canonical evidence to GitHub Release $RC_TAG"
gh release upload "$RC_TAG" \
  "${qual}#release-qualification.json" \
  "${manifest}#qualification-manifest.json" \
  --clobber

note "Uploaded release-qualification.json and qualification-manifest.json to $RC_TAG."
note 'This harness does not dispatch promote-release.yml. Promotion remains a separate operator action.'
