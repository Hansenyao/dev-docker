# AI Dev Container Design (ai-dev)

Date: 2026-10-12
Status: Pending review

## 1. Goals and Scope

### Goal
Provide a long-running Docker development environment on macOS in which Claude Code works on multiple projects in `--dangerously-skip-permissions` mode, while keeping all macOS data outside `~/ai-workspace` invisible to the AI.

### Workflow
1. Project code is cloned or created on macOS under `~/ai-workspace/`, which is mounted as `/workspace` in the container.
2. The container runs continuously via `docker compose`; the image ships with the development toolchains and Claude Code preinstalled.
3. VS Code on macOS connects via **Dev Containers: Attach to Running Container**, opens `/workspace/<project>`, and the user logs in to and runs Claude from the VS Code terminal.
4. The AI can `git commit` / `git push` directly from inside the container.
5. The AI can use an independent nested Docker engine inside the environment (e.g. to run databases), isolated from the other containers in Docker Desktop.

### Threat Model

| Risk | Mitigated? | How |
|---|---|---|
| AI accidentally deletes or modifies macOS files outside the project directory | Yes | Mount only `~/ai-workspace` and `~/.ai-dev`; restrict Docker Desktop File Sharing |
| AI reads sensitive macOS data (`~/.ssh`, `~/.aws`, browser data, wallets, etc.) | Yes | Same as above; disable VS Code SSH agent / git credential / Docker credential forwarding |
| AI accesses all of the user's GitHub repositories under their identity | Yes | Provide only a Fine-grained Token scoped to selected repositories |
| Data inside the container (workspace code, token) is exfiltrated over the network | **No** (accepted) | No egress filtering; damage limited by token least privilege and revocability |
| AI modifies CI to read repository Actions secrets | Yes | Token is not granted the Workflows permission |

### Non-goals
- Egress network allowlisting.
- AI agents other than Claude Code.
- Apple Silicon (arm64) support: only verified on Intel Mac (x86_64) + Docker Desktop.
- GitHub-side configuration (e.g. branch protection on `main`): recommended in the README but out of scope for this project.

## 2. Architecture

```
macOS
├── ~/ai-workspace/            ──bind──▶ /workspace                      (dev, docker)
├── ~/.ai-dev/claude/          ──bind──▶ /home/ai-coder/.claude          (dev)
├── ~/.ai-dev/git/             ──bind──▶ /home/ai-coder/.config/git      (dev)
└── ~/.ai-dev/secrets/ (ro)    ──bind──▶ /run/secrets/ai-dev             (dev)

Docker Desktop VM (File Sharing limited to ~/ai-workspace and ~/.ai-dev)
└── compose project ai-dev
    ├── service docker   (docker:dind, privileged)
    │     dockerd listens on 127.0.0.1:2375; /var/lib/docker → volume ai-dev-docker-data
    └── service dev      (custom image, unprivileged, network_mode: service:docker)
          default user ai-coder; DOCKER_HOST=tcp://127.0.0.1:2375
```

- `dev` and `docker` share a network namespace: ports published by nested containers are reachable from `dev` at `localhost:<port>`. dockerd listens only on loopback, so no TLS is configured.
- `dev` waits for dockerd via `depends_on: condition: service_healthy`.
- No ports are published to the host; dev server ports are forwarded to macOS by VS Code.

## 3. Image (Dockerfile)

- Base image: `ubuntu:24.04`, platform `linux/amd64`.
- All versions are declared as `ARG`s at the top of the Dockerfile so an upgrade is a one-line change.
- Toolchains are installed under `/usr/local`, `/opt`, or system paths — **not under home** — so mounts cannot shadow them.

### Base packages
`git curl wget ca-certificates gnupg jq ripgrep fd-find tree vim less unzip zip htop sudo locales tzdata procps build-essential pkg-config`

### User
- `ai-coder`, UID/GID 1000, bash shell, passwordless sudo (`/etc/sudoers.d/ai-coder`), default image user.
- Rationale: Claude Code refuses `--dangerously-skip-permissions` as root; sudo lets the AI `apt install` what it needs.

### Languages and tools

