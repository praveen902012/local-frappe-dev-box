FROM ubuntu:24.04

# Set to 0 to build without code-server (smaller image, no browser IDE).
ARG INSTALL_CODE_SERVER=1
# Pin for reproducible builds, e.g. --build-arg CODE_SERVER_VERSION=4.96.4 (empty = latest).
ARG CODE_SERVER_VERSION=
ARG NVM_VERSION=v0.39.7

# Everything that must persist lives under /data so the image needs a single
# writable volume (one PVC on Kubernetes, no subPaths).
ENV DEBIAN_FRONTEND=noninteractive \
    FRAPPE_USER=frappe \
    FRAPPE_HOME=/home/frappe \
    DATA_DIR=/data \
    BENCH_DIR=/data/workspace/frappe-bench \
    MARIADB_DATA_DIR=/data/mysql \
    REDIS_DATA_DIR=/data/redis \
    CODE_SERVER_DATA_DIR=/data/code-server \
    RUN_DIR=/tmp/devbox-run \
    BENCH_CMD=bench \
    SITE_NAME=dev.localhost \
    DB_PORT=3306 \
    DEVBOX_INSTALL_APPS= \
    DEVELOPER_MODE=1 \
    DNS_MULTITENANT=0 \
    CREATE_SITE_ON_FIRST_RUN=1 \
    INSTALL_VSCODE_EXTENSIONS=1 \
    PATCH_PROCFILE_FOR_DEV_SERVER=1 \
    MARIADB_START_TIMEOUT=60 \
    ENABLE_LOCAL_MARIADB=1 \
    ENABLE_LOCAL_REDIS=1 \
    ENABLE_CODE_SERVER=1 \
    CODE_SERVER_BIN=/usr/bin/code-server \
    CODE_SERVER_AUTH=password \
    CODE_SERVER_BIND_ADDR=0.0.0.0:8080 \
    VSCODE_EXTENSIONS=ms-python.python,dbaeumer.vscode-eslint \
    LOCAL_VSIX_PATH= \
    NVM_DIR=/usr/local/nvm \
    NODE_VERSION=20.12.2 \
    FRAPPE_BRANCH=version-15

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      bash \
      build-essential \
      ca-certificates \
      cron \
      curl \
      git \
      gnupg \
      jq \
      less \
      libffi-dev \
      libjpeg-dev \
      liblcms2-dev \
      libldap2-dev \
      libsasl2-dev \
      libssl-dev \
      libtiff6 \
      libwebp-dev \
      libx11-6 \
      libxext6 \
      libxml2-dev \
      libxslt1-dev \
      libzip-dev \
      mariadb-client \
      mariadb-server \
      pkg-config \
      python3 \
      python3-dev \
      python3-pip \
      python3-venv \
      redis-server \
      rsync \
      supervisor \
      tini \
      unzip \
      vim \
      xz-utils && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p "${NVM_DIR}" && \
    curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash && \
    source "${NVM_DIR}/nvm.sh" && \
    nvm install "${NODE_VERSION}" && \
    nvm alias default "${NODE_VERSION}" && \
    npm install -g yarn && \
    npm cache clean --force && \
    for bin in node npm npx yarn; do \
      ln -sf "${NVM_DIR}/versions/node/v${NODE_VERSION}/bin/${bin}" "/usr/local/bin/${bin}"; \
    done

RUN if [[ "${INSTALL_CODE_SERVER}" == "1" ]]; then \
      if [[ -n "${CODE_SERVER_VERSION}" ]]; then \
        curl -fsSL https://code-server.dev/install.sh | sh -s -- --version "${CODE_SERVER_VERSION}"; \
      else \
        curl -fsSL https://code-server.dev/install.sh | sh; \
      fi; \
    fi

# setuptools>=81 drops pkg_resources, which Ubuntu's supervisor imports;
# an unpinned install here breaks supervisord at startup.
RUN python3 -m pip install --no-cache-dir --break-system-packages \
      frappe-bench \
      "setuptools<81" \
      wheel && \
    python3 -c "import pkg_resources" 2>/dev/null && \
    supervisord --version

# Run everything as uid/gid 1000. ubuntu:24.04 ships an "ubuntu" user with
# uid 1000, so rename it rather than creating a second user.
RUN if id -u ubuntu >/dev/null 2>&1; then \
      groupmod -n "${FRAPPE_USER}" ubuntu && \
      usermod -l "${FRAPPE_USER}" -d "${FRAPPE_HOME}" -m -s /bin/bash ubuntu; \
    else \
      groupadd --gid 1000 "${FRAPPE_USER}" && \
      useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash "${FRAPPE_USER}"; \
    fi && \
    mkdir -p "${DATA_DIR}" "${FRAPPE_HOME}" && \
    chown 1000:1000 "${DATA_DIR}" "${FRAPPE_HOME}" && \
    chmod 0750 "${DATA_DIR}" && \
    # Drop the distro supervisor config that expects root-owned /var/run paths.
    rm -f /etc/supervisor/supervisord.conf

COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chmod=0644 docker/supervisor/devbox.conf /etc/supervisor/devbox.conf

USER 1000:1000
WORKDIR /data

VOLUME ["/data"]

EXPOSE 8000 9000 8080

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/devbox.conf"]
