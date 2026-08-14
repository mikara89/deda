# v0.3 CI runner release qualification

This harness qualifies DEDA's CI runner autoscaling for GitHub Actions, Azure
Pipelines, and GitLab CI. It has two intentionally separate levels:

1. `./run-deterministic.sh --fast` or `--full` runs a local Docker Swarm against
   the stateful provider simulator. It records evidence under
   `tests/qualification/results/<RUN_ID>/v0.3-ci/`.
2. [`real/`](real/README.md) is an explicit, operator-run flow against dedicated
   pre-existing SaaS targets. It is opt-in and never runs merely because secret
   environment variables exist.

Deterministic PASS is implementation evidence, not a release qualification.
`RESULT.md` therefore reports `RELEASE QUALIFICATION: NOT_QUALIFIED` until all
three real-provider qualifications and every mandatory deterministic scenario
have supplied PASS evidence.

The simulator records endpoint, timestamp, response mode, and bounded request
counts. It never records authorization headers. Qualification secrets are
short-lived Docker secrets and are excluded from result files.
