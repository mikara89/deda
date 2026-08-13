# RabbitMQ trigger

The `rabbitmq` trigger reads one queue property from the RabbitMQ Management
HTTP API:

```text
GET {url}/api/queues/{escaped-vhost}/{escaped-queue}
```

RabbitMQ's management plugin must be enabled and reachable from DEDA. The vhost
and queue path components are URL-escaped by DEDA.

## Labels

All names use the `com.deda.autoscale.` prefix.

| Label | Required | Default | Supported value |
| --- | --- | --- | --- |
| `trigger.type` | Yes | — | `rabbitmq` |
| `trigger.url` | Yes | — | RabbitMQ Management API base URL, such as `http://rabbitmq:15672` |
| `trigger.queue` | Yes | — | Queue name |
| `trigger.vhost` | No | `/` | RabbitMQ virtual host |
| `trigger.metric` | No | `messages` | Documented metrics: `messages`, `messages_ready`, `messages_unacknowledged` |
| `trigger.timeoutSeconds` | No | `5` | Positive integer seconds |
| `trigger.credentialsRef` | No | Global credentials | Operator-owned credential-policy binding name |

The response property must be numeric and the final value must be finite and
non-negative. HTTP errors, missing properties, invalid JSON, credential errors,
and invalid values invoke the service's fail-safe policy.

## Complete service configuration

```yaml
services:
  worker:
    image: example/orders-worker:1.0
    networks: [application]
    deploy:
      replicas: 1
      labels:
        com.deda.autoscale.enabled: "true"
        com.deda.autoscale.min: "1"
        com.deda.autoscale.max: "20"
        com.deda.autoscale.targetPerReplica: "25"
        com.deda.autoscale.cooldownSeconds: "60"
        com.deda.autoscale.scaleDownDelaySeconds: "120"
        com.deda.autoscale.trigger.type: "rabbitmq"
        com.deda.autoscale.trigger.url: "http://rabbitmq:15672"
        com.deda.autoscale.trigger.vhost: "/"
        com.deda.autoscale.trigger.queue: "orders"
        com.deda.autoscale.trigger.metric: "messages_ready"
        com.deda.autoscale.trigger.timeoutSeconds: "5"
        com.deda.autoscale.failsafe: "hold"
```

DEDA, RabbitMQ, and the scaled service do not have to share a stack, but DEDA
must be able to resolve and reach `rabbitmq:15672`. See the runnable
[RabbitMQ example](../../examples/rabbitmq-trigger/README.md).

## Global credentials

Set credentials on the DEDA service, not on the scaled service:

```yaml
services:
  deda:
    environment:
      RABBITMQ_USER_FILE: /run/secrets/rabbitmq_user
      RABBITMQ_PASS_FILE: /run/secrets/rabbitmq_pass
    secrets:
      - rabbitmq_user
      - rabbitmq_pass

secrets:
  rabbitmq_user:
    external: true
  rabbitmq_pass:
    external: true
```

Create the secrets before deployment:

```bash
printf '%s' 'deda-reader' | docker secret create rabbitmq_user -
printf '%s' 'replace-with-a-generated-password' | docker secret create rabbitmq_pass -
```

`RABBITMQ_USER` and `RABBITMQ_PASS` are also supported, but process environment
values can be exposed through inspection and diagnostics. Direct values take
precedence over the corresponding `_FILE` variables.

## Per-service credentials

Different services can select different credentials. Create one secret whose
single-line content is `username:password`:

```bash
printf '%s' 'orders-user:replace-with-a-generated-password' \
  | docker secret create orders-rabbitmq -
```

Mount it on DEDA and configure an operator-owned credential policy. The scaled
service can reference a binding name, but cannot choose a mounted secret or an
arbitrary endpoint:

```yaml
services:
  deda:
    environment:
      DEDA_SECRETS_DIRECTORY: /run/secrets
      DEDA_CREDENTIAL_POLICY_FILE: /run/deda/credential-policy.json
    secrets:
      - orders-rabbitmq
    configs:
      - source: deda-credential-policy
        target: /run/deda/credential-policy.json

  worker:
    deploy:
      labels:
        com.deda.autoscale.trigger.credentialsRef: "orders"

secrets:
  orders-rabbitmq:
    external: true
configs:
  deda-credential-policy:
    file: ./credential-policy.json
```

`credential-policy.json` is controlled by the DEDA operator:

```json
{
  "orders": {
    "secret": "orders-rabbitmq",
    "allowedHosts": ["rabbitmq.internal"],
    "allowedServices": ["worker"]
  }
}
```

The binding requires an absolute `trigger.url`, an allowed host, and (when the
policy lists services) a matching service name or ID. Unknown bindings, wrong
hosts, malformed policy files, and path-traversal secret names fail closed.

`trigger.credentialsSecret` is a legacy trusted-cluster option and is disabled
by default. During migration only, set
`DEDA_ALLOW_LEGACY_CREDENTIALS_SECRET=true` to re-enable it.

DEDA reads `/run/secrets/orders-rabbitmq` by default, splits on the first colon,
and uses the result only for that service. `DEDA_SECRETS_DIRECTORY` changes the
base directory. Secret names must be single file names; absolute paths and path
traversal are rejected.

Security rules:

- Never put a password or connection credential in a Docker service label.
- Mount only secrets DEDA needs and restrict access to the DEDA service.
- Prefer a RabbitMQ account limited to the vhost and queues it must observe.
- Use distinct per-service secrets when tenants or RabbitMQ instances require
  separate access.

## Metric choice

- `messages` counts ready plus unacknowledged messages.
- `messages_ready` counts work waiting for a consumer.
- `messages_unacknowledged` counts work already delivered but not acknowledged.

For queue-worker capacity, `messages_ready` is usually the clearest backlog
signal. Choose `messages` when in-flight work must also contribute to desired
capacity, and test the result under your acknowledgement behavior.
