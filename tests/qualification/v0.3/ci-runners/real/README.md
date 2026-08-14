# Real-provider v0.3 qualification

This is an explicit operator action, never a normal CI action. Supplying
credentials is insufficient; every command needs `--confirm-real-provider-tests`.
Use dedicated, pre-existing provider targets and file paths for queue and runner
registration credentials. The harness never creates repositories, projects,
pools, or runner groups, and it does not delete the supplied targets.

To combine a real run with deterministic evidence, export the same `RUN_ID`
used by `run-deterministic.sh`; otherwise the aggregate correctly remains
`NOT_QUALIFIED`.

`run-all.sh` deploys a dedicated Swarm stack for each provider using the runner
registration files, then submits the configured GitHub Actions, Azure Pipelines,
and GitLab work and polls the provider APIs until every dispatched
pipeline/workflow and job has a successful conclusion. Provider success alone is
not sufficient: the harness also asserts that the DEDA-managed runner service
observed compatible demand, scaled `0 → N`, ran tasks, and eventually scaled
back to zero. It retains only sanitized identifiers, timestamps, statuses,
runner names, conclusions, and Swarm/DEDA scale evidence. The GitLab queue token
is used as a `PRIVATE-TOKEN` and must have API access to create and read
pipelines.

The aggregate remains `NOT_QUALIFIED` unless the run directory already contains
the matching deterministic `result.json` with `PASS`. It becomes `PASS` only
when all three provider results pass; any provider failure produces `FAIL`.
