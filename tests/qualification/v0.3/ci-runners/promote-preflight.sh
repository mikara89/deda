#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

qual=
manifest=
digest=
commit=
revision=
source_tag=
final_tag=

while [[ $# -gt 0 ]]; do
  case "$1" in
    --qual) qual=$2; shift 2 ;;
    --manifest) manifest=$2; shift 2 ;;
    --digest) digest=$2; shift 2 ;;
    --commit) commit=$2; shift 2 ;;
    --revision) revision=$2; shift 2 ;;
    --source-tag) source_tag=$2; shift 2 ;;
    --final-tag) final_tag=$2; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$qual" && -f "$qual" ]] || die 'release-qualification.json is required on the RC release'
[[ -n "$manifest" && -f "$manifest" ]] || die 'qualification-manifest.json is required on the RC release'
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "image digest must be sha256: plus 64 hex chars, got: ${digest:-<empty>}"
[[ -n "$commit" ]] || die 'source commit is required'
[[ -n "$revision" ]] || die 'image OCI revision is required'
[[ "$source_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-.+$ ]] || die "source_tag must be a prerelease, got: ${source_tag:-<empty>}"
[[ "$final_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "final_tag must be a stable version, got: ${final_tag:-<empty>}"
expected_final=${source_tag%%-*}
[[ "$final_tag" == "$expected_final" ]] || die "final_tag $final_tag does not match source release $source_tag; expected $expected_final"
[[ "$revision" == "$commit" ]] || die "image revision $revision does not match source commit $commit"

jq -e '
  .releaseQualification == "PASS"
  and .candidateMatched == true
  and .fullDeterministicQualification == "PASS"
  and ([.providers[]? | select(.provider == "github") | .status] | first) == "PASS"
  and ([.providers[]? | select(.provider == "azure-pipelines") | .status] | first) == "PASS"
  and ([.providers[]? | select(.provider == "gitlab") | .status] | first) == "PASS"
' "$qual" >/dev/null || die 'release-qualification.json is not a complete PASS (deterministic, all three providers, candidateMatched)'

image=$(jq -r '.candidateImage // empty' "$manifest")
manifest_commit=$(jq -r '.candidateCommit // empty' "$manifest")
github_digest=$(jq -r '.githubRunnerReferenceDigest // empty' "$manifest")
azure_digest=$(jq -r '.azureRunnerReferenceDigest // empty' "$manifest")
gitlab_digest=$(jq -r '.gitlabRunnerReferenceDigest // empty' "$manifest")
[[ "$image" == *"@${digest}" ]] || die "qualification-manifest.json candidateImage $image is not pinned to $digest"
[[ "$manifest_commit" == "$commit" ]] || die "qualification-manifest.json commit $manifest_commit does not match source commit $commit"
[[ "$github_digest" == sha256:* && "$azure_digest" == sha256:* && "$gitlab_digest" == sha256:* ]] || die 'qualification-manifest.json is missing digest-pinned runner reference digests'
evidence_commit=$(jq -r '.candidate.commit // empty' "$qual")
[[ -n "$evidence_commit" ]] || die 'release-qualification.json is missing candidate.commit'
[[ "$evidence_commit" == "$commit" ]] || die "release-qualification.json candidate commit $evidence_commit does not match source commit $commit"
qual_github=$(jq -r '.candidate.githubRunner // empty' "$qual")
qual_azure=$(jq -r '.candidate.azureRunner // empty' "$qual")
qual_gitlab=$(jq -r '.candidate.gitlabRunner // empty' "$qual")
[[ "$qual_github" == "$github_digest" ]] || die "github runner digest mismatch between aggregate ($qual_github) and manifest ($github_digest)"
[[ "$qual_azure" == "$azure_digest" ]] || die "azure runner digest mismatch between aggregate ($qual_azure) and manifest ($azure_digest)"
[[ "$qual_gitlab" == "$gitlab_digest" ]] || die "gitlab runner digest mismatch between aggregate ($qual_gitlab) and manifest ($gitlab_digest)"
note "promotion preflight passed for $source_tag -> $final_tag ($digest)"