| Item | Version | Install method | Location |
|---|---|---|---|
| Node.js | 24 LTS | Official binary tarball; `corepack` enabled (pnpm, yarn) | `/usr/local` |
| Python | System 3.12 + `uv` | apt + official uv binary | `/usr/bin`, `/usr/local/bin` |
| C++ | GCC 13, Clang 18, CMake, Ninja, GDB, ccache | apt | system |
| Rust | stable + rustfmt, clippy, rust-analyzer | rustup; `RUSTUP_HOME=/opt/rustup`, `CARGO_HOME=/opt/cargo`, owned by ai-coder | `/opt` |
| Go | Latest stable at build time (pinned via ARG) | Official tarball; `GOPATH=/home/ai-coder/go` | `/usr/local/go` |
| Java | Temurin JDK 21 + Maven | Adoptium apt repo + apt; Gradle via each project's `gradlew` | system |
| Docker client | CLI + compose plugin + buildx (no dockerd) | Docker official apt repo | system |
| GitHub CLI | Latest | GitHub official apt repo; real binary at `/usr/bin/gh` | system |
| Claude Code | Latest at build time | Official native installer, run as ai-coder | `~/.local/bin` |

### Environment variables
- `CLAUDE_CONFIG_DIR=/home/ai-coder/.claude`: puts `.claude.json` (onboarding, project trust, MCP config) inside the mounted directory too.
- `DISABLE_AUTOUPDATER=1`: keeps the in-container Claude version consistent with the image; upgrade via `make rebuild`.
- `DOCKER_HOST=tcp://127.0.0.1:2375`
- `PATH` includes `/home/ai-coder/.local/bin`, `/opt/cargo/bin`, `/usr/local/go/bin`, `/home/ai-coder/go/bin`.
- `HISTFILE=/home/ai-coder/.history/bash_history`

### Pre-created directories
Every named-volume mount point is created in the image and `chown`ed to ai-coder, so newly created volumes inherit the correct ownership.

### Size and build time
Expected image size 4–5 GB; first build 10–20 minutes.

## 4. Persistence

| Content | Host location / volume | Container path | Notes |
|---|---|---|---|
| Project code | `~/ai-workspace` | `/workspace` | Mounted in both `dev` and `docker` at the same path |
| Claude state | `~/.ai-dev/claude` | `/home/ai-coder/.claude` | Sessions, login, settings, `.claude.json` |
| Git global config | `~/.ai-dev/git` | `/home/ai-coder/.config/git` | Git reads the XDG `config` as global config |
| GitHub token | `~/.ai-dev/secrets/github-token` | `/run/secrets/ai-dev/github-token` | Directory mounted read-only |
| General cache (pip, uv, go-build, etc.) | volume `ai-dev-cache` | `/home/ai-coder/.cache` | |
| npm cache | volume `ai-dev-npm` | `/home/ai-coder/.npm` | |
| Cargo registry | volume `ai-dev-cargo-registry` | `/opt/cargo/registry` | |
| Go module cache | volume `ai-dev-gomod` | `/home/ai-coder/go/pkg/mod` | |
| Maven repository | volume `ai-dev-m2` | `/home/ai-coder/.m2` | |
| Shell history | volume `ai-dev-history` | `/home/ai-coder/.history` | |
| Nested Docker data | volume `ai-dev-docker-data` | `/var/lib/docker` (docker service) | Delete the volume to wipe it |

Design notes:
- Git config and the token are mounted as **directories**, not single files. Git writes config via rename, which fails on a single-file bind mount; and when a macOS editor replaces a file, a single-file mount keeps pointing at the old inode, so a rotated token would not take effect.
- `~/.ai-dev` lives outside `~/ai-workspace` so the token cannot be accidentally committed into a project.
- **Never mount** the host's own `~/.claude`, `~/.gitconfig`, or `~/.ssh`.
- Claude stores sessions by project path; `/workspace/<project>` is stable across rebuilds, so `claude --continue` survives container recreation.

## 5. Credentials and Security

### GitHub token
- macOS file `~/.ai-dev/secrets/github-token`, mode 600.
- `/usr/local/bin/git-credential-ghtoken`: on a `get` request for `github.com`, outputs `username=x-access-token` and `password=<file contents>`; exits with an error if the file is missing or empty.
- `/etc/gitconfig` (system level, unaffected by VS Code or user global config):
  ```
  [credential "https://github.com"]
      helper = ghtoken
  [url "https://github.com/"]
      insteadOf = git@github.com:
      insteadOf = ssh://git@github.com/
  ```
  Effect: repositories cloned on macOS with SSH URLs transparently use HTTPS + token inside the container.
