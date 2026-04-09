# Frappe v15 Devbox

A browser-accessible developer workspace for Frappe v15 that helps you get a working bench up quickly with code-server, Supervisor, and optional local MariaDB and Redis.

This image is designed for single-tenant developer use, not as a shared SaaS runtime or production multi-container Frappe deployment.

## What's included

- Frappe Bench
- code-server
- Supervisor
- Optional local MariaDB
- Optional local Redis
- Idempotent first-run bootstrap entrypoint

## What this image is for

This image is meant to give a developer a fast way to:

- boot a Frappe v15 bench in Docker
- open the bench in browser-based VS Code
- create a site on first run
- keep bench, database, Redis, and editor data persisted through Docker volumes
- switch between local MariaDB/Redis and external services with environment variables

## What this image is not

This is not a full production Frappe topology with separate web, queue, scheduler, websocket, database, and cache services managed independently.

It is a workspace bootstrap container for development and isolated dev environments.

## Build

```bash
docker build -t frappe-workspace-box .
```

## Quick start

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
  frappe-workspace-box
```

After startup:

- Frappe: `http://localhost:8000`
- code-server: `http://localhost:8080`

code-server opens the bench directory by default.

## Test and verify

Use this flow to validate that the container builds, boots correctly, and stays idempotent across restarts.

1. Build the image:

```bash
cd /Users/praveen/Documents/localbox
docker build -t frappe-workspace-box .
```

2. Start the container with local MariaDB and Redis enabled:

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
  frappe-workspace-box
```

3. Watch the logs and confirm the bootstrap finishes without errors. A healthy first boot should initialize services, create the bench when missing, create the site if requested, and then start Supervisor-managed processes.

4. Open the services locally:

- Frappe web: `http://localhost:8000`
- code-server: `http://localhost:8080`

5. Stop the container and run the same command again with the same named volumes. Confirm that:

- the bench is reused
- the site is not recreated
- the Procfile is not patched again
- code-server extensions are not reinstalled unless the requested extension list changes

6. To test external service mode, rerun with:

- `ENABLE_LOCAL_MARIADB=0`
- `DB_HOST` and `DB_PORT` set to your external MariaDB instance
- `ENABLE_LOCAL_REDIS=0`
- `REDIS_URL` set to your external Redis instance

## External DB and Redis mode

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
  frappe-workspace-box
```

## Important environment variables

- `SITE_NAME`: Site to create and use on first boot when `CREATE_SITE_ON_FIRST_RUN=1`
- `SITE_ADMIN_PASSWORD`: Required when creating a site
- `DB_ROOT_PASSWORD`: Required for site creation and used to initialize the local MariaDB root account
- `ENABLE_LOCAL_MARIADB`: Set to `1` to start MariaDB inside the container, or `0` to use an external DB
- `DB_HOST`: Required when `ENABLE_LOCAL_MARIADB=0`, defaults to `127.0.0.1` for local MariaDB
- `DB_PORT`: MariaDB port, defaults to `3306`
- `ENABLE_LOCAL_REDIS`: Set to `1` to start Redis inside the container, or `0` to use external Redis
- `REDIS_URL`: Required when `ENABLE_LOCAL_REDIS=0`, defaults to `redis://127.0.0.1:6379` for local Redis
- `DEVBOX_INSTALL_APPS`: Comma-separated list of apps to install after first-run site creation
- `DEVELOPER_MODE`: Bench-wide `developer_mode` value, defaults to `1`
- `DNS_MULTITENANT`: Bench-wide `dns_multitenant` value, defaults to `0`
- `CREATE_SITE_ON_FIRST_RUN`: When `1`, creates `SITE_NAME` if it does not already exist
- `PATCH_PROCFILE_FOR_DEV_SERVER`: When `1`, patches the bench `Procfile` once for container-friendly startup
- `INSTALL_VSCODE_EXTENSIONS`: When `1`, installs requested code-server extensions only when the requested extension set changes
- `VSCODE_EXTENSIONS`: Comma-separated extension IDs for code-server
- `LOCAL_VSIX_PATH`: Optional comma-separated list of local VSIX files to install
- `ADD_SITE_TO_ETC_HOSTS`: When `1`, appends `SITE_NAME` to `/etc/hosts` if it is not already present
- `FRAPPE_BRANCH`: Optional bench bootstrap branch when the bench directory is empty, defaults to `version-15`
- `BENCH_DIR`: Bench path, defaults to `/workspace/frappe-bench`
- `CODE_SERVER_AUTH`: If set, overrides code-server auth mode; by default code-server runs with auth disabled for isolated local workspace usage

## Suggested image tags

- `latest`
- `v15`
- `0.1.0`

## Notes

- Startup is intentionally strict and fails loudly on critical bootstrap errors.
- First boot is slower because bench initialization, asset build, and site creation happen then.
- Restart is much faster when the same Docker volumes are reused.
- This image uses `bench start`, so it is appropriate for development workflows, not hardened production traffic.
# local-frappe-dev-box
