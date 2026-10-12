# AI 开发容器设计（ai-dev）

日期：2026-10-12
状态：待审阅

## 1. 目标与边界

### 目标
在 macOS 上提供一个常驻的 Docker 开发环境，让 Claude Code 在容器内以 `--dangerously-skip-permissions` 模式开发多个项目，同时让 macOS 上 `~/ai-workspace` 以外的数据对 AI 不可见。

### 工作模式
1. 项目代码 clone 或创建在 macOS 的 `~/ai-workspace/` 下，该目录映射为容器内 `/workspace`。
2. 容器由 `docker compose` 常驻运行，镜像内已预装开发工具链和 Claude Code。
3. macOS 上的 VS Code 通过 **Dev Containers: Attach to Running Container** 连接容器，打开 `/workspace/<项目>`，在 VS Code 终端中登录并使用 Claude。
4. AI 可在容器内直接 `git commit` / `git push`。
5. AI 可在容器内使用一个独立的嵌套 Docker 引擎（如起数据库），与 Docker Desktop 上的其他容器隔离。

### 威胁模型

| 风险 | 是否防护 | 手段 |
|---|---|---|
| AI 误删/篡改 macOS 上项目目录以外的文件 | 防 | 只挂载 `~/ai-workspace` 与 `~/.ai-dev`；收窄 Docker Desktop File Sharing |
| AI 读取 macOS 上的敏感信息（`~/.ssh`、`~/.aws`、浏览器数据、钱包等） | 防 | 同上；关闭 VS Code 的 SSH agent / git 凭据 / Docker 凭据转发 |
| AI 以你的身份访问所有 GitHub 仓库 | 防 | 只提供 Fine-grained Token，仅授权指定仓库 |
| 容器内数据（工作区代码、Token）经网络外传 | **不防**（已确认接受） | 不做出站网络限制；靠 Token 最小权限与可吊销降低损失 |
| AI 修改 CI 读取仓库 Actions secrets | 防 | Token 不授予 Workflows 权限 |

### 非目标
- 出站网络白名单。
- 除 Claude Code 外的其他 AI Agent。
- Apple Silicon（arm64）适配：当前只在 Intel Mac（x86_64）+ Docker Desktop 上验证。
- GitHub 侧配置（如 `main` 分支保护）：README 中建议，但不属于本项目实现范围。

## 2. 总体架构

```
macOS
├── ~/ai-workspace/            ──bind──▶ /workspace          (ai-dev, docker)
├── ~/.ai-dev/claude/          ──bind──▶ /home/ai-coder/.claude          (ai-dev)
├── ~/.ai-dev/git/             ──bind──▶ /home/ai-coder/.config/git      (ai-dev)
└── ~/.ai-dev/secrets/ (ro)    ──bind──▶ /run/secrets/ai-dev             (ai-dev)

Docker Desktop VM（File Sharing 仅限 ~/ai-workspace、~/.ai-dev）
└── compose 项目 ai-dev
    ├── 服务 docker   (docker:dind, privileged)
    │     dockerd 监听 127.0.0.1:2375；/var/lib/docker → volume ai-dev-docker-data
    └── 服务 dev      (自建镜像, 非特权, network_mode: service:docker)
          默认用户 ai-coder；DOCKER_HOST=tcp://127.0.0.1:2375
```

- `dev` 与 `docker` 共享网络命名空间：嵌套容器发布的端口在 `dev` 中以 `localhost:<port>` 访问；dockerd 只监听回环地址，故不配 TLS。
- `dev` 通过 `depends_on: condition: service_healthy` 等待 dockerd 就绪。
- 不对外发布端口，开发服务器端口由 VS Code 自动转发到 macOS。

## 3. 镜像（Dockerfile）

- 基础镜像：`ubuntu:24.04`，平台 `linux/amd64`。
- 所有版本号集中在 Dockerfile 顶部 `ARG`，升级只改一行。
- 工具链安装到 `/usr/local`、`/opt` 或系统路径，**不放在 home 下**，避免被挂载覆盖。

### 基础包
`git curl wget ca-certificates gnupg jq ripgrep fd-find tree vim less unzip zip htop sudo locales tzdata procps build-essential pkg-config`

