# docker-deda — Docker CLI Plugin

`docker deda` is a Docker CLI plugin that installs, manages, and validates the
DEDA autoscaler on a Docker Swarm cluster. Instead of writing and maintaining a
Compose/stack file by hand, a single command deploys the complete DEDA stack
with production-oriented defaults that you should review for your cluster.

---

## How it works

Docker discovers a plugin binary named `docker-deda` (or `docker-deda.exe` on
Windows) in its CLI plugins directory. Release archives contain the published
`Docker.Deda.Cli` executable; rename it while installing. Docker then exposes it
as the `docker deda` sub-command.

On `install`, it:

1. Checks that Docker is available and the node is a Swarm manager.
2. Renders a built-in production stack template with your flags (image, port,
   poll interval, etc.).
3. Writes the rendered YAML to a temp file and runs `docker stack deploy` so you
   never touch a YAML file directly.

The stack it deploys includes:

- **`docker-proxy`** —
  [tecnativa/docker-socket-proxy](https://github.com/Tecnativa/docker-socket-proxy)
  mounted on the Docker socket, exposing only the Swarm API calls DEDA needs
  (least-privilege access). DEDA never gets direct socket access.
- **`deda`** — the autoscaler container, pointed at the proxy, configured
  entirely via environment variables, with RabbitMQ credentials injected via
  Docker Swarm secrets.

---

## Installation

### Prerequisites

- Docker with Swarm mode active (`docker swarm init` or connected to a manager
  context)
- Existing Docker Swarm secrets for RabbitMQ credentials (see below)

### Install the plugin binary

Download a release archive for `linux-x64`, `linux-arm64`, or `win-x64`, extract
it, and place the binary in the Docker CLI plugins directory:

Pre-built archives are attached to versioned GitHub releases. If the repository
does not yet have a versioned release, use the source-build instructions below.

```bash
# Linux
mkdir -p ~/.docker/cli-plugins
cp Docker.Deda.Cli ~/.docker/cli-plugins/docker-deda
chmod +x ~/.docker/cli-plugins/docker-deda

# Windows (PowerShell)
$dir = "$env:USERPROFILE\.docker\cli-plugins"
New-Item -ItemType Directory -Force $dir
Copy-Item Docker.Deda.Cli.exe "$dir\docker-deda.exe"
```

Verify the plugin is recognized:

```bash
docker deda --help
```

### Or build from source

```bash
dotnet publish src/tools/Docker.Deda.Cli/Docker.Deda.Cli.csproj \
  -c Release -r linux-x64 \
  /p:PublishAot=true /p:SelfContained=true \
  -o ./publish/cli
```

The output binary is `publish/cli/Docker.Deda.Cli` — rename it to `docker-deda`
and copy it to the plugins directory as above.

---

## Create RabbitMQ secrets

DEDA reads RabbitMQ credentials from Docker Swarm secrets. Create them before
running `install`:

```bash
echo -n "your-rabbitmq-username" | docker secret create rabbitmq_user -
echo -n "your-rabbitmq-password" | docker secret create rabbitmq_pass -
```

If you use different secret names, pass `--rabbitmq-user-secret-name` and
`--rabbitmq-pass-secret-name` to `install`.

The generated stack mounts this global credential pair. DEDA also supports
per-service `trigger.credentialsSecret` values containing `username:password`,
but the current CLI does not add arbitrary per-service secrets to its generated
stack. Extend the rendered deployment or use a repository example when you need
multiple credential sets. See the [RabbitMQ guide](../../../docs/triggers/rabbitmq.md).

---

## Commands

### `install`

Deploys the DEDA stack on the Swarm.

```bash
docker deda install [options]
```

| Flag                              | Default         | Description                                                      |
| --------------------------------- | --------------- | ---------------------------------------------------------------- |
| `--image <img>`                   | `deda:local`    | DEDA container image to deploy                                   |
| `--stack <name>`                  | `deda`          | Docker stack name                                                |
| `--port <n>`                      | `8080`          | Published port for `/metrics` and `/health/*`                    |
| `--poll <sec>`                    | `10`            | Global reconcile interval (`DEDA_POLL_SECONDS`)                  |
| `--max-per-cycle <n>`             | `25`            | Max services processed per cycle (`DEDA_MAX_SERVICES_PER_CYCLE`) |
| `--jitter <bool>`                 | `true`          | Stable-hash service ordering (`DEDA_JITTER_ENABLED`)             |
| `--rabbitmq-user-secret-name <s>` | `rabbitmq_user` | Name of the Swarm secret holding the RabbitMQ username           |
| `--rabbitmq-pass-secret-name <s>` | `rabbitmq_pass` | Name of the Swarm secret holding the RabbitMQ password           |

**Example:**

```bash
docker deda install \
  --image ghcr.io/mikara89/deda:VERSION \
  --stack deda \
  --port 8080 \
  --poll 15
```

---

### `upgrade`

Redeploys the stack with a new image. Accepts the same flags as `install`;
unspecified flags keep their defaults.

```bash
docker deda upgrade --image ghcr.io/mikara89/deda:VERSION [--stack deda]
```

---

### `status`

Shows running services, task state, and the last 50 log lines from the DEDA
container.

```bash
docker deda status [--stack deda]
```

---

### `validate`

Runs basic sanity checks against a deployed stack:

- The `<stack>_deda` service exists.
- The service has a `node.role == manager` placement constraint.

```bash
docker deda validate [--stack deda]
```

---

### `uninstall`

Removes the entire DEDA stack.

```bash
docker deda uninstall [--stack deda]
```

> This removes all services in the stack but **does not** remove the Swarm
> secrets or any volumes.

---

## Architecture of the deployed stack

```
Swarm manager node
├── docker-proxy  (tecnativa/docker-socket-proxy)
│     └── mounts /var/run/docker.sock (read+write, restricted to Swarm API calls)
└── deda          (DEDA autoscaler)
      ├── connects to docker-proxy:2375 (never touches the socket directly)
      ├── reads RabbitMQ credentials from /run/secrets/*
      └── exposes :8080  →  /metrics  /health/live  /health/ready
```

The proxy narrows the exposed endpoint families and prevents DEDA from mounting
the socket directly. Because service scaling requires `POST`, the proxy is not
read-only and remains a privileged control-plane component. Keep its network
private and review the [production guidance](../../../docs/production.md#docker-api-access).