- `/usr/local/bin/gh` wrapper: reads the token from the file into `GH_TOKEN` on every invocation, then `exec /usr/bin/gh`. Token rotation takes effect immediately and does not depend on shell startup files.

### Recommended token permissions (documented in README)
- Repository access: Only select repositories
- Contents: Read and write
- Pull requests: Read and write (optional, for `gh pr create`)
- Metadata: Read (required)
- **No Workflows permission**
- Expiration: 90 days

### VS Code credential forwarding
Verified against the Dev Containers extension 0.470.0 source:
- Settings exist for git config copying (`dev.containers.copyGitConfig`), the git credential helper (`dev.containers.gitCredentialHelperConfigLocation`), and the Docker credential helper (`dev.containers.dockerCredentialHelper`).
- **There is no setting for SSH agent forwarding.** The extension forwards the agent whenever the VS Code process environment has a non-empty `SSH_AUTH_SOCK`, and on macOS launchd sets it for every GUI app.
- GPG agent forwarding happens only if the host has a gpg agent; the host currently has no gpg installed.

Therefore the AI environment uses a **dedicated VS Code instance** instead of the user's normal one:
- `scripts/host/ai-code` launches VS Code with `SSH_AUTH_SOCK` removed from the environment and with its own `--user-data-dir` and `--extensions-dir` under `~/Library/Application Support/ai-dev-vscode/` (outside the File Sharing list, so the AI cannot reach it even after a VM escape).
- On launch it installs the Dev Containers extension into that extensions dir if missing and writes `vscode/settings.json` into that instance's user settings: `copyGitConfig: false`, `gitCredentialHelperConfigLocation: "none"`, `dockerCredentialHelper: false`, `githubCLILoginWithToken: false`.
- The user's normal VS Code, its settings, and its SSH agent behavior are untouched. The dedicated instance runs alongside it as a separate window.
- `ai-dev-check` remains the authority on whether any credential was forwarded.

### `ai-dev-check` (runs in the container)
Prints FAIL and exits non-zero if any of these does not hold:
- `SSH_AUTH_SOCK` is empty, or `ssh-add -l` lists no keys;
- `git config --show-origin --get-all credential.helper` contains only `ghtoken` from `/etc/gitconfig`;
- No VS Code–injected git/Docker credential environment variables or sockets exist (e.g. credential helpers tied to `REMOTE_CONTAINERS_IPC`, `/tmp/vscode-ssh-auth-*`);
- No host bind mounts exist other than `/workspace`, `/home/ai-coder/.claude`, `/home/ai-coder/.config/git`, `/run/secrets/ai-dev` (parsed from `/proc/self/mountinfo`);
- The token file exists and is non-empty.

### Container configuration
- `dev`: `container_name: ai-dev`; unprivileged; no `/var/run/docker.sock` mount; no host networking; default Docker capabilities retained; no `no-new-privileges` (it would break sudo); `init: true`; command `sleep infinity`; `restart: unless-stopped`.
- `docker`: `container_name: ai-dev-docker`; `privileged: true` (required for nested Docker); mounts only `~/ai-workspace` and `ai-dev-docker-data`, **not** `~/.ai-dev`; dockerd listens only on `tcp://127.0.0.1:2375`; healthcheck `docker -H tcp://127.0.0.1:2375 info`; `restart: unless-stopped`.

### Docker Desktop File Sharing (required)
- Why: the AI can run a `--privileged` container in the nested Docker, escape into the `docker` container, and from there into the Docker Desktop VM. The boundary then falls back to the VM, and the host directories the VM can reach are exactly the File Sharing list.
- How: Docker Desktop → Settings → Resources → File sharing — keep only `~/ai-workspace` and `~/.ai-dev`; remove the defaults such as `/Users`, `/Volumes`, `/private`, `/tmp`, `/var/folders`.
- Impact: other local containers that bind-mount paths under `/Users/...` need their directories added back to the list.
- Accepted residual risk: after escaping into the VM, the AI could see data of other containers and volumes in Docker Desktop.

## 6. Repository Layout