### 用户
- `ai-coder`，UID/GID 1000，shell 为 bash，免密 sudo（`/etc/sudoers.d/ai-coder`），镜像默认用户。
- 理由：Claude Code 拒绝以 root 运行 `--dangerously-skip-permissions`；sudo 让 AI 可自行 `apt install`。

### 语言与工具

| 项 | 版本 | 安装方式 | 位置 |
|---|---|---|---|
| Node.js | 24 LTS | 官方二进制包；启用 `corepack`（pnpm、yarn） | `/usr/local` |
| Python | 系统 3.12 + `uv` | apt + uv 官方二进制 | `/usr/bin`、`/usr/local/bin` |
| C++ | GCC 13、Clang 18、CMake、Ninja、GDB、ccache | apt | 系统 |
| Rust | stable + rustfmt、clippy、rust-analyzer | rustup；`RUSTUP_HOME=/opt/rustup`、`CARGO_HOME=/opt/cargo`，归属 ai-coder | `/opt` |
| Go | 构建时的最新稳定版（ARG 固定） | 官方 tarball；`GOPATH=/home/ai-coder/go` | `/usr/local/go` |
| Java | Temurin JDK 21 + Maven | Adoptium apt 源 + apt；Gradle 用项目自带 `gradlew` | 系统 |
| Docker 客户端 | CLI + compose 插件 + buildx（不含 dockerd） | Docker 官方 apt 源 | 系统 |
| GitHub CLI | 最新版 | GitHub 官方 apt 源，真实二进制在 `/usr/bin/gh` | 系统 |
| Claude Code | 构建时最新版 | 官方原生安装器，以 ai-coder 身份安装 | `~/.local/bin` |

### 环境变量
- `CLAUDE_CONFIG_DIR=/home/ai-coder/.claude`：让 `.claude.json`（引导、项目信任、MCP 配置）也落入挂载目录。
- `DISABLE_AUTOUPDATER=1`：容器内 Claude 版本与镜像一致，升级走 `make rebuild`。
- `DOCKER_HOST=tcp://127.0.0.1:2375`
- `PATH` 包含 `/home/ai-coder/.local/bin`、`/opt/cargo/bin`、`/usr/local/go/bin`、`/home/ai-coder/go/bin`。
- `HISTFILE=/home/ai-coder/.history/bash_history`

### 预建目录
所有 named volume 挂载点在镜像中预先创建并 `chown ai-coder`，确保首次创建的 volume 继承正确属主。

### 体积与构建
预计镜像 4–5 GB，首次构建 10–20 分钟。

## 4. 持久化

| 内容 | 宿主位置 / volume | 容器路径 | 说明 |
|---|---|---|---|
| 项目代码 | `~/ai-workspace` | `/workspace` | dev 与 docker 两个服务都挂载，路径一致 |
| Claude 状态 | `~/.ai-dev/claude` | `/home/ai-coder/.claude` | 会话、登录、设置、`.claude.json` |
| git 全局配置 | `~/.ai-dev/git` | `/home/ai-coder/.config/git` | git 读取 XDG `config` 作为全局配置 |
| GitHub Token | `~/.ai-dev/secrets/github-token` | `/run/secrets/ai-dev/github-token` | 目录只读挂载 |
| 通用缓存（pip、uv、go-build 等） | volume `ai-dev-cache` | `/home/ai-coder/.cache` | |
| npm 缓存 | volume `ai-dev-npm` | `/home/ai-coder/.npm` | |
| cargo registry | volume `ai-dev-cargo-registry` | `/opt/cargo/registry` | |
| Go 模块缓存 | volume `ai-dev-gomod` | `/home/ai-coder/go/pkg/mod` | |
| Maven 仓库 | volume `ai-dev-m2` | `/home/ai-coder/.m2` | |
| shell 历史 | volume `ai-dev-history` | `/home/ai-coder/.history` | |
| 嵌套 Docker 数据 | volume `ai-dev-docker-data` | `/var/lib/docker`（docker 服务） | 删除该 volume 即清空 |

设计要点：
- git 配置和 Token 挂的是**目录**而非单个文件。原因：git 以重命名方式写配置，单文件 bind mount 会写入失败；macOS 上编辑器替换文件后，单文件挂载会继续指向旧 inode，导致换 Token 不生效。
- `~/.ai-dev` 位于 `~/ai-workspace` 之外，避免 Token 被误提交进项目仓库。
- **绝不挂载** macOS 自身的 `~/.claude`、`~/.gitconfig`、`~/.ssh`。
- Claude 会话按项目路径存储，`/workspace/<项目>` 在重建前后不变，所以 `claude --continue` 可以跨容器重建恢复。

