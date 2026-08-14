# CI provider simulator

This is a deliberately small, Python-standard-library HTTP server. It exposes
only the API paths currently called by DEDA's GitHub Actions, Azure Pipelines,
and GitLab CI providers. `POST /__admin/state` replaces provider state or sets
a deterministic failure mode. Request evidence records the endpoint, time, and
response mode only—never request headers or credentials.

Example state update:

```sh
curl -fsS -X POST http://simulator:8081/__admin/state \
  -H 'content-type: application/json' \
  -d '{"github":{"jobs":[{"status":"queued","labels":["self-hosted","linux","deda"]}]}}'
```

`real-runner/` contains qualification-only variants built on top of the real PR10
GitHub, Azure, and GitLab runner images. Their fake provider binaries replace
the network/API surface, but the real entrypoint remains PID 1 and receives the
same Swarm shutdown signals as the release images.
