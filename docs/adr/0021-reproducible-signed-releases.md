# ADR-0021: Reproducible and Signed Release Pipeline

**Status:** Accepted

## Context

Production users need immutable, verifiable artifacts for both supported Linux
architectures and the Docker CLI plugin. Mutable action and container tags also
make CI and example deployments vulnerable to upstream changes.

## Decision

Version tags build native `linux/amd64` and `linux/arm64` candidates addressed
only by immutable digest. Each candidate digest must pass the vulnerability
gate before the workflow assembles an unadvertised multi-architecture manifest.
The verified manifest digest is signed with Cosign's GitHub OIDC identity before
any public `latest` or semantic-version tag is created. The release workflow
publishes NativeAOT CLI archives for Linux x64, Linux arm64, and Windows x64
together with SHA-256 checksums, an SPDX SBOM, and a GitHub artifact provenance
attestation.

All third-party GitHub Actions and the example Docker socket proxy are pinned to
immutable digests. Dependabot proposes routine updates for NuGet, Actions, and
Docker dependencies. CodeQL, dependency review, and an 80% aggregate line
coverage threshold across the production packages exercised by unit tests are
required release-quality checks. The Docker transport is verified separately by
the real-Swarm job because its socket calls cannot be meaningfully covered by a
mock-only unit run.

## Alternatives Considered

- Mutable major-version action tags are easier to read but can change without a
  repository commit.
- A single emulated multi-architecture build is simpler but significantly
  slower than native architecture runners for NativeAOT.
- Long-lived signing keys create a secret-rotation burden; keyless OIDC signing
  binds the signature to the GitHub workflow identity instead.

## Consequences

- Releases are auditable and consumers can verify checksums, provenance, SBOMs,
  vulnerability reports, and image signatures.
- A failed scan or signature step cannot leave a rejected digest advertised by
  a public release tag.
- Maintainers must review digest update pull requests and periodically confirm
  that pinned actions and base images remain supported.
- Release publication requires GitHub Actions OIDC and artifact-attestation
  permissions.