```
dev-docker/
├── Dockerfile
├── compose.yaml
├── Makefile
├── scripts/
│   ├── git-credential-ghtoken
│   ├── gh                      # gh wrapper
│   ├── ai-dev-check
│   ├── smoke-test
│   └── host/ai-code            # macOS: dedicated VS Code launcher
├── vscode/settings.json        # user settings for the dedicated VS Code instance
├── docs/superpowers/specs/     # this file
├── README.md
└── CLAUDE.md
```

## 7. Commands (Makefile, run on macOS)

| Command | Behavior |
|---|---|
| `make setup` | Creates `~/ai-workspace` and `~/.ai-dev/{claude,git,secrets}`; interactively writes `user.name`/`user.email` to `~/.ai-dev/git/config` (skipped if present); if the token file is missing, explains how to create it and sets mode 600; reminds the user to restrict File Sharing |
| `make build` | Builds the image |
| `make up` | `docker compose up -d`; first checks that mount sources such as `~/.ai-dev/git` and `~/.ai-dev/secrets` exist, and asks the user to run `make setup` if not |
| `make down` | `docker compose down` (volumes are kept) |
| `make shell` | Opens a bash shell in `dev` as ai-coder |
| `make check` | Host side: `docker run --rm -v "$HOME:/probe:ro" alpine true` **must fail** with Docker Desktop's "not shared from the host" error; in container: runs `ai-dev-check` and `smoke-test` |
| `make vscode` | Runs `scripts/host/ai-code`: opens the dedicated VS Code instance (installs the Dev Containers extension on first run) |
| `make rebuild` | `build --pull`, then `up -d --force-recreate`; persisted data is unaffected |

## 8. Usage

### First time
1. Restrict Docker Desktop File Sharing.
2. Create a Fine-grained Token on GitHub.
3. `make setup` → `make build` → `make up`.
4. `make vscode` to open the dedicated VS Code instance.
5. In that instance: Cmd+Shift+P → Dev Containers: Attach to Running Container → `ai-dev` → open `/workspace/<project>`.
6. Run `claude` in the terminal to log in: there is no browser in the container, so complete authorization in the macOS browser and paste the code back into the terminal.
7. `make check` passes.

### Day to day
- The containers start automatically with Docker Desktop; run `make vscode` and attach (always use the dedicated instance, never the normal VS Code, to connect to `ai-dev`).
- Run `claude --dangerously-skip-permissions` or `claude --continue`.
- Clone new projects into `~/ai-workspace/` from macOS or from inside the container; no restart needed.

## 9. Testing and Acceptance

### `smoke-test` (runs in the container)
- Prints versions: node, corepack, python3, uv, gcc, clang, cmake, ninja, rustc, cargo, go, java, mvn, docker, docker compose, gh, claude.
- Builds and runs a hello world in a temp directory: Node, Python (`uv run`), C++ (CMake + Ninja), Rust (cargo), Go, Java (Maven or javac).
- `docker run --rm hello-world`.
- Starts postgres with `docker compose`, connects from `dev` via `localhost:5432`, then cleans up.

### Acceptance criteria
1. `make check` passes.
2. After `make down && docker compose rm -f && make up`, Claude needs no re-login and `claude --continue` resumes the previous session in the same project directory.
3. Push to a token-authorized repository succeeds from the container; push to an unauthorized repository fails.
4. A repository cloned with an SSH URL can push from the container via HTTPS + token.
5. After VS Code attaches, `ai-dev-check` still passes, i.e. VS Code injected no host credentials.
6. After replacing the token file on macOS, without restarting the container, `git push` and `gh` use the new token.

## 10. Known Limitations and Risks
- Data inside the container (workspace code, token) can be exfiltrated over the network (accepted).
- Nested Docker requires `privileged`; the security boundary falls back to the Docker Desktop VM + File Sharing list.
- `dev` uses `network_mode: service:docker`: if the `docker` container is restarted on its own, `dev` loses networking and must be recreated with `make up`.
- Docker 29 `dockerd` refuses a plain-TCP listener unless `--tls=false` is passed explicitly; the `docker` service command passes it (the dind entrypoint does not add its own defaults when the command starts with `dockerd`).
- Attaching to `ai-dev` from the normal VS Code instance would forward the macOS SSH agent; the README must say to use `make vscode` only. If gpg is installed on macOS later, GPG agent forwarding must be re-checked with `ai-dev-check`.
- Only verified on x86_64 Macs.