## 5. 凭据与安全

### GitHub Token
- macOS 文件 `~/.ai-dev/secrets/github-token`，权限 600。
- `/usr/local/bin/git-credential-ghtoken`：对 `github.com` 的 `get` 请求输出 `username=x-access-token` 和 `password=<文件内容>`；文件缺失或为空时报错退出。
- `/etc/gitconfig`（系统级，不受 VS Code 或用户全局配置影响）：
  ```
  [credential "https://github.com"]
      helper = ghtoken
  [url "https://github.com/"]
      insteadOf = git@github.com:
      insteadOf = ssh://git@github.com/
  ```
  作用：在 macOS 上用 SSH 地址 clone 的仓库，在容器内自动改走 HTTPS + Token。
- `/usr/local/bin/gh` 包装脚本：每次调用时从文件读取 Token 放入 `GH_TOKEN`，再 `exec /usr/bin/gh`。因此 Token 轮换立即生效，且不依赖 shell 启动文件。

### 建议的 Token 权限（README 中说明）
- Repository access：Only select repositories
- Contents：Read and write
- Pull requests：Read and write（可选，用于 `gh pr create`）
- Metadata：Read（必选）
- **不授予 Workflows**
- 过期时间：90 天

### VS Code 凭据转发
`vscode/settings.json` 给出需要合并进 VS Code **用户设置**的配置项，用于关闭：复制宿主 `~/.gitconfig`、注入 git 凭据 helper、转发 Docker 凭据、转发 SSH agent（以及 GPG agent，如有对应开关）。

**待实现时核实**：各配置项的确切名称与效果，尤其是 SSH agent 转发是否有独立开关。无论核实结果如何，都以 `ai-dev-check` 的实测结果为准。

### `ai-dev-check`（容器内运行）
以下任一项不通过即输出 FAIL，退出码非 0：
- `SSH_AUTH_SOCK` 为空，或 `ssh-add -l` 无法列出任何密钥；
- `git config --show-origin --get-all credential.helper` 只包含 `/etc/gitconfig` 中的 `ghtoken`；
- 不存在 VS Code 注入的 git/Docker 凭据相关环境变量或 socket（如 `REMOTE_CONTAINERS_IPC` 关联的凭据 helper、`/tmp/vscode-ssh-auth-*`）；
- `/workspace`、`/home/ai-coder/.claude`、`/home/ai-coder/.config/git`、`/run/secrets/ai-dev` 以外不存在来自 macOS 的 bind mount（解析 `/proc/self/mountinfo`）；
- Token 文件存在且非空。

### 容器配置
- `dev`：`container_name: ai-dev`；非特权；不挂载 `/var/run/docker.sock`；不使用 host 网络；保留 Docker 默认 capability；不设 `no-new-privileges`（否则 sudo 失效）；`init: true`；命令为 `sleep infinity`；`restart: unless-stopped`。
- `docker`：`container_name: ai-dev-docker`；`privileged: true`（嵌套 Docker 必需）；只挂载 `~/ai-workspace` 和 `ai-dev-docker-data`，**不挂载** `~/.ai-dev`；dockerd 只监听 `tcp://127.0.0.1:2375`；healthcheck 为 `docker -H tcp://127.0.0.1:2375 info`；`restart: unless-stopped`。

### Docker Desktop File Sharing（必须）
- 原因：AI 可以在嵌套 Docker 中运行 `--privileged` 容器，进而逃逸到 `docker` 容器，再到 Docker Desktop VM。此时边界退到 VM，VM 能访问的宿主目录就是 File Sharing 列表。
- 操作：Docker Desktop → Settings → Resources → File sharing，只保留 `~/ai-workspace` 和 `~/.ai-dev`，删除 `/Users`、`/Volumes`、`/private`、`/tmp`、`/var/folders` 等默认项。
- 影响：本机其他使用 `/Users/...` bind mount 的容器需要把各自的目录加回列表。
- 已知剩余风险：逃逸到 VM 后可看到 Docker Desktop 中其他容器和 volume 的数据（已确认接受）。

