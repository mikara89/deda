# Real-provider v0.3 qualification

This is an explicit operator action, never a normal CI action. Supplying
credentials is insufficient; every command needs `--confirm-real-provider-tests`.
Use dedicated, pre-existing provider targets and file paths for queue and runner
registration credentials. The harness never creates repositories, projects,
pools, or runner groups, and it does not delete the supplied targets.

To combine a real run with deterministic evidence, export the same `RUN_ID`
used by `run-deterministic.sh`. Both runs must also use the same digest-pinned
`REAL_DEDA_IMAGE` / `DEDA_IMAGE` and commit; otherwise the aggregate remains
`NOT_QUALIFIED`.

All four candidate image variables are mandatory and must be immutable
`image@sha256:...` references: `REAL_DEDA_IMAGE`, `GITHUB_QUAL_RUNNER_IMAGE`,
`AZURE_QUAL_RUNNER_IMAGE`, and `GITLAB_QUAL_RUNNER_IMAGE`. Set those same four
pins **before** the matching `run-deterministic.sh --full` run; otherwise the
deterministic manifest records null runner reference digests and
`candidateMatched` stays false. The harness records image IDs and refuses a
release `PASS` unless the deterministic and real manifests identify the same
DEDA candidate and the same three runner reference digests.

`run-all.sh` deploys a dedicated Swarm stack for each provider using the runner
registration files, then submits the configured GitHub Actions, Azure Pipelines,
and GitLab work and polls the provider APIs until every dispatched
pipeline/workflow and job has a successful conclusion. Provider success alone is
not sufficient: the harness also asserts that the DEDA-managed runner service
observed compatible demand, scaled `0 → N`, ran tasks, and eventually scaled
back to zero. It retains only sanitized identifiers, timestamps, statuses,
runner/agent identities, conclusions, and Swarm/DEDA scale evidence. Provider
job identities are correlated to the DEDA-created Swarm tasks: GitHub by runner
name, Azure by timeline `workerName`, and GitLab by runner/manager name. The
GitLab queue token is used as a `PRIVATE-TOKEN` and must have API access to
create and read pipelines.

The aggregate remains `NOT_QUALIFIED` unless the run directory already contains
matching full-deterministic `result.json`, manifest, and candidate identity.
It becomes `PASS` only when full deterministic qualification is `PASS`, all
three provider results pass, and candidate binding succeeds; any provider or
candidate failure produces `FAIL`/`NOT_QUALIFIED`.
