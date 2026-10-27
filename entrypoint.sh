#!/usr/bin/env bash
# Frappe v15 devbox bootstrap. Runs as the unprivileged image user (uid 1000):
# no root, no chown, no user switching, so it works under Kubernetes
# Pod Security "restricted".
#
# Flow: prepare /data -> start MariaDB/Redis temporarily -> bench init /
# new-site if needed -> stop them cleanly -> exec supervisord, which owns
# every long-running process from then on.
set -Eeuo pipefail
umask 0027

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

TEMP_MARIADB_PID=""
TEMP_REDIS_PID=""

cleanup_temp_services() {
  stop_temp_services || true
}
trap cleanup_temp_services EXIT

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

require_command() {
  command -v "$1" >/dev/null 2>&1 || fatal "Required command not found: $1"
}

require_env() {
  local name="$1"
  [[ -n "${!name:-}" ]] || fatal "Required environment variable is not set: ${name}"
}

# Escape a value for use inside a single-quoted SQL string literal.
sql_escape() {
  local value="${1//\\/\\\\}"
  printf '%s' "${value//\'/\'\'}"
}

# --- setup -------------------------------------------------------------------

set_defaults() {
  export FRAPPE_USER="${FRAPPE_USER:-frappe}"
  export FRAPPE_HOME="${FRAPPE_HOME:-/home/frappe}"
  export HOME="${FRAPPE_HOME}"
  export DATA_DIR="${DATA_DIR:-/data}"
  export BENCH_DIR="${BENCH_DIR:-${DATA_DIR}/workspace/frappe-bench}"
  export MARIADB_DATA_DIR="${MARIADB_DATA_DIR:-${DATA_DIR}/mysql}"
  export REDIS_DATA_DIR="${REDIS_DATA_DIR:-${DATA_DIR}/redis}"
  export CODE_SERVER_DATA_DIR="${CODE_SERVER_DATA_DIR:-${DATA_DIR}/code-server}"
  export RUN_DIR="${RUN_DIR:-/tmp/devbox-run}"
  export BENCH_CMD="${BENCH_CMD:-bench}"
  export DB_PORT="${DB_PORT:-3306}"
  export CODE_SERVER_BIN="${CODE_SERVER_BIN:-/usr/bin/code-server}"
  export CODE_SERVER_AUTH="${CODE_SERVER_AUTH:-password}"
  export CODE_SERVER_BIND_ADDR="${CODE_SERVER_BIND_ADDR:-0.0.0.0:8080}"
  [[ -s "${NVM_DIR:-/usr/local/nvm}/nvm.sh" ]] && export PATH="${NVM_DIR:-/usr/local/nvm}/versions/node/v${NODE_VERSION}/bin:${PATH}"
}

check_not_root() {
  if [[ "$(id -u)" == "0" ]]; then
    fatal "This image must not run as root. Remove '--user 0' / runAsUser: 0; it runs as uid 1000."
  fi
}

ensure_directories() {
  if [[ ! -w "${DATA_DIR}" ]]; then
    fatal "${DATA_DIR} is not writable by uid $(id -u). On Kubernetes set securityContext.fsGroup: 1000, or make the volume writable for uid 1000. Volumes created by the old root-based image need: chown -R 1000:1000 <volume>"
  fi

  mkdir -p \
    "${BENCH_DIR%/*}" \
    "${MARIADB_DATA_DIR}" \
    "${REDIS_DATA_DIR}" \
    "${CODE_SERVER_DATA_DIR}/user-data" \
    "${CODE_SERVER_DATA_DIR}/extensions" \
    "${RUN_DIR}" \
    "${FRAPPE_HOME}"
  chmod 0700 "${RUN_DIR}" "${MARIADB_DATA_DIR}"

  local dir
  for dir in "${MARIADB_DATA_DIR}" "${REDIS_DATA_DIR}" "${BENCH_DIR%/*}"; do
    [[ -w "${dir}" ]] || fatal "${dir} exists but is not writable by uid $(id -u). If it came from the old root-based image, run: chown -R 1000:1000 ${dir}"
  done
}

