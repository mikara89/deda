# docker-deda — Docker CLI Plugin

`docker deda` is a Docker CLI plugin that installs, manages, and validates the
DEDA autoscaler on a Docker Swarm cluster. Instead of writing and maintaining a
Compose/stack file by hand, a single command deploys the complete DEDA stack
with production-ready defaults.

---

## How it works

The plugin is a NativeAOT binary named `docker-deda` (or `docker-deda.exe` on
Windows) placed in the Docker CLI plugins directory. Docker then exposes it as
the `docker deda` sub-command.

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

Download the pre-built binary for your platform and place it in the Docker CLI
plugins directory:

```bash
# Linux / macOS
mkdir -p ~/.docker/cli-plugins
cp docker-deda ~/.docker/cli-plugins/docker-deda
chmod +x ~/.docker/cli-plugins/docker-deda

# Windows (PowerShell)
$dir = "$env:USERPROFILE\.docker\cli-plugins"
New-Item -ItemType Directory -Force $dir
Copy-Item docker-deda.exe "$dir\docker-deda.exe"
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

> **Known limitation — single credential set:** DEDA uses one RabbitMQ username
> and password for all services it scales. All RabbitMQ queues referenced by
> `com.deda.autoscale.trigger.type=rabbitmq` labels across your Swarm services
> must be accessible with the same credentials. Multiple RabbitMQ instances or
> per-service credentials are not yet supported.

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
  --image ghcr.io/mikara89/deda:0.3.0 \
  --stack deda \
  --port 8080 \
  --poll 15
```

---

### `upgrade`

Redeploys the stack with a new image. Accepts the same flags as `install`;
unspecified flags keep their defaults.

```bash
docker deda upgrade --image ghcr.io/mikara89/deda:0.4.0 [--stack deda]
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

Using `docker-socket-proxy` means the DEDA container cannot perform arbitrary
Docker operations — it can only list services, inspect tasks, and update replica
counts.
