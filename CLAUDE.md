# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Infrastructure for a macOS Docker environment ("ai-dev") in which Claude Code runs isolated from the host. There is no application code: the deliverables are a Dockerfile, a compose stack, host-side scripts behind a Makefile, and in-container helper scripts. The design spec is `docs/superpowers/specs/2026-10-12-ai-dev-container-design.md`; read it before changing behavior.

## Commands

- `make test-unit` — run all script unit tests (`tests/test-*.sh`) in a throwaway `buildpack-deps:noble-scm` container.
- Run one test file: `tar --no-xattrs -c scripts tests vscode | docker run --rm -i buildpack-deps:noble-scm bash -c 'mkdir -p /src && cd /src && tar -x && bash tests/test-ai-dev-check.sh'`
- `make build` / `make up` / `make check` — build the image, start the stack, run the File Sharing check + `ai-dev-check` + `smoke-test`.
- `docker run --rm -e SMOKE_SKIP_DOCKER=1 ai-dev:latest smoke-test` — smoke-test the image without the nested engine.

## Architecture

- `compose.yaml` runs two containers: `ai-dev-engine` (`docker:dind`, privileged, dockerd on `127.0.0.1:2375` only) and `ai-dev` (the `Dockerfile` image, unprivileged, `network_mode: service:engine`). Sharing the network namespace is what lets `dev` reach dockerd and nested containers' published ports on `localhost` without TLS.
- Host state is mounted from `~/.ai-dev/{claude,git,secrets}` as directories, never single files (git writes config by rename; single-file mounts also go stale when macOS editors replace the file).
- GitHub auth: `/etc/gitconfig` (from `config/gitconfig`) registers `scripts/git-credential-ghtoken` for github.com with `useHttpPath = true` and rewrites SSH GitHub URLs to HTTPS. Tokens are per owner (`/run/secrets/ai-dev/github/<owner>`, case-insensitive) because a fine-grained token covers one account or organization; the helper takes the owner from the repo path and replies `quit=1` when it has none. `scripts/gh` wraps `/usr/bin/gh` and picks the owner from `-R`/`--repo`, `GH_REPO`, or `origin` on every call.
- VS Code: the Dev Containers extension forwards the host SSH agent whenever `SSH_AUTH_SOCK` is set and has no setting to stop it, so `scripts/host/ai-code` launches a separate VS Code instance without that variable. It must start `Contents/MacOS/Code` directly: the `code` CLI launches through macOS `open`, which restores launchd's `SSH_AUTH_SOCK`. The credential-helper settings are machine-scoped, so they live in the image (`config/vscode-machine-settings.json` → `~/.vscode-server/data/Machine/settings.json`), not in host user settings; a placeholder `~/.gitconfig` with a section (`config/home-gitconfig`) blocks the host gitconfig copy and `GIT_CONFIG_GLOBAL` points git at the mounted `~/.config/git/config`. Those settings do not close the extension's IPC socket (`/tmp/vscode-remote-containers-ipc-*.sock`), which answers credential requests by asking the Mac, so `ai-code` also starts the instance with `GIT_CONFIG_NOSYSTEM=1` and `GIT_CONFIG_GLOBAL=/dev/null` (no git credential helper on the Mac side). Docker credentials stay reachable through it; the README tells the user not to `docker login` on the Mac. `ai-dev-check` probes the socket. `scripts/ai-dev-check` is the authority on whether any host credential leaked in.
- Scripts take `AI_DEV_*` environment overrides (token path, mountinfo path, etc.) so tests can run them against fixtures.

## Rules that are easy to break

- Docker Desktop File Sharing is restricted to `~/ai-workspace` and `~/.ai-dev`, so this repo cannot be bind-mounted into containers. Stream files in with `tar` as `make test-unit` does.
- Never add a mount of `/var/run/docker.sock`, the host's `~/.claude`, `~/.gitconfig` or `~/.ssh`, and never make `dev` privileged.
- Install toolchains outside `/home/ai-coder` (except Claude Code and the Rust homes) so volume mounts cannot shadow them; pre-create every volume mount point in the Dockerfile as `ai-coder`.
- Ubuntu 24.04 ships user `ubuntu` with UID 1000; the Dockerfile deletes it before creating `ai-coder`.
- Makefile recipes must be indented with tabs.
- All docs, comments and script output are in English.