validate_environment() {
  require_command "${BENCH_CMD}"
  require_command mysql
  require_command redis-cli

  if is_true "${CREATE_SITE_ON_FIRST_RUN:-1}"; then
    require_env SITE_NAME
    require_env SITE_ADMIN_PASSWORD
    require_env DB_ROOT_PASSWORD
  fi

  if is_true "${ENABLE_LOCAL_MARIADB:-1}"; then
    require_env DB_ROOT_PASSWORD
    export DB_HOST="127.0.0.1"
    export MARIADB_AUTOSTART=true
  else
    require_env DB_HOST
    export MARIADB_AUTOSTART=false
  fi

  if is_true "${ENABLE_LOCAL_REDIS:-1}"; then
    export REDIS_URL="${REDIS_URL:-redis://127.0.0.1:6379}"
    if [[ ! "${REDIS_URL}" =~ ^redis://(127\.0\.0\.1|localhost):6379(/.*)?$ ]]; then
      fatal "REDIS_URL must point at 127.0.0.1:6379 when ENABLE_LOCAL_REDIS=1"
    fi
    export REDIS_AUTOSTART=true
  else
    require_env REDIS_URL
    export REDIS_AUTOSTART=false
  fi

  export CODE_SERVER_AUTOSTART=false
  if is_true "${ENABLE_CODE_SERVER:-1}"; then
    if [[ ! -x "${CODE_SERVER_BIN}" ]]; then
      warn "ENABLE_CODE_SERVER=1 but ${CODE_SERVER_BIN} is not installed (image built with INSTALL_CODE_SERVER=0); code-server disabled"
    else
      case "${CODE_SERVER_AUTH}" in
        password)
          if [[ -z "${PASSWORD:-}" && -z "${HASHED_PASSWORD:-}" ]]; then
            fatal "code-server auth is 'password' but neither PASSWORD nor HASHED_PASSWORD is set. Set one, or ENABLE_CODE_SERVER=0."
          fi
          ;;
        none)
          warn "code-server is running WITHOUT authentication (CODE_SERVER_AUTH=none). Anyone who can reach port ${CODE_SERVER_BIND_ADDR##*:} gets a shell. Only use this behind a private port-forward."
          ;;
        *)
          fatal "CODE_SERVER_AUTH must be 'password' or 'none'"
          ;;
      esac
      export CODE_SERVER_AUTOSTART=true
    fi
  fi

  if is_true "${ADD_SITE_TO_ETC_HOSTS:-0}"; then
    warn "ADD_SITE_TO_ETC_HOSTS is no longer supported (the container is non-root). Use --add-host or Kubernetes hostAliases instead."
  fi
}

# --- MariaDB -----------------------------------------------------------------

write_mysql_client_config() {
  # Keeps the root password out of process arguments.
  local cnf="${RUN_DIR}/root.cnf"
  (
    umask 0077
    printf '[client]\nuser=root\npassword="%s"\nsocket=%s\n' \
      "$(printf '%s' "${DB_ROOT_PASSWORD}" | sed 's/\\/\\\\/g; s/"/\\"/g')" \
      "${RUN_DIR}/mysqld.sock" >"${cnf}"
  )
  export MYSQL_ROOT_CNF="${cnf}"
}

mysql_root() {
  mysql --defaults-extra-file="${MYSQL_ROOT_CNF}" "$@"
}

wait_for_socket() {
  local socket="$1" timeout="$2" elapsed=0
  until mysqladmin --no-defaults --socket="${socket}" ping --silent >/dev/null 2>&1; do
    sleep 1
    elapsed=$((elapsed + 1))
    if (( elapsed >= timeout )); then
      [[ -f "${RUN_DIR}/mariadb-bootstrap.log" ]] && sed 's/^/[mariadb] /' "${RUN_DIR}/mariadb-bootstrap.log" >&2
      fatal "MariaDB did not become ready within ${timeout}s"
    fi
  done
}

