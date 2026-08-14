# Hetzner v0.2 release qualification

This is a reusable release gate for a supplied DEDA release-candidate image. It is deliberately not normal pull-request CI: it creates a temporary three-manager Docker Swarm in Hetzner Cloud, runs deterministic failure scenarios, and retains sanitized evidence locally.

The harness uses the official `hcloud` CLI only. It creates one private Network/subnet, Spread Placement Group, Firewall, temporary SSH key, and exactly three servers. Every resource has `purpose=deda-qualification`, `version=v0-2`, the exact generated `run` label, and an `expires_at` label (default: 26 hours). The firewall exposes only SSH from `DEDA_QUAL_SSH_CIDR`; Docker, Redis, RabbitMQ, Prometheus, Swarm, and the socket proxy stay private.

## Run a short qualification

```bash
export HCLOUD_TOKEN=...
export DEDA_IMAGE=ghcr.io/mikara89/deda:v0.2.0-preview.1
export DEDA_QUAL_SSH_CIDR=<my-public-ip>/32

./provision.sh
./configure-swarm.sh
./deploy-stack.sh
./run-all.sh
./collect-evidence.sh
./destroy.sh --run <RUN_ID>
```

`DEDA_IMAGE` is mandatory and may not be `latest`. Provisioning generates an ephemeral ed25519 key under `.runtime/<RUN_ID>/` with mode 0600; neither that key nor `HCLOUD_TOKEN` is uploaded to the servers. Before spending money, use `./provision.sh --dry-run` (or `DEDA_QUAL_DRY_RUN=1 ./provision.sh`) to validate prerequisites and print the intended resources.

When the repository is accessed from WSL through `/mnt/...`, the harness automatically stores runtime state under `~/.local/state/deda-qualification/hetzner` instead. Windows-mounted files commonly appear as mode 0777 to WSL OpenSSH and are rejected as private keys. If a run created with an older harness stopped at that error, preserve the existing VMs and migrate it once with `./migrate-wsl-runtime.sh --run <RUN_ID>`, then continue with `./configure-swarm.sh`; do not provision a second cluster.

`qualify.sh` supplies the equivalent `provision`, `configure`, `deploy`, `run`, `collect`, and `destroy` entry points. Individual scripts remain available for diagnosis.

## Soak and evidence

After the short suite, start the resilient manager-hosted soak; it survives a local terminal/runner disconnect:

```bash
./soak/start-soak.sh --duration 24h --services 20
./soak/soak-status.sh
./soak/finish-soak.sh          # inspect only
./soak/finish-soak.sh --wait   # explicitly wait for completion
./collect-evidence.sh
```

Evidence is saved below `tests/qualification/results/<RUN_ID>/`, including scenario result JSON, node/service state, DEDA logs, versions, candidate digests, metrics, and `RESULT.md`. The collector redacts token/password/secret-like values. Creating this harness or passing a dry run is not a release qualification PASS: only a successfully completed real-cloud suite can supply that evidence.

The soak defaults to 20 autoscaled services and accepts `--services 1..50` (or `DEDA_QUAL_SOAK_SERVICES`). It rotates metric load and five recoverable disturbances, and records readiness, the single Redis lease owner, service/task placement, local controller resource usage, logs, and metrics. A completed soak `FAIL` makes the release recommendation fail; `NOT_RUN` remains allowed for the short qualification gate.

## Preventing cost leaks

List outstanding qualification resources at any time:

```bash
HCLOUD_TOKEN=... ./list-runs.sh
```

Clean up only one exact run (safe to repeat after partial provisioning):

```bash
HCLOUD_TOKEN=... ./destroy.sh --run 20260813-155500-a1b2c3 --yes
```

`destroy.sh` reselects each object by all three qualification labels before deleting it; it never performs a broad prefix deletion. Do not delete the local run directory before collecting evidence.
