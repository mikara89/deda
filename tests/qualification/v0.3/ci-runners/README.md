# v0.3 CI runner release qualification

This harness qualifies DEDA's CI runner autoscaling for GitHub Actions, Azure
Pipelines, and GitLab CI. It has two intentionally separate levels:

1. `./run-deterministic.sh --fast` or `--full` runs a local Docker Swarm against
   the stateful provider simulator. It records evidence under
   `tests/qualification/results/<RUN_ID>/v0.3-ci/`.
2. [`real/`](real/README.md) is an explicit, operator-run flow against dedicated
   pre-existing SaaS targets. It is opt-in and never runs merely because secret
   environment variables exist.

`fastQualification` PASS and `fullDeterministicQualification` PASS are
implementation evidence, not a release qualification. They are not equivalent
to `releaseQualification` PASS, which also requires real GitHub Actions, Azure
Pipelines, and GitLab CI evidence bound to the same commit and `sha256` image
digests. `RESULT.md` therefore reports `RELEASE QUALIFICATION: NOT_QUALIFIED`
until that aggregate is complete. `NOT_RUN` is never converted into `PASS`.

The simulator records endpoint, timestamp, response mode, and bounded request
counts. It never records authorization headers. Qualification secrets are
short-lived Docker secrets and are excluded from result files.

Full deterministic mode uses qualification images derived from the real PR10
runner images. The fake provider binaries keep the API interaction
deterministic while Swarm still signals the actual GitHub, Azure, and GitLab
runner entrypoints, so active-job protection is exercised under the same
wrapper/PID1 path used by the release images.

Full mode runs three real Swarm `5 → 0` drain cycles per provider. Real-provider
qualification requires digest-pinned DEDA and runner images and binds its
evidence to the deterministic candidate commit and image ID before `PASS` is
allowed.