## 6. 仓库结构

```
dev-docker/
├── Dockerfile
├── compose.yaml
├── Makefile
├── scripts/
│   ├── git-credential-ghtoken
│   ├── gh                      # gh 包装脚本
│   ├── ai-dev-check
│   └── smoke-test
├── vscode/settings.json
├── docs/superpowers/specs/     # 本文件
├── README.md
└── CLAUDE.md
```

## 7. 操作入口（Makefile，在 macOS 上执行）

| 命令 | 行为 |
|---|---|
| `make setup` | 创建 `~/ai-workspace`、`~/.ai-dev/{claude,git,secrets}`；交互式写入 `~/.ai-dev/git/config` 的 `user.name`/`user.email`（已存在则跳过）；若 Token 文件不存在，则提示创建方法并设置权限 600；提醒完成 File Sharing 收窄 |
| `make build` | 构建镜像 |
| `make up` | `docker compose up -d`；启动前检查 `~/.ai-dev/git`、`~/.ai-dev/secrets` 等挂载源是否存在，缺失时提示先运行 `make setup` |
| `make down` | `docker compose down`（不删除 volume） |
| `make shell` | 以 ai-coder 身份进入 `dev` 的 bash |
| `make check` | 宿主侧：`docker run --rm -v "$HOME/Documents:/x" alpine ls /x` **必须失败**；容器内：运行 `ai-dev-check` 和 `smoke-test` |
| `make rebuild` | `build --pull` 后 `up -d --force-recreate`；持久化数据不受影响 |

## 8. 使用流程

### 首次
1. 收窄 Docker Desktop File Sharing。
2. 在 GitHub 创建 Fine-grained Token。
3. `make setup` → `make build` → `make up`。
4. 把 `vscode/settings.json` 合并进 VS Code 用户设置。
5. VS Code：Cmd+Shift+P → Dev Containers: Attach to Running Container → `ai-dev` → 打开 `/workspace/<项目>`。
6. 在终端运行 `claude` 登录：容器内没有浏览器，在 macOS 浏览器中完成授权后把授权码粘回终端。
7. `make check` 全部通过。

### 日常
- Docker Desktop 启动后，容器自动拉起，直接 attach 即可。
- 运行 `claude --dangerously-skip-permissions` 或 `claude --continue`。
- 新项目在 macOS 上或容器内 clone 到 `~/ai-workspace/` 即可，无需重启容器。

## 9. 测试与验收

### `smoke-test`（容器内运行）
- 打印各工具版本：node、corepack、python3、uv、gcc、clang、cmake、ninja、rustc、cargo、go、java、mvn、docker、docker compose、gh、claude。
- 在临时目录中编译并运行 hello world：Node、Python（`uv run`）、C++（CMake + Ninja）、Rust（cargo）、Go、Java（Maven 或 javac）。
- `docker run --rm hello-world`。
- 用 `docker compose` 起一个 postgres，在 `dev` 中通过 `localhost:5432` 连接成功后清理。

### 验收标准
1. `make check` 全部通过。
2. 执行 `make down && docker compose rm -f && make up` 后，Claude 无需重新登录，在同一项目目录中 `claude --continue` 能接上之前的会话。
3. 在容器内能 push 到 Token 授权的仓库；push 到未授权的仓库会失败。
4. 用 SSH 地址 clone 的仓库在容器内能通过 HTTPS + Token push。
5. VS Code attach 后，`ai-dev-check` 仍然全部通过，即 VS Code 没有注入宿主凭据。
6. 在 macOS 上替换 Token 文件后，不重启容器，`git push` 和 `gh` 就会使用新 Token。

## 10. 已知限制与风险
- 容器内数据（工作区代码、Token）可经网络外传（已接受）。
- 嵌套 Docker 依赖 `privileged`，安全边界退到 Docker Desktop VM + File Sharing 列表。
- `dev` 使用 `network_mode: service:docker`：若 `docker` 容器被单独重启，`dev` 会失去网络，需要 `make up` 重建 `dev`。
- `docker:dind` 在无 TLS 的 TCP 监听下的启动行为（警告、可能的延迟）需在实现时确认并处理。
- VS Code Dev Containers 凭据转发相关配置项名称需在实现时核实（见第 5 节）。
- 只验证了 x86_64 Mac。