initialize_mariadb_datadir() {
  if [[ -d "${MARIADB_DATA_DIR}/mysql" ]]; then
    return 1
  fi
  info "Initializing MariaDB data directory"
  mariadb-install-db \
    --datadir="${MARIADB_DATA_DIR}" \
    --auth-root-authentication-method=normal \
    --skip-test-db \
    >"${RUN_DIR}/mariadb-install.log" 2>&1 || {
      sed 's/^/[mariadb-install] /' "${RUN_DIR}/mariadb-install.log" >&2
      fatal "mariadb-install-db failed"
    }
  return 0
}

start_temp_mariadb() {
  local fresh=0
  initialize_mariadb_datadir && fresh=1

  info "Starting MariaDB for bootstrap"
  mariadbd \
    --datadir="${MARIADB_DATA_DIR}" \
    --socket="${RUN_DIR}/mysqld.sock" \
    --pid-file="${RUN_DIR}/mysqld.pid" \
    --bind-address=127.0.0.1 \
    --port="${DB_PORT}" \
    --skip-name-resolve \
    --character-set-server=utf8mb4 \
    --collation-server=utf8mb4_unicode_ci \
    >"${RUN_DIR}/mariadb-bootstrap.log" 2>&1 &
  TEMP_MARIADB_PID=$!
  wait_for_socket "${RUN_DIR}/mysqld.sock" "${MARIADB_START_TIMEOUT:-60}"

  local pw
  pw="$(sql_escape "${DB_ROOT_PASSWORD}")"

  if (( fresh )); then
    # Fresh datadir: root@localhost has an empty password over the socket.
    mysql --no-defaults --socket="${RUN_DIR}/mysqld.sock" -u root <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${pw}';
FLUSH PRIVILEGES;
SQL
  fi

  mysql_root -e 'SELECT 1' >/dev/null 2>&1 \
    || fatal "Cannot log in to MariaDB as root with DB_ROOT_PASSWORD. If you changed the password, reset it in the datadir or start from an empty volume."

  # Keep exactly two root accounts, both loopback and password-protected.
  # Removes root@'%' from the previous image and the passwordless
  # root@::1 / root@<hostname> that mariadb-install-db creates.
  mysql_root <<SQL
CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED BY '${pw}';
ALTER USER 'root'@'127.0.0.1' IDENTIFIED BY '${pw}';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION;
DELETE FROM mysql.global_priv WHERE User = 'root' AND Host NOT IN ('localhost', '127.0.0.1');
DELETE FROM mysql.global_priv WHERE User = '';
FLUSH PRIVILEGES;
SQL
}

stop_temp_mariadb() {
  [[ -n "${TEMP_MARIADB_PID}" ]] || return 0
  info "Stopping bootstrap MariaDB"
  mysqladmin --defaults-extra-file="${MYSQL_ROOT_CNF}" shutdown >/dev/null 2>&1 \
    || kill -TERM "${TEMP_MARIADB_PID}" 2>/dev/null || true
  wait "${TEMP_MARIADB_PID}" 2>/dev/null || true
  TEMP_MARIADB_PID=""
}

wait_for_external_mariadb() {
  local timeout="${MARIADB_START_TIMEOUT:-60}" elapsed=0
  until MYSQL_PWD="${DB_ROOT_PASSWORD:-}" mysqladmin --no-defaults -h "${DB_HOST}" -P "${DB_PORT}" --protocol=tcp -u root ping --silent >/dev/null 2>&1; do
    sleep 2
    elapsed=$((elapsed + 2))
    (( elapsed < timeout )) || fatal "MariaDB at ${DB_HOST}:${DB_PORT} did not become ready within ${timeout}s"
  done
}

# --- Redis -------------------------------------------------------------------

start_temp_redis() {
  info "Starting Redis for bootstrap"
  redis-server \
    --bind 127.0.0.1 \
    --port 6379 \
    --protected-mode yes \
    --dir "${REDIS_DATA_DIR}" \
    --appendonly yes \
    --daemonize no \
    >"${RUN_DIR}/redis-bootstrap.log" 2>&1 &
  TEMP_REDIS_PID=$!
  local elapsed=0
  until redis-cli -u "${REDIS_URL}" ping >/dev/null 2>&1; do
    sleep 1
    elapsed=$((elapsed + 1))
    (( elapsed < 30 )) || fatal "Redis did not become ready within 30s"
  done
}

