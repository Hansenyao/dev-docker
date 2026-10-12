# syntax=docker/dockerfile:1
# AI development image: toolchains + Claude Code, default user ai-coder.
# See docs/superpowers/specs/2026-10-12-ai-dev-container-design.md.

ARG UV_VERSION=0.13.0
FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv

FROM ubuntu:24.04

ARG NODE_VERSION=24.21.0
ARG GO_VERSION=1.27.2
ARG MAVEN_VERSION=3.9.16
ARG JAVA_VERSION=21
ARG USERNAME=ai-coder
ARG USER_UID=1000

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Base tools, C/C++ toolchain, system Python, PostgreSQL client.
RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl wget ca-certificates gnupg jq ripgrep fd-find tree vim less \
      unzip zip xz-utils htop sudo locales tzdata procps \
      build-essential pkg-config clang cmake ninja-build gdb ccache \
      python3 python3-dev python3-venv python3-pip \
      postgresql-client \
    && ln -s /usr/bin/fdfind /usr/local/bin/fd \
    && locale-gen en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

# Third-party apt repos: Temurin JDK, Docker CLI, GitHub CLI.
RUN install -d -m 0755 /etc/apt/keyrings \
    && curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public \
       | gpg --dearmor -o /etc/apt/keyrings/adoptium.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb noble main" \
       > /etc/apt/sources.list.d/adoptium.list \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
       | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable" \
       > /etc/apt/sources.list.d/docker.list \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       -o /etc/apt/keyrings/githubcli.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends \
      temurin-${JAVA_VERSION}-jdk \
      docker-ce-cli docker-compose-plugin docker-buildx-plugin \
      gh \
    && rm -rf /var/lib/apt/lists/*

# Node.js (official build) with corepack shims for pnpm and yarn.
RUN curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
    | tar -xJ -C /usr/local --strip-components=1 --exclude='*.md' --exclude=LICENSE \
    && corepack enable

# Go (official build).
RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" | tar -xz -C /usr/local

# Maven (from Maven Central; Ubuntu's package would pull in another JDK).
RUN curl -fsSL "https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/${MAVEN_VERSION}/apache-maven-${MAVEN_VERSION}-bin.tar.gz" \
    | tar -xz -C /opt \
    && ln -s "/opt/apache-maven-${MAVEN_VERSION}/bin/mvn" /usr/local/bin/mvn

# uv (Python version, venv and package manager).
COPY --from=uv /uv /uvx /usr/local/bin/

# Non-root default user. Ubuntu 24.04 ships user "ubuntu" with UID 1000.
RUN userdel -r ubuntu \
    && groupadd --gid "${USER_UID}" "${USERNAME}" \
    && useradd --uid "${USER_UID}" --gid "${USER_UID}" --create-home --shell /bin/bash "${USERNAME}" \
    && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${USERNAME}" \
    && chmod 0440 "/etc/sudoers.d/${USERNAME}" \
    && install -d -o "${USERNAME}" -g "${USERNAME}" /workspace /opt/rustup /opt/cargo

# Helper scripts and system config.
COPY --chmod=0755 scripts/git-credential-ghtoken scripts/gh scripts/ai-dev-check scripts/smoke-test /usr/local/bin/
COPY --chmod=0644 config/gitconfig /etc/gitconfig
COPY --chmod=0644 config/profile.sh /etc/profile.d/ai-dev.sh

ENV RUSTUP_HOME=/opt/rustup \
    CARGO_HOME=/opt/cargo \
    GOPATH=/home/${USERNAME}/go \
    PATH=/home/${USERNAME}/.local/bin:/opt/cargo/bin:/usr/local/go/bin:/home/${USERNAME}/go/bin:${PATH} \
    NPM_CONFIG_PREFIX=/home/${USERNAME}/.local \
    COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
    CLAUDE_CONFIG_DIR=/home/${USERNAME}/.claude \
    DISABLE_AUTOUPDATER=1 \
    DOCKER_HOST=tcp://127.0.0.1:2375 \
    HISTFILE=/home/${USERNAME}/.history/bash_history

USER ${USERNAME}

# Mount points for named volumes and host state, created here so they are
# owned by ai-coder when Docker initialises the volumes.
RUN mkdir -p ~/.cache ~/.npm ~/go/pkg/mod ~/.m2 ~/.history ~/.claude ~/.config/git ~/.local/bin \
    /opt/cargo/registry

# Rust toolchain into /opt/rustup and /opt/cargo (owned by ai-coder).
RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile minimal \
      --default-toolchain stable --component rustfmt,clippy,rust-analyzer

# Claude Code (native installer, into ~/.local/bin).
RUN curl -fsSL https://claude.ai/install.sh | bash \
    && rm -rf ~/.claude/downloads

# VS Code attach: the Dev Containers settings that stop git and Docker
# credential forwarding are machine-scoped, so the extension reads them from
# the container's machine settings, not from the host's user settings.
# It also copies the host's ~/.gitconfig unless that file already has a
# section (it ignores copyGitConfig=false here), so a placeholder is installed
# and git is pointed at the mounted ~/.config/git/config as its only global
# config.
ENV GIT_CONFIG_GLOBAL=/home/${USERNAME}/.config/git/config
RUN mkdir -p ~/.vscode-server/data/Machine
COPY --chown=${USERNAME}:${USERNAME} config/vscode-machine-settings.json \
    /home/${USERNAME}/.vscode-server/data/Machine/settings.json
COPY --chown=${USERNAME}:${USERNAME} config/home-gitconfig /home/${USERNAME}/.gitconfig

WORKDIR /workspace
CMD ["sleep", "infinity"]
