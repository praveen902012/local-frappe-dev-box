FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    FRAPPE_USER=frappe \
    FRAPPE_HOME=/home/frappe \
    BENCH_DIR=/workspace/frappe-bench \
    BENCH_CMD=bench \
    SITE_NAME=dev.localhost \
    DB_PORT=3306 \
    DEVBOX_INSTALL_APPS= \
    DEVELOPER_MODE=1 \
    DNS_MULTITENANT=0 \
    CREATE_SITE_ON_FIRST_RUN=1 \
    INSTALL_VSCODE_EXTENSIONS=1 \
    PATCH_PROCFILE_FOR_DEV_SERVER=1 \
    ADD_SITE_TO_ETC_HOSTS=0 \
    MARIADB_START_TIMEOUT=60 \
    ENABLE_LOCAL_MARIADB=1 \
    ENABLE_LOCAL_REDIS=1 \
    CODE_SERVER_BIN=/usr/bin/code-server \
    VSCODE_EXTENSIONS=ms-python.python,dbaeumer.vscode-eslint \
    LOCAL_VSIX_PATH= \
    NVM_DIR=/usr/local/nvm \
    NODE_VERSION=20.12.2 \
    FRAPPE_BRANCH=version-15 \
    CODE_SERVER_BIND_ADDR=0.0.0.0:8080

SHELL ["/bin/bash", "-lc"]

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
      software-properties-common \
      supervisor \
      tini \
      unzip \
      util-linux \
      vim \
      xz-utils && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p "${NVM_DIR}" && \
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash && \
    source "${NVM_DIR}/nvm.sh" && \
    nvm install "${NODE_VERSION}" && \
    nvm alias default "${NODE_VERSION}" && \
    nvm use default && \
    npm install -g yarn && \
    ln -sf "${NVM_DIR}/versions/node/v${NODE_VERSION}/bin/node" /usr/local/bin/node && \
    ln -sf "${NVM_DIR}/versions/node/v${NODE_VERSION}/bin/npm" /usr/local/bin/npm && \
    ln -sf "${NVM_DIR}/versions/node/v${NODE_VERSION}/bin/npx" /usr/local/bin/npx && \
    ln -sf "${NVM_DIR}/versions/node/v${NODE_VERSION}/bin/yarn" /usr/local/bin/yarn

RUN curl -fsSL https://code-server.dev/install.sh | sh

RUN python3 -m pip install --no-cache-dir --break-system-packages \
      frappe-bench \
      setuptools \
      wheel

RUN if ! getent group "${FRAPPE_USER}" >/dev/null; then \
      existing_group="$(getent group 1000 | cut -d: -f1 || true)"; \
      if [[ -n "${existing_group}" ]]; then \
        groupmod -n "${FRAPPE_USER}" "${existing_group}"; \
      else \
        groupadd --gid 1000 "${FRAPPE_USER}"; \
      fi; \
    fi && \
    if ! id -u "${FRAPPE_USER}" >/dev/null 2>&1; then \
      existing_user="$(getent passwd 1000 | cut -d: -f1 || true)"; \
      if [[ -n "${existing_user}" ]]; then \
        usermod -l "${FRAPPE_USER}" -d "${FRAPPE_HOME}" -m -g "${FRAPPE_USER}" -s /bin/bash "${existing_user}"; \
      else \
        useradd --uid 1000 --gid "${FRAPPE_USER}" --create-home --shell /bin/bash "${FRAPPE_USER}"; \
      fi; \
    fi && \
    mkdir -p \
      /workspace \
      /var/lib/mysql \
      /var/lib/redis \
      /var/log/supervisor \
      /run/mysqld \
      /etc/supervisor/conf.d && \
    chown -R "${FRAPPE_USER}:${FRAPPE_USER}" /workspace "${FRAPPE_HOME}" && \
    chown -R mysql:mysql /var/lib/mysql /run/mysqld && \
    chown -R redis:redis /var/lib/redis

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY docker/supervisor/devbox.conf /etc/supervisor/conf.d/devbox.conf

RUN chmod 0755 /usr/local/bin/entrypoint.sh

WORKDIR /workspace

VOLUME ["/workspace", "/var/lib/mysql", "/var/lib/redis", "/home/frappe/.local/share/code-server"]

EXPOSE 8000 8080

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/devbox.conf"]