stop_temp_redis() {
  [[ -n "${TEMP_REDIS_PID}" ]] || return 0
  info "Stopping bootstrap Redis"
  redis-cli -u "${REDIS_URL}" shutdown >/dev/null 2>&1 \
    || kill -TERM "${TEMP_REDIS_PID}" 2>/dev/null || true
  wait "${TEMP_REDIS_PID}" 2>/dev/null || true
  TEMP_REDIS_PID=""
}

start_temp_services() {
  if is_true "${ENABLE_LOCAL_MARIADB:-1}"; then
    write_mysql_client_config
    start_temp_mariadb
  else
    wait_for_external_mariadb
  fi
  if is_true "${ENABLE_LOCAL_REDIS:-1}"; then
    start_temp_redis
  fi
}

stop_temp_services() {
  stop_temp_redis
  stop_temp_mariadb
}

# --- bench / site ------------------------------------------------------------

# Everything a finished `bench init` leaves behind. bench writes the Procfile
# early and exits 0 even after rolling back a failed init, so neither the
# Procfile nor the exit code is enough on its own.
bench_is_complete() {
  [[ -f "${BENCH_DIR}/Procfile" \
     && -f "${BENCH_DIR}/sites/common_site_config.json" \
     && -x "${BENCH_DIR}/env/bin/python" \
     && -d "${BENCH_DIR}/apps/frappe/node_modules" \
     && -d "${BENCH_DIR}/sites/assets/frappe" ]]
}

bench_is_ready() {
  local marker="${BENCH_DIR}/.devbox-bench-ready"
  [[ -f "${marker}" ]] && return 0
  # Benches from the earlier image have no marker; adopt them if complete.
  if bench_is_complete; then
    touch "${marker}"
    return 0
  fi
  return 1
}

ensure_bench() {
  if bench_is_ready; then
    info "Using existing bench at ${BENCH_DIR}"
    return 0
  fi
  if [[ -e "${BENCH_DIR}" ]]; then
    warn "Removing incomplete bench at ${BENCH_DIR} from an earlier failed run and retrying"
    rm -rf "${BENCH_DIR}"
  fi
  info "Initializing bench at ${BENCH_DIR} (first run; this takes a while)"
  # On failure bench asks "rollback? [y/N]"; answer yes so a container
  # restart retries from a clean state instead of hanging or wedging.
  (
    cd "${BENCH_DIR%/*}"
    printf 'y\n' | "${BENCH_CMD}" init --skip-redis-config-generation --frappe-branch "${FRAPPE_BRANCH:-version-15}" "${BENCH_DIR}"
  )
  bench_is_complete || fatal "bench init did not complete (see output above); the container will retry from scratch on restart"
  touch "${BENCH_DIR}/.devbox-bench-ready"
}

configure_common_site() {
  info "Configuring bench-wide settings"
  cd "${BENCH_DIR}"
  "${BENCH_CMD}" set-config -g developer_mode "${DEVELOPER_MODE:-1}"
  "${BENCH_CMD}" set-config -g dns_multitenant "${DNS_MULTITENANT:-0}"
  "${BENCH_CMD}" set-config -g db_host "${DB_HOST}"
  "${BENCH_CMD}" set-config -g db_port "${DB_PORT}"
  "${BENCH_CMD}" set-config -g redis_cache "${REDIS_URL}"
  "${BENCH_CMD}" set-config -g redis_queue "${REDIS_URL}"
  "${BENCH_CMD}" set-config -g redis_socketio "${REDIS_URL}"
  "${BENCH_CMD}" set-config -g webserver_port 8000
  "${BENCH_CMD}" set-config -g socketio_port 9000
}

patch_procfile_once() {
  local procfile="${BENCH_DIR}/Procfile"
  local marker="${BENCH_DIR}/.devbox-procfile-patched"

  is_true "${PATCH_PROCFILE_FOR_DEV_SERVER:-1}" || { info "Skipping Procfile patch"; return 0; }
  [[ -f "${procfile}" ]] || fatal "Procfile not found at ${procfile}"
  [[ -f "${marker}" ]] && return 0

  info "Patching Procfile for container-friendly bench start"
  sed -i \
    -e "s|^web: .*|web: bench serve --port 8000|" \
    -e "s|^socketio: .*|socketio: /usr/bin/env node apps/frappe/socketio.js|" \
    -e "/^redis_cache:/d" \
    -e "/^redis_queue:/d" \
    "${procfile}"
  touch "${marker}"
}

