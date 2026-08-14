# GitHub Actions runner

Build with a released Actions runner archive checksum supplied by your release process (the Dockerfile refuses an empty checksum), publish it, then deploy:

```bash
docker buildx build --platform linux/amd64,linux/arm64 --build-arg RUNNER_SHA256_AMD64=... --build-arg RUNNER_SHA256_ARM64=... -t REGISTRY/deda-github-runner:v0.3.0 --push .
docker secret create github-queue-reader - < github-queue-reader.txt
docker secret create github-runner-admin - < github-runner-admin.txt
docker stack deploy -c stack.yml ci-github
```

Set the org/repositories and the same labels in `stack.yml`; the supplied workflow targets exactly `self-hosted`, `linux`, and `deda`. The observer token needs only access to list workflow jobs for the configured repositories. The separate runner-admin token needs permission to create registration and removal tokens (organization self-hosted runner write, or repository administration) and is never exposed to the workflow.

Dispatch `workflow.example.yml` and watch `docker service ls`; compatible jobs scale `0 → N`, and queued-plus-active observation prevents an immediate downscale while jobs run. The runner uses GitHub ephemeral registration and `--disableupdate`, so one completed job exits and image updates are explicit.

On TERM the wrapper asks the runner process to stop and uses a 30-minute Swarm grace period before its hard kill. GitHub's ephemeral model prevents a second job after a completed job, but Swarm can select an active task and a job exceeding the grace period can still be killed. Qualify the chosen grace period with your longest job and alert on cancelled jobs. Retain `docker service logs` externally; GitHub recommends preserving ephemeral runner logs.

Troubleshoot API/rate behavior with DEDA's `deda_ci_*` metrics and logs. `refreshSeconds=15` bounds repeated observations between cache refreshes. Cleanup retries its short-lived removal-token request three times by default without logging a token; if the API remains unavailable, GitHub eventually removes disconnected ephemeral runners.
