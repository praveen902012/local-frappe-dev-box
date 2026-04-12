# Frappe v15 Devbox

`neuron27/frappe-v15-devbox` is a browser-accessible Frappe v15 developer workspace image. It gives you a ready-to-run bench with code-server, Supervisor, and optional local MariaDB and Redis so you can start building quickly with Docker.

This image is meant for a single developer workspace, not a full production Frappe cluster.

## What you get

- Frappe Bench
- code-server in the browser
- Supervisor-managed processes
- Optional local MariaDB
- Optional local Redis
- First-run bootstrap for bench and site creation

## Quick start

Pull the image:

```bash
docker pull neuron27/frappe-v15-devbox:latest
```

Run it with local MariaDB and Redis:

```bash
docker run --rm -it \
  -p 8000:8000 \
  -p 8080:8080 \
  -e SITE_NAME=dev.localhost \
  -e SITE_ADMIN_PASSWORD='change-me-now' \
  -e DB_ROOT_PASSWORD='change-me-now' \
  -e CREATE_SITE_ON_FIRST_RUN=1 \
  -e ENABLE_LOCAL_MARIADB=1 \
  -e ENABLE_LOCAL_REDIS=1 \
  -v frappe-workspace:/workspace \
  -v frappe-mariadb:/var/lib/mysql \
  -v frappe-redis:/var/lib/redis \
  -v frappe-code-server:/home/frappe/.local/share/code-server \
  neuron27/frappe-v15-devbox:latest
```

After startup:

- Frappe will be available at `http://localhost:8000`
- code-server will be available at `http://localhost:8080`
- code-server opens the bench directory by default

## First boot behavior

On the first run, the container can:

- initialize the local MariaDB data directory
- start local Redis if enabled
- create a new Frappe bench if one does not exist
- create the site defined by `SITE_NAME`
- install requested code-server extensions

When you reuse the same Docker volumes, the container is designed to be idempotent and should not recreate the bench, site, or extensions unnecessarily.

## Required environment variables

For the standard local setup, set these:

- `SITE_NAME`
- `SITE_ADMIN_PASSWORD`
- `DB_ROOT_PASSWORD`

## Common environment variables

- `ENABLE_LOCAL_MARIADB`: `1` to use MariaDB inside the container, `0` to use an external database
- `DB_HOST`: required when `ENABLE_LOCAL_MARIADB=0`
- `DB_PORT`: MariaDB port, default `3306`
- `ENABLE_LOCAL_REDIS`: `1` to use Redis inside the container, `0` to use an external Redis
- `REDIS_URL`: required when `ENABLE_LOCAL_REDIS=0`
- `CREATE_SITE_ON_FIRST_RUN`: `1` to create the site automatically if it does not exist
- `DEVBOX_INSTALL_APPS`: comma-separated apps to install after site creation
- `VSCODE_EXTENSIONS`: comma-separated code-server extension IDs
- `INSTALL_VSCODE_EXTENSIONS`: `1` to install extensions only when the requested set changes
- `BENCH_DIR`: bench path, default `/workspace/frappe-bench`
- `DEVELOPER_MODE`: bench-wide developer mode, default `1`
- `DNS_MULTITENANT`: bench-wide dns_multitenant flag, default `0`

## External DB and Redis example

```bash
docker run --rm -it \
  -p 8000:8000 \
  -p 8080:8080 \
  -e SITE_NAME=dev.example.internal \
  -e SITE_ADMIN_PASSWORD='change-me-now' \
  -e DB_ROOT_PASSWORD='mysql-root-password' \
  -e ENABLE_LOCAL_MARIADB=0 \
  -e DB_HOST=mysql.example.internal \
  -e DB_PORT=3306 \
  -e ENABLE_LOCAL_REDIS=0 \
  -e REDIS_URL='redis://redis.example.internal:6379' \
  -v frappe-workspace:/workspace \
  -v frappe-code-server:/home/frappe/.local/share/code-server \
  neuron27/frappe-v15-devbox:latest
```

## Verify it is working

Use this quick check after startup:

1. Watch the container logs and confirm bootstrap completes without errors.
2. Open `http://localhost:8080` and confirm code-server loads.
3. Open `http://localhost:8000` and confirm the Frappe site responds.
4. Stop the container and run the same command again with the same volumes.
5. Confirm the restart is faster and the existing bench and site are reused.

## Available tags

- `latest`
- `v15`
- `0.1.0`
- `amd64`

## Notes

- This image is for development and learning workflows.
- It is not a full multi-service production deployment model for Frappe.
- The first run can take a while because bench setup and asset build happen there.
- The image is published at [Docker Hub](https://hub.docker.com/r/neuron27/frappe-v15-devbox).
