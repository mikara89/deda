# GitLab Runner

This image extends the pinned multi-architecture `gitlab/gitlab-runner:alpine-v17.11.0` image. The runner manager remains root so it can read the root-only authentication secret and configuration; its shell executor explicitly drops every job to the unprivileged `ci-job` user, which cannot read that configuration. The shell executor is deliberately limited to simple tooling jobs; it has no Docker socket and should only serve trusted projects because shell jobs share the runner task environment.

Create a group or project runner in GitLab first, set its tags to exactly `linux,deda`, disable **Run untagged jobs**, and store its `glrt-…` runner authentication token separately from the API token DEDA uses to read jobs:

```bash
docker buildx build --platform linux/amd64,linux/arm64 -t REGISTRY/deda-gitlab-runner:v0.3.0 --push .
docker secret create gitlab-queue-reader - < gitlab-queue-reader.txt
docker secret create gitlab-runner-auth - < gitlab-runner-auth.txt
docker stack deploy -c stack.yml ci-gitlab
```

For self-managed GitLab, change both `CI_SERVER_URL` and the trigger URL, then update `allowedHosts`. Deploy with the shown stack name or change `allowedServices` in the policy file to the resulting Swarm service name. The observer token is a least-privilege API token able to read jobs for the listed projects; the auth token only registers runner managers and is not a DEDA credential.

Queue `gitlab-ci.example.yml` to observe `0 → N → 0`. The task registration has a task-derived name, explicit `concurrent = 1`, and a writable per-task config directory, so each replica gets a distinct `.runner_system_id`; it is never baked into the image. GitLab configuration sets the runner's tags and `runUntagged` policy in the UI, while DEDA uses the same values solely for queue compatibility.

The stack delivers `SIGQUIT`, GitLab Runner's documented graceful-stop signal: it stops accepting jobs and exits after active work. The wrapper then retries bounded runner-manager cleanup without logging the authentication token. With a runner authentication token GitLab retains the reusable runner object by design; delete that object in the UI/API when it is permanently no longer wanted. A job longer than Swarm's 30-minute stop grace can still be killed. Inspect DEDA CI metrics (including the cached-observation age) and retain `docker service logs` centrally.
