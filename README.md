# Frappe v15 Devbox

`neuron27/frappe-v15-devbox` is a browser-accessible Frappe v15 developer workspace image. It gives you a ready-to-run bench with code-server, Supervisor, and optional local MariaDB and Redis so you can start building quickly with Docker or on Kubernetes.

This image is meant for a single developer or staging workspace, not a full production Frappe cluster.

## What you get

- Frappe Bench (v15)
- code-server in the browser, password-protected by default
- Supervisor managing MariaDB, Redis, code-server and `bench start`
- Optional local MariaDB and Redis, bound to loopback only
- First-run bootstrap for bench and site creation
- Runs as an unprivileged user (uid 1000), compatible with Kubernetes Pod Security `restricted`

## Quick start

```bash
docker run --rm -it \
  -p 8000:8000 \
  -p 9000:9000 \
  -p 8080:8080 \
  -e SITE_NAME=dev.localhost \
  -e SITE_ADMIN_PASSWORD='change-me-now' \
  -e DB_ROOT_PASSWORD='change-me-now' \
  -e PASSWORD='code-server-password' \
  -v frappe-data:/data \
  neuron27/frappe-v15-devbox:latest
```

After startup:

- Frappe: `http://localhost:8000`
- code-server: `http://localhost:8080` (log in with `PASSWORD`)

Everything that persists (bench, MariaDB, Redis, code-server settings and extensions) lives in the single `/data` volume.

## First boot behavior

On the first run the container:

- initializes the MariaDB data directory and sets the root password
- creates a Frappe bench (git clone, Python env, yarn install, asset build)
- creates the site defined by `SITE_NAME` and installs `DEVBOX_INSTALL_APPS`
- installs the requested code-server extensions

This takes 15–30 minutes. Later starts reuse the volume and take seconds.

If the first `bench init` fails (for example a network error), the container exits with a clear error and removes the half-built bench on the next start, so a restart retries from a clean state.

## Required environment variables

- `SITE_NAME`
- `SITE_ADMIN_PASSWORD`
- `DB_ROOT_PASSWORD`
- `PASSWORD` (or `HASHED_PASSWORD`) for code-server, unless `ENABLE_CODE_SERVER=0` or `CODE_SERVER_AUTH=none`

## Common environment variables

- `ENABLE_LOCAL_MARIADB`: `1` (default) for MariaDB inside the container, `0` for an external database
- `DB_HOST`, `DB_PORT`: required/used when `ENABLE_LOCAL_MARIADB=0`
- `ENABLE_LOCAL_REDIS`: `1` (default) for Redis inside the container, `0` for external Redis
- `REDIS_URL`: required when `ENABLE_LOCAL_REDIS=0`
- `ENABLE_CODE_SERVER`: `1` (default) to run code-server, `0` to disable it
- `CODE_SERVER_AUTH`: `password` (default) or `none`. `none` gives anyone who can reach port 8080 a shell; only use it behind a private port-forward
- `CREATE_SITE_ON_FIRST_RUN`: `1` to create the site if it does not exist
- `DEVBOX_INSTALL_APPS`: comma-separated apps to install after site creation
- `VSCODE_EXTENSIONS`: comma-separated code-server extension IDs
- `INSTALL_VSCODE_EXTENSIONS`: `1` to install extensions when the requested set changes
- `DEVELOPER_MODE`: bench-wide developer mode, default `1`
- `DNS_MULTITENANT`: bench-wide dns_multitenant flag, default `0`

## Security model

- The container runs as uid/gid 1000. It refuses to start as root, never changes file ownership, and needs no Linux capabilities.
- MariaDB and Redis listen on `127.0.0.1` only. Redis runs with protected mode on.
- MariaDB keeps exactly two root accounts, `root@localhost` and `root@127.0.0.1`, both password-protected. Any other root account (including `root@'%'` from earlier versions of this image) is removed on start.
- The MariaDB root password is passed to clients through a `0600` option file, not on the command line, and is escaped before use in SQL.
- MariaDB and Redis are run by Supervisor, so stopping the container shuts them down cleanly.
- code-server requires a password by default.

## External DB and Redis example

