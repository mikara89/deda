# HTTP trigger example

This self-contained stack serves `{"queue":{"pending":75}}` from Nginx and
uses `valuePath=queue.pending` to scale a sleeping demo worker.

## Deploy

```bash
docker stack deploy -c examples/http-trigger/stack.yml deda-http
```

## Expected behavior

`ceil(75 / 25) = 3`, so the worker moves from one to three replicas after a
successful reconciliation.

```bash
curl --fail http://MANAGER_IP:8081/health/ready
docker service logs --since 2m deda-http_deda
docker service inspect deda-http_worker \
  --format '{{.Spec.Mode.Replicated.Replicas}}'
```

The metric is intentionally static so the example is deterministic. Replace
`metric-api` with an application endpoint for real use.

## Clean up

```bash
docker stack rm deda-http
```

See the [HTTP trigger guide](../../docs/triggers/http.md).
