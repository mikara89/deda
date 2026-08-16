# Hetzner v0.3 release qualification

This is release/test infrastructure only. It qualifies an **already published**
DEDA release candidate on one temporary Hetzner Docker Swarm manager. It does
not change DEDA runtime behavior, rebuild DEDA, create tags, or promote a
release.

v0.3 release qualification still means exactly what the canonical harness
defines:

```text
full deterministic PASS
+ GitHub real-provider PASS
+ Azure Pipelines real-provider PASS
+ GitLab CI real-provider PASS
+ candidateMatched == true
+ exact same source commit
+ exact same DEDA digest
+ exact same three runner digests
= releaseQualification PASS
```

`fastQualification` PASS and `fullDeterministicQualification` PASS are not
`releaseQualification` PASS.

## Intended release flow

```text
merge this qualification-only PR
    ↓
cut v0.3.0-rc.2
    ↓
RC build/scan/sign/release completes
    ↓
git checkout --detach v0.3.0-rc.2
    ↓
./qualify.sh prepare --rc v0.3.0-rc.2 --runner-registry ghcr.io/mikara89
    ↓
./qualify.sh provision --dry-run
    ↓
./qualify.sh provision
    ↓
./qualify.sh configure
    ↓
./qualify.sh run --confirm-real-provider-tests
    ↓
releaseQualification PASS
    ↓
./qualify.sh upload --confirm-evidence-upload
    ↓
./qualify.sh destroy --run <RUN_ID> --yes
    ↓
operator manually dispatches promote-release.yml
    ↓
v0.3.0 aliases the exact qualified RC digest
```

Explicitly:

- Qualification does not equal promotion.
- No real provider tests run from credentials alone.
- No RC is created by this harness.
- No DEDA image is rebuilt by this harness.
- Any changed candidate digest requires a fresh qualification.
- Existing [v0.2 Hetzner qualification](../../v0.2/hetzner/README.md) remains
  the HA / multi-manager qualification source.

## Architecture

The operator machine (exact RC checkout) runs the **canonical** v0.3 scripts
under `tests/qualification/v0.3/ci-runners/`. The temporary Hetzner VM provides
only Docker Engine / Swarm. Local `docker` talks to that daemon over
`ssh://root@<server>`. Provider HTTP/API calls and credential files stay on the
operator machine. Docker secrets required by the existing runner/DEDA stacks
are created through the local Docker CLI against the remote daemon.

This directory is a wrapper. It does not reimplement deterministic scenarios or
GitHub / Azure / GitLab provider logic.

Default topology is **one** manager. v0.2 already qualifies multi-manager HA.
`DEDA_QUAL_MANAGER_COUNT` is reserved and must stay `1` in this harness.

## Operator commands

```bash
export HCLOUD_TOKEN=...
export DEDA_QUAL_SSH_CIDR=<public-ip>/32
# plus provider target metadata and *TOKEN_FILE paths; see env.example

./qualify.sh prepare --rc v0.3.0-rc.2 --runner-registry ghcr.io/mikara89
./qualify.sh provision --dry-run
./qualify.sh provision
./qualify.sh configure
./qualify.sh deterministic          # wrapper only; not a release PASS
./qualify.sh real --confirm-real-provider-tests
./qualify.sh run --confirm-real-provider-tests
./qualify.sh collect
./qualify.sh upload --confirm-evidence-upload
./qualify.sh destroy --run <RUN_ID> --yes
./list-runs.sh
```

`qualify.sh` is only a dispatcher. Every script remains directly runnable.

`provision --dry-run` requires `HCLOUD_TOKEN` locally, validates location /
server type / image / SSH CIDR, prints the planned resources and candidate
identity, and creates nothing.

## Candidate identity

The DEDA candidate must always be:

```text
ghcr.io/mikara89/deda@sha256:<digest>
```

with `org.opencontainers.image.revision == RC source commit`. The three
operator-owned runner images must also be `image@sha256:<digest>`. Mutable tags
such as `latest` or `v0.3` are rejected.

`prepare` resolves the published DEDA RC manifest, verifies the OCI revision,
builds/pushes the three runner images from the exact RC checkout, and writes
non-secret pins to `.runtime/<RUN_ID>/candidate.env`. Later phases consume
those exact pins and do not rebuild them.

## Security model

- `HCLOUD_TOKEN` stays on the operator machine. It is never uploaded, never
  written to state, and never copied into evidence.
- Ephemeral ed25519 SSH key, mode `0600`, run-scoped known_hosts.
- WSL checkouts under `/mnt` store runtime state under
  `~/.local/state/deda-qualification/hetzner-v0.3` so OpenSSH accepts the key.
- Labels on every Hetzner resource: `purpose=deda-qualification`,
  `version=v0-3`, `run=<safe RUN_ID>`, `expires_at=<UTC>` (default 12 hours).
- Firewall exposes SSH only, restricted to `DEDA_QUAL_SSH_CIDR`.
- Docker API, Redis, DEDA metrics/health, and runner services are not exposed.
- Docker connectivity is SSH only. TCP `2375`/`2376` is refused.
- Provider tokens are file paths. Their contents are never printed or written
  to evidence.
- Real SaaS tests require the exact flag `--confirm-real-provider-tests`.
- Evidence upload requires `--confirm-evidence-upload` and a canonical
  `releaseQualification` PASS. Upload uses `gh release upload --clobber` and
  does not dispatch `promote-release.yml`.
- `destroy` selects resources by all three labels (`purpose`, `version=v0-3`,
  `run`). It never does prefix deletion. Local evidence is kept.

## Evidence

Canonical files remain under `tests/qualification/results/<RUN_ID>/v0.3-ci/`:

- `result.json`
- `manifest.json`
- `real-provider-result.json`
- provider-specific evidence from the canonical harness

Hetzner metadata is added under `v0.3-ci/hetzner/` and summarized in
`hetzner/RESULT.md`. Canonical files in `v0.3-ci/` are not rewritten.
This layer does not invent alternate PASS calculations.
