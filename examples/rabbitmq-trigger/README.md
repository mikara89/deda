# RabbitMQ trigger example

This stack demonstrates a DEDA-managed replicated service whose desired count
follows RabbitMQ `messages_ready`. The demo worker sleeps rather than consuming
messages, so queued messages remain visible while you inspect scale-up.

## Prerequisites

- Active Linux Docker Swarm
- Manager-node Docker context
- Two external secrets whose values match the local demo RabbitMQ account

```bash
printf '%s' 'admin' | docker secret create rabbitmq_user -
printf '%s' 'changeme' | docker secret create rabbitmq_pass -
```

These are disposable demonstration values. Use generated, least-privilege
credentials outside this isolated example.

## Deploy

```bash
docker stack deploy -c examples/rabbitmq-trigger/stack.yml deda-rabbit
```

Wait for RabbitMQ, then declare the queue and publish messages through the
management API:

```bash
curl --user admin:changeme \
  --request PUT \
  --header 'content-type: application/json' \
  --data '{"auto_delete":false,"durable":true,"arguments":{}}' \
  http://MANAGER_IP:15672/api/queues/%2F/my-queue

for i in $(seq 1 200); do
  curl --silent --user admin:changeme \
    --request POST \
    --header 'content-type: application/json' \
    --data '{"properties":{},"routing_key":"my-queue","payload":"demo","payload_encoding":"string"}' \
    http://MANAGER_IP:15672/api/exchanges/%2F/amq.default/publish >/dev/null
done
```

## Expected behavior

With 200 ready messages and `targetPerReplica=50`, DEDA calculates four
replicas. `stepUp=5` permits the change in one cycle.

```bash
docker service logs --since 5m deda-rabbit_deda
docker service inspect deda-rabbit_worker-rmq \
  --format '{{.Spec.Mode.Replicated.Replicas}}'
curl --fail http://MANAGER_IP:8080/health/ready
```

Because the demo workers do not consume, the queue will not drain on its own.
Purge it from the management UI or API to observe stabilized downscale.

## Clean up

```bash
docker stack rm deda-rabbit
docker secret rm rabbitmq_user rabbitmq_pass
```

See the canonical [RabbitMQ guide](../../docs/triggers/rabbitmq.md), including
per-service credential secrets.
