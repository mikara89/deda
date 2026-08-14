# Configuration reference

DEDA has two configuration layers:

1. Docker service labels configure one autoscaled service.
2. Environment variables configure the DEDA process globally.

All service labels must be strings and belong under `deploy.labels`. Numeric
parsing uses invariant culture (`.` as the decimal separator).

## Core service labels

All names below use the `com.deda.autoscale.` prefix.

| Label | Type | Default | Allowed value | Behavior and example | Operational consideration |
| --- | --- | --- | --- | --- | --- |
| `enabled` | Boolean | Disabled | `true` or `false` | `"true"` opts the service in. Missing or false values skip it; an explicitly invalid value is a configuration error. | Only replicated services are evaluated; global services are ignored. |
| `min` | Integer | `0` | `0`–`2147483647`, and no greater than `max` | Hard lower bound, for example `"1"`. | Use `0` only after reviewing scale-to-zero startup behavior. |
| `max` | Integer | `50` | `0`–`2147483647`, and no less than `min` | Hard upper bound, for example `"20"`. | Choose a limit the workload and dependencies can sustain. |
| `targetPerReplica` | Number | `50` | Finite and greater than `0` | Active-work recommendation is `ceil(work / targetPerReplica)`, for example `"25"`. | This is the main capacity assumption; measure it under load. |
| `activationThreshold` | Number | `5` | Finite and at least `0` | Work at or below this value recommends `min`, for example `"1"`. | It identifies inactivity; it does not gate ordinary proportional downscaling. |
| `cooldownSeconds` | Integer | `60` | At least `0` | Blocks downscale for this many seconds after a DEDA scale-up. `"0"` disables it. | It does not block scale-up. Large values delay recovery of spare capacity. |
| `scaleDownDelaySeconds` | Integer | `120` | `0`–`86400` | Retains the highest recent recommendation during the window. `"0"` disables it. | The window is in memory and resets when DEDA restarts. |
| `scaleToZeroGraceSeconds` | Integer | `0` | `0`–`86400` | Requires continuous inactivity before a positive replica count can reach zero, for example `"60"`. | Trigger failures reset inactivity evidence. Other downscale controls still apply. |
| `stepUp` | Integer | `10` | At least `0` | Maximum replicas added per reconciliation. `"0"` means unlimited. | A small value slows response to bursts. |
| `stepDown` | Integer | `5` | At least `0` | Maximum replicas removed per reconciliation. `"0"` means unlimited. | A small value provides a gradual drain. |
| `failsafe` | String | `hold` | `hold`, `min`, or `max` | Chooses the target when metric retrieval or validation fails, for example `"max"`. Explicit invalid values are configuration errors. | See [fail-safe modes](#fail-safe-modes). |
| `trigger.type` | String | None | `rabbitmq`, `prometheus`, `http`, `github-actions`, `azure-pipelines`, or `gitlab-ci` | Selects the adapter, for example `"github-actions"`. | Missing or unknown types are logged as service errors. |
| `trigger.*` | String | Trigger-specific | See trigger guide | Supplies settings such as `trigger.timeoutSeconds: "5"`. | Labels are visible through the Docker API; never place passwords in them. |
| `pollSeconds` | Integer | Ignored | Ignored | A value such as `"30"` has no effect; this is a deprecated compatibility label. | `DEDA_POLL_SECONDS` is the only reconciliation interval. |

Missing scaling labels use their documented defaults. Explicit malformed numeric
values and invalid enum values fail closed: DEDA logs a configuration error and
does not autoscale that service.

## Trigger labels

| Trigger | Required labels | Optional labels |
| --- | --- | --- |
| RabbitMQ | `trigger.type=rabbitmq`, `trigger.url`, `trigger.queue` | `trigger.vhost`, `trigger.metric`, `trigger.timeoutSeconds`, `trigger.credentialsRef` |
| Prometheus | `trigger.type=prometheus`, `trigger.url`, `trigger.query` | `trigger.timeoutSeconds` |
| HTTP | `trigger.type=http`, `trigger.url` | `trigger.timeoutSeconds`, `trigger.valuePath` |
| GitHub Actions | `trigger.type=github-actions`, `trigger.owner`, `trigger.repos`, `trigger.credentialsRef` | `trigger.labels`, `trigger.scope`, `trigger.apiUrl` |
| Azure Pipelines | `trigger.type=azure-pipelines`, `trigger.organizationUrl`, `trigger.poolId` or `trigger.poolName`, `trigger.credentialsRef` | `trigger.demands` |
| GitLab CI | `trigger.type=gitlab-ci`, `trigger.projects`, `trigger.credentialsRef` | `trigger.url`, `trigger.tags`, `trigger.runUntagged` |

See the [RabbitMQ](triggers/rabbitmq.md), [Prometheus](triggers/prometheus.md),
and [HTTP](triggers/http.md) references for exact response semantics.

## Fail-safe modes

Fail-safe behavior applies only when the trigger returns an error or a
non-finite/negative workload.

| Mode | Failure target | Appropriate use | Main risk |
| --- | --- | --- | --- |
| `hold` | Current replicas | Conservative default when the last known demand is uncertain. | Capacity does not increase during a metric outage. |
| `min` | Configured `min` | Workloads where reducing capacity during monitoring failure is intentional. | With `min=0`, a single failure can intentionally select zero without waiting for scale-to-zero grace. |
| `max` | Configured `max` | Critical consumers where metric failure should favor capacity. | A monitoring outage can consume maximum resources and stress dependencies. |

No mode is universally correct. Set it from the failure policy of the workload,
not from the expected steady state.

## DEDA environment variables

Out-of-range integer environment variables are clamped to the listed range;
missing or unparsable values use the default.

| Variable | Default | Allowed value | Purpose |
| --- | --- | --- | --- |
| `DEDA_POLL_SECONDS` | `10` | `1`–`3600` seconds | Authoritative global reconciliation interval. |
| `DEDA_MAX_RECONCILE_BACKOFF_SECONDS` | `60` | `1`–`3600` seconds | Maximum exponential delay after controller-level failures. |
| `DEDA_HTTP_TIMEOUT_SECONDS` | `5` | `1`–`120` seconds | Named-client default; current adapters apply their own per-trigger default of 5 seconds. |
| `DEDA_MAX_SERVICES_PER_CYCLE` | `0` | `0`–`10000` | Page size; `0` evaluates all services. |
| `DEDA_JITTER_ENABLED` | `true` | Boolean | Enables stable-hash service ordering before paging; it does not add a random delay. |
| `DEDA_LOG_DECISIONS` | `true` | Boolean | Retained host option. Decisions are currently logged through structured telemetry. |
| `DEDA_HTTP_PORT` | `8080` | `1`–`65535` | Port for health and Prometheus endpoints. |
| `DEDA_SECRETS_DIRECTORY` | `/run/secrets` | Non-empty path | Directory for named per-service credential secrets. |
| `DEDA_CREDENTIAL_POLICY_FILE` | Disabled | Readable JSON file | Operator-owned credential bindings used by `trigger.credentialsRef`. |
| `DEDA_ALLOW_LEGACY_CREDENTIALS_SECRET` | `false` | Boolean | Temporarily enables legacy label-selected `trigger.credentialsSecret`; use only for trusted-cluster migration. |
| `DEDA_MAX_CONCURRENT_SERVICES` | `8` | `1`–`256` | Maximum simultaneous service evaluations in one reconciliation cycle. |
| `DEDA_RECONCILE_TIMEOUT_SECONDS` | `120` | `1`–`3600` seconds | Maximum duration of one reconciliation cycle. |
| `DEDA_READINESS_MAX_AGE_SECONDS` | `60` | `1`–`3600` seconds | Readiness freshness floor; effective maximum age is at least three poll intervals. |
| `RABBITMQ_USER` / `RABBITMQ_PASS` | None | Non-empty strings | Global RabbitMQ credentials; direct values take precedence over file variants. |
| `RABBITMQ_USER_FILE` / `RABBITMQ_PASS_FILE` | None | Readable file paths | Global RabbitMQ credentials from mounted files. |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | Disabled | OTLP endpoint URI | Enables standard OpenTelemetry OTLP metrics and traces. |
| `DEDA_REDIS_CONNECTION` | Disabled | StackExchange.Redis connection string | Enables optional leader election. |
| `DEDA_LEADER_LOCK_KEY` | `deda:leader` | Non-empty string | Redis lease key. |
| `DEDA_INSTANCE_ID` | Host name plus process ID | Non-empty, unique string | Lease owner identity. |
| `DEDA_LEADER_LEASE_SECONDS` | `30` | `5`–`300` | Redis lease TTL. |
| `DEDA_LEADER_RENEW_SECONDS` | `10` | `1`–`299`, and less than the lease | Lease renewal interval. |
| `DOCKER_HOST` | `unix:///var/run/docker.sock` on Linux | `unix://`, `tcp://`, `http://`, or `https://` | Docker API endpoint. Windows named pipes are not supported. |

Standard OpenTelemetry variables such as `OTEL_EXPORTER_OTLP_PROTOCOL`,
`OTEL_EXPORTER_OTLP_HEADERS`, and exporter timeout settings are handled by the
OpenTelemetry SDK; they are not DEDA-specific variables.