create_site_if_needed() {
  is_true "${CREATE_SITE_ON_FIRST_RUN:-1}" || { info "Skipping site creation"; return 0; }
  cd "${BENCH_DIR}"

  if [[ -d "${BENCH_DIR}/sites/${SITE_NAME}" ]]; then
    info "Site ${SITE_NAME} already exists"
    "${BENCH_CMD}" use "${SITE_NAME}"
    return 0
  fi

  info "Creating site ${SITE_NAME}"
  # bench takes these only as arguments; they are visible only to this
  # container's own uid for the duration of the command.
  "${BENCH_CMD}" new-site "${SITE_NAME}" \
    --admin-password "${SITE_ADMIN_PASSWORD}" \
    --db-root-username root \
    --db-root-password "${DB_ROOT_PASSWORD}" \
    --db-host "${DB_HOST}" \
    --db-port "${DB_PORT}" \
    --set-default

  local apps_raw="${DEVBOX_INSTALL_APPS:-}" app
  if [[ -n "$(trim "${apps_raw}")" ]]; then
    IFS=',' read -r -a apps <<<"${apps_raw}"
    for app in "${apps[@]}"; do
      app="$(trim "${app}")"
      [[ -n "${app}" ]] || continue
      info "Installing app ${app} on ${SITE_NAME}"
      "${BENCH_CMD}" --site "${SITE_NAME}" install-app "${app}"
    done
  fi
}

install_vscode_extensions() {
  [[ "${CODE_SERVER_AUTOSTART}" == "true" ]] || return 0
  is_true "${INSTALL_VSCODE_EXTENSIONS:-1}" || return 0

  local spec_file="${CODE_SERVER_DATA_DIR}/.devbox-extension-spec"
  local desired
  desired="$(printf 'ext=%s\nvsix=%s\n' "${VSCODE_EXTENSIONS:-}" "${LOCAL_VSIX_PATH:-}")"
  if [[ -f "${spec_file}" ]] && [[ "$(cat "${spec_file}")" == "${desired}" ]]; then
    info "Requested code-server extensions already installed"
    return 0
  fi

  local cs_args=(--user-data-dir "${CODE_SERVER_DATA_DIR}/user-data" --extensions-dir "${CODE_SERVER_DATA_DIR}/extensions")
  local item
  if [[ -n "$(trim "${VSCODE_EXTENSIONS:-}")" ]]; then
    IFS=',' read -r -a items <<<"${VSCODE_EXTENSIONS}"
    for item in "${items[@]}"; do
      item="$(trim "${item}")"
      [[ -n "${item}" ]] || continue
      info "Installing code-server extension ${item}"
      "${CODE_SERVER_BIN}" "${cs_args[@]}" --install-extension "${item}" \
        || warn "Could not install extension ${item}; continuing"
    done
  fi
  if [[ -n "$(trim "${LOCAL_VSIX_PATH:-}")" ]]; then
    IFS=',' read -r -a items <<<"${LOCAL_VSIX_PATH}"
    for item in "${items[@]}"; do
      item="$(trim "${item}")"
      [[ -n "${item}" ]] || continue
      [[ -f "${item}" ]] || fatal "VSIX file not found: ${item}"
      info "Installing code-server VSIX ${item}"
      "${CODE_SERVER_BIN}" "${cs_args[@]}" --install-extension "${item}"
    done
  fi
  printf '%s' "${desired}" >"${spec_file}"
}

main() {
  set_defaults
  check_not_root
  ensure_directories
  validate_environment

  start_temp_services
  ensure_bench
  configure_common_site
  patch_procfile_once
  create_site_if_needed
  stop_temp_services

  install_vscode_extensions

  trap - EXIT
  info "Bootstrap complete; starting: $*"
  exec "$@"
}

main "$@"
