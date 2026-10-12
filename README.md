# ai-dev

A Docker development environment for running Claude Code on macOS without giving it access to the rest of your Mac.

- Claude runs in the `ai-dev` container as `ai-coder` and can use `--dangerously-skip-permissions`.
- It sees only `~/ai-workspace` (mounted at `/workspace`) plus its own state in `~/.ai-dev`.
- It pushes to GitHub with fine-grained tokens (one per account or organization) limited to the repositories you choose.
- It can run Docker (databases, etc.) in a nested engine that is separate from your Docker Desktop containers.
- Toolchains: Node.js 24, Python 3.12 + uv, C/C++ (GCC, Clang, CMake, Ninja), Rust, Go, Java 21 + Maven, GitHub CLI.

Design: `docs/superpowers/specs/2026-10-12-ai-dev-container-design.md`.

## What is and is not protected

Protected: files outside `~/ai-workspace` and `~/.ai-dev`, your SSH keys and agent, other credentials on the Mac, GitHub repositories no token covers, and repository CI secrets (the tokens have no Workflows permission).

Not protected: anything inside the container (workspace code, the token) can be sent over the network. Only put projects in `~/ai-workspace` that you are willing to expose to the AI.

## First-time setup

1. **Restrict Docker Desktop File Sharing (required).** Docker Desktop → Settings → Resources → File sharing: remove all entries (`/Users`, `/Volumes`, `/private`, `/tmp`, `/var/folders`) and add `/Users/<you>/ai-workspace` and `/Users/<you>/.ai-dev` (in the folder picker, Cmd+Shift+G lets you type the hidden `.ai-dev` path). The nested Docker engine runs privileged, so this list is the real boundary between the AI and your Mac. Other containers you run that bind-mount paths under `/Users` need their directories added here.
2. **Create GitHub fine-grained tokens**, one per owner (a token covers only one account or organization), at https://github.com/settings/personal-access-tokens/new: Resource owner: the account or organization (organization admins may have to approve it); Only select repositories; Contents: Read and write; Pull requests: Read and write (optional); no Workflows; 90-day expiration.
3. `make setup` in a terminal (it prompts for input) — creates the directories, asks for the git name/email used for commits (also settable later with `git config --global user.name ...` inside the container, which writes to `~/.ai-dev/git/config`), and tells you where to save the tokens: `~/.ai-dev/secrets/github/<owner>`, named after the GitHub account or organization (case-insensitive).
4. `make build && make up`
5. `make check` — must end with `all checks passed`.
6. `make vscode` — opens a dedicated VS Code window. Attaching needs the [Dev Containers](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers) extension (`ms-vscode-remote.remote-containers`); `make vscode` installs it automatically on first run into the dedicated instance's own extensions directory (`~/Library/Application Support/ai-dev-vscode/extensions`), so your normal VS Code gets nothing installed. Then Cmd+Shift+P → **Dev Containers: Attach to Running Container** → `ai-dev`, and open `/workspace/<project>`.
7. In the VS Code terminal run `claude` and log in (open the printed URL in your Mac browser and paste the code back).

Always use `make vscode` to attach, and do not install Dev Containers in your normal VS Code to attach to `ai-dev`: the extension forwards your Mac's SSH agent into the container whenever VS Code has `SSH_AUTH_SOCK` set (macOS sets it for every app), and it has no setting to turn that off. The dedicated instance is started from the app binary without `SSH_AUTH_SOCK` (the `code` command would launch it through macOS `open`, which brings the variable back). Git and Docker credential forwarding are turned off by machine settings baked into the image, and a placeholder `~/.gitconfig` in the image stops the extension from copying your Mac's one. Quit the dedicated instance with Cmd+Q before running `make vscode` again after updating this repo, so it restarts with the current launcher.

## Daily use

- The containers start with Docker Desktop. Run `make vscode` and attach.
- `claude --dangerously-skip-permissions`, or `claude --continue` to resume.
- Put new projects in `~/ai-workspace/` (clone on the Mac or in the container). SSH clone URLs work: the container rewrites them to HTTPS + token.
- Services started with `docker run`/`docker compose` in the container are reachable at `localhost:<port>` from the container and are forwarded to the Mac by VS Code.

## Commands

| Command | What it does |
|---|---|
| `make setup` | Create directories and git identity; explain token setup |
| `make build` | Build the image |
| `make up` / `make down` | Start / stop both containers (volumes are kept) |
| `make shell` | Bash in the container without VS Code |
| `make check` | File Sharing check, isolation check, smoke test |
| `make rebuild` | Rebuild with the latest base images and Claude Code, recreate containers |
| `make vscode` | Open the dedicated VS Code instance (installs Dev Containers into it on first run) |
| `make test-unit` | Run the script unit tests |

## Where things live

| What | Where |
|---|---|
| Projects | `~/ai-workspace` → `/workspace` |
| Claude login, sessions, settings | `~/.ai-dev/claude` |
| Git identity for container commits | `~/.ai-dev/git/config` |
| GitHub tokens | `~/.ai-dev/secrets/github/<owner>`, one per account or organization (add or replace files any time; no restart needed) |
| Package caches, shell history | Docker volumes `ai-dev-*` |
| Nested Docker images/containers | Docker volume `ai-dev-docker-data` (`docker volume rm ai-dev-docker-data` after `make down` wipes it) |
| Dedicated VS Code data | `~/Library/Application Support/ai-dev-vscode` |

## Upgrading

Edit the version `ARG`s at the top of the `Dockerfile` (or nothing, to pick up the latest Claude Code and Rust), then `make rebuild`. Claude Code auto-update is disabled in the container.

## Troubleshooting

- **`dev` has no network after the `engine` container restarted on its own:** run `make up` to recreate `dev`.
- **`make check-host` fails:** File Sharing still includes your home directory; see setup step 1.
- **Push fails with `no token for owner X`:** save a token for that account or organization as `~/.ai-dev/secrets/github/X`.
- **Push fails with 403:** the repository is not selected in that owner's token, the token expired, or the organization has not approved it.
- **`gh` warns it cannot tell the owner:** pass `-R owner/repo`.
