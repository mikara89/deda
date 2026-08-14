# GitHub Actions runner

Build with a released Actions runner archive checksum supplied by your release process (the Dockerfile refuses an empty checksum), publish it, then deploy:

```bash
docker buildx build --platform linux/amd64,linux/arm64 --build-arg RUNNER_SHA256_AMD64=048024cd2c848eb6f14d5646d56c13a4def2ae7ee3ad12122bee960c56f3d271 --build-arg RUNNER_SHA256_ARM64=f44255bd3e80160eb25f71bc83d06ea025f6908748807a584687b3184759f7e4 -t REGISTRY/deda-github-runner:v0.3.0 --push .
docker secret create github-queue-reader - < github-queue-reader.txt
docker secret create github-runner-admin - < github-runner-admin.txt
docker stack deploy -c stack.yml ci-github
```

Set the org/repositories and the same labels in `stack.yml`; the supplied workflow targets exactly `self-hosted`, `linux`, and `deda`. The observer token needs only access to list workflow jobs for the configured repositories. The separate runner-admin token needs permission to create registration and removal tokens (organization self-hosted runner write, or repository administration) and is never exposed to the workflow.

Dispatch `workflow.example.yml` and watch `docker service ls`; compatible jobs scale `0 → N`, and queued-plus-active observation prevents an immediate downscale while jobs run. The runner uses GitHub ephemeral registration and `--disableupdate`, so one completed job exits and image updates are explicit.

The root supervisor alone can read the runner-admin secret. It uses GitHub job-started/job-completed hooks as busy signals, then runs the actual runner and its job as the unprivileged `runner` user. On TERM, an idle runner is stopped; a busy ephemeral runner is deliberately left to finish its one job naturally. There remains a small dispatch race between the busy hook and Swarm termination, and a job exceeding the 30-minute grace can still be killed. Qualify the grace period with your longest job and alert on cancellations. Retain `docker service logs` externally; GitHub recommends preserving ephemeral-runner logs.

Troubleshoot API/rate behavior with DEDA's `deda_ci_*` metrics and logs. `refreshSeconds=15` bounds repeated observations between cache refreshes. Cleanup retries its short-lived removal-token request three times by default without logging a token; if the API remains unavailable, GitHub eventually removes disconnected ephemeral runners. The image pins Actions Runner 2.334.0; review its version and published checksums at every image release and within GitHub's supported update window when using `--disableupdate`.