```bash
docker run --rm -it \
  -p 8000:8000 -p 9000:9000 -p 8080:8080 \
  -e SITE_NAME=dev.example.internal \
  -e SITE_ADMIN_PASSWORD='change-me-now' \
  -e DB_ROOT_PASSWORD='mysql-root-password' \
  -e ENABLE_LOCAL_MARIADB=0 \
  -e DB_HOST=mysql.example.internal \
  -e DB_PORT=3306 \
  -e ENABLE_LOCAL_REDIS=0 \
  -e REDIS_URL='redis://redis.example.internal:6379' \
  -e PASSWORD='code-server-password' \
  -v frappe-data:/data \
  neuron27/frappe-v15-devbox:latest
```

## Kubernetes (k3s)

Two manifests, identical except for storage. Apply one of them, not both:

| File | Storage | Use when |
|------|---------|----------|
| `k8s/frappe-devbox.yaml` | `local-path` | Single node, or you don't mind the pod being pinned to the node that holds its data |
| `k8s/frappe-devbox-longhorn.yaml` | Longhorn (`longhorn-devbox` StorageClass, 2 replicas, `dataLocality: best-effort`, `Retain`) | The pod should be able to move between nodes and survive a node loss |

Both run under Pod Security `restricted` with a read-only root filesystem, a NetworkPolicy that only admits Traefik, and an Ingress that routes `/socket.io` to port 9000.

```bash
# edit the image tag, Secret values and Ingress host first
kubectl apply -f k8s/frappe-devbox-longhorn.yaml      # or k8s/frappe-devbox.yaml
kubectl -n frappe-staging logs -f deploy/frappe-devbox
kubectl -n frappe-staging port-forward deploy/frappe-devbox 8080:8080   # code-server
```

Resources: requests `250m` CPU / `1Gi` memory (enough for an idle devbox, so it schedules on a busy node), limits `2` CPU / `4Gi` memory. The first boot bursts to the limits during `yarn install` and the asset build; with the 2-CPU cap it can take up to an hour, and the startup probe allows for that. Because requests are below limits, the pod is in the Burstable QoS class and is evicted before Guaranteed pods if a node runs out of memory.

With Longhorn, `fsGroupChangePolicy: OnRootMismatch` matters: without it the kubelet re-chowns every file in the bench on each mount, which stalls every restart once `node_modules` exists.

code-server is deliberately not exposed through the Service or Ingress.

## Build

Multi-arch (Apple Silicon and amd64 servers):

```bash
docker buildx build --platform linux/amd64,linux/arm64 \
  -t neuron27/frappe-v15-devbox:0.2.0 -t neuron27/frappe-v15-devbox:latest \
  --push .
```

Build arguments:

- `INSTALL_CODE_SERVER=0` builds without code-server
- `CODE_SERVER_VERSION=4.x.y` pins code-server (default: latest)

## Upgrading from 0.1.x

0.1.x ran as root and used four volumes (`/workspace`, `/var/lib/mysql`, `/var/lib/redis`, code-server data). 0.2.0 runs as uid 1000 with one `/data` volume. To keep existing data, copy the old volumes into the new layout and hand them to uid 1000:

```bash
docker run --rm \
  -v frappe-workspace:/old/workspace -v frappe-mariadb:/old/mysql \
  -v frappe-redis:/old/redis -v frappe-code-server:/old/code-server \
  -v frappe-data:/data ubuntu:24.04 bash -c '
    mkdir -p /data/workspace /data/mysql /data/redis /data/code-server/user-data /data/code-server/extensions &&
    cp -a /old/workspace/. /data/workspace/ &&
    cp -a /old/mysql/. /data/mysql/ &&
    cp -a /old/redis/. /data/redis/ &&
    cp -a /old/code-server/. /data/code-server/user-data/ &&
    chown -R 1000:1000 /data'
```

The new container also removes the old `root@'%'` MariaDB account on its first start.

## Verify it is working

1. Watch the logs and confirm `Bootstrap complete` appears.
2. Open `http://localhost:8000` and confirm the Frappe site responds.
3. Open `http://localhost:8080`, log in with `PASSWORD`, and confirm code-server loads.
4. Restart the container with the same volume and confirm the bench and site are reused.

## Notes

- This image is for development, learning and staging workflows.
- It is not a multi-service production deployment of Frappe.
- The image is published at [Docker Hub](https://hub.docker.com/r/neuron27/frappe-v15-devbox).
