#!/usr/bin/env bash
set -Eeuo pipefail

log() {
  local level="$1"
  shift
  printf '%s [%s] %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$level" "$*" >&2
}

info() { log INFO "$@"; }
warn() { log WARN "$@"; }
error() { log ERROR "$@"; }
fatal() { error "$@"; exit 1; }

trap 'error "Entrypoint failed at line ${LINENO} while running: ${BASH_COMMAND}"' ERR

require_command() {
  command -v "$1" >/dev/null 2>&1 || fatal "Required command not found: $1"
}

require_env() {
  local name="$1"
  [[ -n "${!name:-}" ]] || fatal "Required environment variable is not set: ${name}"
}

is_true() {
  case "${1:-0}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

trim() {
  local value="${1:-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

run_as_frappe() {
  runuser -u "${FRAPPE_USER}" -- \
    env \
      HOME="${FRAPPE_HOME}" \
      USER="${FRAPPE_USER}" \
      LOGNAME="${FRAPPE_USER}" \
      NVM_DIR="${NVM_DIR:-/usr/local/nvm}" \
      FRAPPE_HOME="${FRAPPE_HOME}" \
      BENCH_DIR="${BENCH_DIR}" \
      BENCH_CMD="${BENCH_CMD}" \
      FRAPPE_BRANCH="${FRAPPE_BRANCH:-version-15}" \
      SITE_NAME="${SITE_NAME:-}" \
      SITE_ADMIN_PASSWORD="${SITE_ADMIN_PASSWORD:-}" \
      DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-}" \
      DB_HOST="${DB_HOST:-}" \
      DB_PORT="${DB_PORT:-}" \
      REDIS_URL="${REDIS_URL:-}" \
      DEVELOPER_MODE="${DEVELOPER_MODE:-1}" \
      DNS_MULTITENANT="${DNS_MULTITENANT:-0}" \
      CODE_SERVER_BIN="${CODE_SERVER_BIN}" \
      "$@"
}

wait_for_mariadb() {
  local timeout="${MARIADB_START_TIMEOUT:-60}"
  local elapsed=0
  until mysqladmin ping -h "${DB_HOST}" -P "${DB_PORT}" --protocol=tcp -u root "-p${DB_ROOT_PASSWORD}" --silent >/dev/null 2>&1; do
    sleep 2
    elapsed=$((elapsed + 2))
    if (( elapsed >= timeout )); then
      fatal "MariaDB did not become ready within ${timeout}s"
    fi
  done
}

wait_for_local_mariadb_socket() {
  local timeout="${MARIADB_START_TIMEOUT:-60}"
  local elapsed=0
  until mysqladmin --socket=/run/mysqld/mysqld.sock ping --silent >/dev/null 2>&1; do
    sleep 2
    elapsed=$((elapsed + 2))
    if (( elapsed >= timeout )); then
      if [[ -f /tmp/mariadb.log ]]; then
        error "MariaDB startup log:"
        sed 's/^/[mariadb] /' /tmp/mariadb.log >&2 || true
      fi
      fatal "Local MariaDB did not become ready within ${timeout}s"
    fi
  done
}

wait_for_redis() {
  local url="$1"
  local timeout=30
  local elapsed=0
  until redis-cli -u "$url" ping >/dev/null 2>&1; do
    sleep 1
    elapsed=$((elapsed + 1))
    if (( elapsed >= timeout )); then
      fatal "Redis did not become ready within ${timeout}s for ${url}"
    fi
  done
}

ensure_core_directories() {
  mkdir -p \
    "${FRAPPE_HOME}" \
    "${BENCH_DIR%/*}" \
    /workspace \
    /run/mysqld \
    /var/lib/mysql \
    /var/lib/redis \
    "${FRAPPE_HOME}/.local/share/code-server/extensions" \
    "${FRAPPE_HOME}/.config/code-server"

  chown -R "${FRAPPE_USER}:${FRAPPE_USER}" /workspace "${FRAPPE_HOME}" "${BENCH_DIR%/*}"
  chown -R mysql:mysql /run/mysqld /var/lib/mysql
  chown -R redis:redis /var/lib/redis
}

validate_environment() {
  require_command "${BENCH_CMD}"
  require_command mysql
  require_command redis-cli
  require_command "${CODE_SERVER_BIN}"

  require_env FRAPPE_USER
  require_env FRAPPE_HOME
  require_env BENCH_DIR
  require_env BENCH_CMD

  id -u "${FRAPPE_USER}" >/dev/null 2>&1 || fatal "User ${FRAPPE_USER} does not exist in the image"

  if is_true "${CREATE_SITE_ON_FIRST_RUN:-1}"; then
    require_env SITE_NAME
    require_env SITE_ADMIN_PASSWORD
    require_env DB_ROOT_PASSWORD
  fi

  if is_true "${ENABLE_LOCAL_MARIADB:-1}"; then
    require_env DB_ROOT_PASSWORD
    : "${DB_HOST:=127.0.0.1}"
    : "${DB_PORT:=3306}"
    if [[ "${DB_HOST}" != "127.0.0.1" && "${DB_HOST}" != "localhost" ]]; then
      fatal "DB_HOST must resolve to the local container when ENABLE_LOCAL_MARIADB=1"
    fi
  else
    require_env DB_HOST
    : "${DB_PORT:=3306}"
  fi

  if is_true "${ENABLE_LOCAL_REDIS:-1}"; then
    : "${REDIS_URL:=redis://127.0.0.1:6379}"
    if [[ ! "${REDIS_URL}" =~ ^redis://(127\.0\.0\.1|localhost):6379(/.*)?$ ]]; then
      fatal "REDIS_URL must point at the local Redis service when ENABLE_LOCAL_REDIS=1"
    fi
  elif [[ -z "${REDIS_URL:-}" ]]; then
    fatal "REDIS_URL must be set when ENABLE_LOCAL_REDIS=0"
  fi
}

initialize_local_mariadb_datadir() {
  if [[ -d /var/lib/mysql/mysql ]]; then
    return 0
  fi

  info "Initializing MariaDB data directory"
  mariadb-install-db --user=mysql --datadir=/var/lib/mysql >/dev/null

  mariadbd \
    --user=mysql \
    --datadir=/var/lib/mysql \
    --socket=/run/mysqld/mysqld-init.sock \
    --pid-file=/run/mysqld/mysqld-init.pid \
    --skip-networking \
    >/tmp/mariadb-init.log 2>&1 &
  local bootstrap_pid=$!

  local waited=0
  until mysqladmin --socket=/run/mysqld/mysqld-init.sock ping --silent >/dev/null 2>&1; do
    sleep 1
    waited=$((waited + 1))
    if (( waited >= 30 )); then
      kill "${bootstrap_pid}" >/dev/null 2>&1 || true
      fatal "MariaDB bootstrap server did not become ready"
    fi
  done

  mysql --socket=/run/mysqld/mysqld-init.sock <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD}';
CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED BY '${DB_ROOT_PASSWORD}';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION;
CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '${DB_ROOT_PASSWORD}';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL

  mysqladmin --socket=/run/mysqld/mysqld-init.sock -u root "-p${DB_ROOT_PASSWORD}" shutdown
  wait "${bootstrap_pid}" || true
}

ensure_local_mariadb_root_access() {
  mysql --socket=/run/mysqld/mysqld.sock -u root "-p${DB_ROOT_PASSWORD}" <<SQL
CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED BY '${DB_ROOT_PASSWORD}';
ALTER USER 'root'@'127.0.0.1' IDENTIFIED BY '${DB_ROOT_PASSWORD}';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION;
CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '${DB_ROOT_PASSWORD}';
ALTER USER 'root'@'%' IDENTIFIED BY '${DB_ROOT_PASSWORD}';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
}

start_local_mariadb() {
  if ! is_true "${ENABLE_LOCAL_MARIADB:-1}"; then
    info "Skipping local MariaDB startup because ENABLE_LOCAL_MARIADB=${ENABLE_LOCAL_MARIADB:-0}"
    return 0
  fi

  initialize_local_mariadb_datadir

  if mysqladmin --socket=/run/mysqld/mysqld.sock ping --silent >/dev/null 2>&1; then
    info "Local MariaDB already accepting connections"
    ensure_local_mariadb_root_access
    return 0
  fi

  info "Starting local MariaDB"
  mariadbd-safe \
    --user=mysql \
    --datadir=/var/lib/mysql \
    --bind-address=0.0.0.0 \
    --port="${DB_PORT}" \
    --skip-name-resolve \
    >/tmp/mariadb.log 2>&1 &

  wait_for_local_mariadb_socket
  ensure_local_mariadb_root_access
  wait_for_mariadb
}

start_local_redis() {
  if ! is_true "${ENABLE_LOCAL_REDIS:-1}"; then
    info "Skipping local Redis startup because ENABLE_LOCAL_REDIS=${ENABLE_LOCAL_REDIS:-0}"
    return 0
  fi

  if redis-cli -u "${REDIS_URL}" ping >/dev/null 2>&1; then
    info "Local Redis already accepting connections"
    return 0
  fi

  info "Starting local Redis"
  redis-server \
    --bind 0.0.0.0 \
    --port 6379 \
    --dir /var/lib/redis \
    --appendonly yes \
    --daemonize yes \
    --protected-mode no

  wait_for_redis "${REDIS_URL}"
}

ensure_bench() {
  if [[ -f "${BENCH_DIR}/Procfile" ]]; then
    info "Using existing bench at ${BENCH_DIR}"
    return 0
  fi

  info "Initializing bench at ${BENCH_DIR}"
  mkdir -p "${BENCH_DIR%/*}"
  chown -R "${FRAPPE_USER}:${FRAPPE_USER}" "${BENCH_DIR%/*}"
  run_as_frappe bash -lc '
    [[ -s "${NVM_DIR}/nvm.sh" ]] && source "${NVM_DIR}/nvm.sh"
    mkdir -p "${BENCH_DIR%/*}"
    exec "${BENCH_CMD}" init --skip-redis-config-generation --frappe-branch "${FRAPPE_BRANCH:-version-15}" "${BENCH_DIR}"
  '
}

configure_common_site() {
  info "Configuring bench-wide settings"
  run_as_frappe bash -lc 'cd "${BENCH_DIR}" && "${BENCH_CMD}" set-config -g developer_mode "${DEVELOPER_MODE:-1}"'
  run_as_frappe bash -lc 'cd "${BENCH_DIR}" && "${BENCH_CMD}" set-config -g dns_multitenant "${DNS_MULTITENANT:-0}"'
  run_as_frappe bash -lc 'cd "${BENCH_DIR}" && "${BENCH_CMD}" set-config -g db_host "${DB_HOST}"'
  run_as_frappe bash -lc 'cd "${BENCH_DIR}" && "${BENCH_CMD}" set-config -g db_port "${DB_PORT}"'
  run_as_frappe bash -lc 'cd "${BENCH_DIR}" && "${BENCH_CMD}" set-config -g redis_cache "${REDIS_URL}"'
  run_as_frappe bash -lc 'cd "${BENCH_DIR}" && "${BENCH_CMD}" set-config -g redis_queue "${REDIS_URL}"'
  run_as_frappe bash -lc 'cd "${BENCH_DIR}" && "${BENCH_CMD}" set-config -g redis_socketio "${REDIS_URL}"'
  run_as_frappe bash -lc 'cd "${BENCH_DIR}" && "${BENCH_CMD}" set-config -g webserver_port "8000"'
  run_as_frappe bash -lc 'cd "${BENCH_DIR}" && "${BENCH_CMD}" set-config -g socketio_port "9000"'
}

patch_procfile_once() {
  local procfile="${BENCH_DIR}/Procfile"
  local marker="${BENCH_DIR}/.devbox-procfile-patched"

  if ! is_true "${PATCH_PROCFILE_FOR_DEV_SERVER:-1}"; then
    info "Skipping Procfile patch because PATCH_PROCFILE_FOR_DEV_SERVER=${PATCH_PROCFILE_FOR_DEV_SERVER:-0}"
    return 0
  fi

  [[ -f "${procfile}" ]] || fatal "Procfile not found at ${procfile}"

  if [[ -f "${marker}" ]]; then
    info "Procfile patch already recorded"
    return 0
  fi

  info "Patching Procfile for container-friendly bench start"
  if ! grep -q "bench serve --port 8000" "${procfile}"; then
    sed -i \
      -e "s|^web: .*|web: bench serve --port 8000|" \
      -e "s|^socketio: .*|socketio: /usr/bin/env node apps/frappe/socketio.js|" \
      "${procfile}"
  fi

  touch "${marker}"
  chown "${FRAPPE_USER}:${FRAPPE_USER}" "${marker}"
}

site_exists() {
  [[ -d "${BENCH_DIR}/sites/${SITE_NAME}" ]]
}

create_site_if_needed() {
  if ! is_true "${CREATE_SITE_ON_FIRST_RUN:-1}"; then
    info "Skipping site creation because CREATE_SITE_ON_FIRST_RUN=${CREATE_SITE_ON_FIRST_RUN:-0}"
    return 0
  fi

  if site_exists; then
    info "Site ${SITE_NAME} already exists"
    run_as_frappe bash -lc 'cd "${BENCH_DIR}" && "${BENCH_CMD}" use "${SITE_NAME}"'
    return 0
  fi

  info "Creating site ${SITE_NAME}"
  run_as_frappe bash -lc '
    cd "${BENCH_DIR}"
    exec "${BENCH_CMD}" new-site "${SITE_NAME}" \
      --admin-password "${SITE_ADMIN_PASSWORD}" \
      --db-root-password "${DB_ROOT_PASSWORD}" \
      --db-host "${DB_HOST}" \
      --db-port "${DB_PORT}" \
      --set-default
  '

  local apps_raw="${DEVBOX_INSTALL_APPS:-}"
  if [[ -n "$(trim "${apps_raw}")" ]]; then
    IFS=',' read -r -a apps <<<"${apps_raw}"
    for app in "${apps[@]}"; do
      app="$(trim "${app}")"
      [[ -n "${app}" ]] || continue
      info "Installing app ${app} on ${SITE_NAME}"
      run_as_frappe env APP_TO_INSTALL="${app}" bash -lc 'cd "${BENCH_DIR}" && "${BENCH_CMD}" --site "${SITE_NAME}" install-app "${APP_TO_INSTALL}"'
    done
  fi
}

install_vscode_extensions() {
  if ! is_true "${INSTALL_VSCODE_EXTENSIONS:-1}"; then
    info "Skipping code-server extension installation because INSTALL_VSCODE_EXTENSIONS=${INSTALL_VSCODE_EXTENSIONS:-0}"
    return 0
  fi

  local spec_file="${FRAPPE_HOME}/.local/share/code-server/.devbox-extension-spec"
  local desired
  desired="$(printf 'ext=%s\nvsix=%s\n' "${VSCODE_EXTENSIONS:-}" "${LOCAL_VSIX_PATH:-}")"

  if [[ -f "${spec_file}" ]] && [[ "$(cat "${spec_file}")" == "${desired}" ]]; then
    info "Requested code-server extensions already installed"
    return 0
  fi

  local extensions_raw="${VSCODE_EXTENSIONS:-}"
  if [[ -n "$(trim "${extensions_raw}")" ]]; then
    IFS=',' read -r -a extensions <<<"${extensions_raw}"
    for extension in "${extensions[@]}"; do
      extension="$(trim "${extension}")"
      [[ -n "${extension}" ]] || continue
      info "Installing code-server extension ${extension}"
      run_as_frappe env EXTENSION_ID="${extension}" bash -lc 'exec "${CODE_SERVER_BIN}" --install-extension "${EXTENSION_ID}"'
    done
  fi

  local vsix_raw="${LOCAL_VSIX_PATH:-}"
  if [[ -n "$(trim "${vsix_raw}")" ]]; then
    IFS=',' read -r -a vsix_paths <<<"${vsix_raw}"
    for vsix in "${vsix_paths[@]}"; do
      vsix="$(trim "${vsix}")"
      [[ -n "${vsix}" ]] || continue
      [[ -f "${vsix}" ]] || fatal "VSIX file not found: ${vsix}"
      info "Installing code-server VSIX ${vsix}"
      run_as_frappe env VSIX_PATH="${vsix}" bash -lc 'exec "${CODE_SERVER_BIN}" --install-extension "${VSIX_PATH}"'
    done
  fi

  printf '%s' "${desired}" >"${spec_file}"
  chown "${FRAPPE_USER}:${FRAPPE_USER}" "${spec_file}"
}

maybe_add_site_to_hosts() {
  if ! is_true "${ADD_SITE_TO_ETC_HOSTS:-0}"; then
    return 0
  fi

  if grep -Eq "(^|[[:space:]])${SITE_NAME}([[:space:]]|$)" /etc/hosts; then
    info "Site ${SITE_NAME} already present in /etc/hosts"
    return 0
  fi

  info "Adding ${SITE_NAME} to /etc/hosts"
  printf '127.0.0.1 %s\n' "${SITE_NAME}" >>/etc/hosts
}

main() {
  export FRAPPE_USER="${FRAPPE_USER:-frappe}"
  export FRAPPE_HOME="${FRAPPE_HOME:-/home/frappe}"
  export BENCH_DIR="${BENCH_DIR:-/workspace/frappe-bench}"
  export BENCH_CMD="${BENCH_CMD:-bench}"
  export CODE_SERVER_BIN="${CODE_SERVER_BIN:-/usr/bin/code-server}"

  ensure_core_directories
  validate_environment
  start_local_mariadb
  start_local_redis
  ensure_bench
  configure_common_site
  patch_procfile_once
  create_site_if_needed
  install_vscode_extensions
  maybe_add_site_to_hosts

  info "Bootstrap complete; starting: $*"
  exec "$@"
}

main "$@"
