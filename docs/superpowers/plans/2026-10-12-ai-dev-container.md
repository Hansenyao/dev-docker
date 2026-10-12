# AI Dev Container Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a long-running Docker environment on macOS where Claude Code works on projects in `~/ai-workspace` with no access to other host files or credentials, can push to GitHub with a scoped token, and can use an isolated nested Docker engine.

**Architecture:** A compose project `ai-dev` with two services: `docker` (official `docker:dind`, privileged, dockerd on loopback TCP) and `dev` (custom Ubuntu 24.04 image, unprivileged, sharing `docker`'s network namespace). Host-side shell scripts behind a Makefile handle setup, checks, and launching a dedicated VS Code instance with no SSH agent. In-container shell scripts provide the git credential helper, a `gh` wrapper, an isolation self-check, and a smoke test.

**Tech Stack:** Docker Desktop 29 (macOS, x86_64), Docker Compose, Bash, GNU Make, Ubuntu 24.04, docker:29.9.0-dind, VS Code + Dev Containers extension.

**Spec:** `docs/superpowers/specs/2026-10-12-ai-dev-container-design.md`

## Global Constraints

- All file contents (docs, comments, messages printed by scripts) are in English.
- Host: Intel Mac (x86_64), Docker Desktop. Image platform `linux/amd64` only.
- Base image `ubuntu:24.04`; versions pinned as `ARG`s at the top of the Dockerfile: Node `24.21.0`, Go `1.27.2`, uv `0.13.0`, Maven `3.9.16`, Java `21` (Temurin). Nested engine image `docker:29.9.0-dind`.
- Default container user `ai-coder`, UID/GID 1000, passwordless sudo. Ubuntu 24.04 ships a `ubuntu` user with UID 1000 that must be removed first.
- Toolchains are installed outside `/home/ai-coder` except Claude Code (`~/.local/bin`) and Rust homes (`/opt/rustup`, `/opt/cargo`, owned by ai-coder).
- Host paths: workspace `~/ai-workspace` → `/workspace`; state `~/.ai-dev/{claude,git,secrets}` → `/home/ai-coder/.claude`, `/home/ai-coder/.config/git`, `/run/secrets/ai-dev` (read-only). Token file: `~/.ai-dev/secrets/github-token`.
- Never mount `/var/run/docker.sock`, the host's `~/.claude`, `~/.gitconfig`, or `~/.ssh`. `dev` is never privileged.
- Container names: `ai-dev` (dev), `ai-dev-docker` (dind). Named volumes are prefixed `ai-dev-`.
- Dedicated VS Code data lives in `~/Library/Application Support/ai-dev-vscode/` (outside File Sharing).
- Docker Desktop File Sharing is restricted to `~/ai-workspace` and `~/.ai-dev`. Consequence for this repo: **never bind-mount the repo into a container** (tests are streamed in with `tar`).
- Makefile recipe lines must be indented with a real TAB character.
- Every commit message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. A token pasted with a trailing newline, CRLF, or spaces (`pbpaste > file`) must still authenticate → helper and `gh` wrapper strip all whitespace (tests in Task 1 and Task 2).
2. Docker Desktop restart (or Mac reboot) must bring back both containers with `dev` networked to the nested engine → manual restart check in Task 8.
3. Running `make up` before `make setup` must fail with a clear "run make setup" message instead of Docker creating root-owned or missing mount sources → test step in Task 7.
4. The dedicated VS Code directory path contains a space (`Application Support`) → `ai-code` must quote every path (test with a spaced directory in Task 5).
5. Repositories cloned on macOS with `git@github.com:` or `ssh://git@github.com/` URLs must push over HTTPS + token from the container → `insteadOf` checks in the smoke test (Task 6).

---

## File Map

| File | Responsibility |
|---|---|
| `tests/lib.sh` | Assertion helpers for shell tests |
| `tests/run.sh` | Runs all `tests/test-*.sh` |
| `tests/test-*.sh` | Unit tests for each script |
| `scripts/git-credential-ghtoken` | Git credential helper serving the mounted token |
| `scripts/gh` | `gh` wrapper loading the token into `GH_TOKEN` |
| `scripts/ai-dev-check` | In-container isolation self-check |
| `scripts/smoke-test` | In-container toolchain + nested Docker smoke test |
| `scripts/host/setup` | macOS first-time setup |
| `scripts/host/check-file-sharing` | macOS check that File Sharing is restricted |
| `scripts/host/ai-code` | macOS launcher for the dedicated VS Code instance |
| `vscode/settings.json` | User settings for the dedicated VS Code instance |
| `config/gitconfig` | Installed as `/etc/gitconfig` in the image |
| `config/profile.sh` | Installed as `/etc/profile.d/ai-dev.sh` (PATH for login shells) |
| `Dockerfile`, `.dockerignore` | The `dev` image |
| `compose.yaml` | The two services and volumes |
| `Makefile` | Host entry points |
| `README.md`, `CLAUDE.md` | User docs and agent guidance |

---

### Task 1: Test harness and git credential helper

**Files:**
- Create: `tests/lib.sh`, `tests/run.sh`, `tests/test-git-credential-ghtoken.sh`, `scripts/git-credential-ghtoken`, `Makefile`

**Interfaces:**
- Produces: `tests/lib.sh` functions `pass NAME`, `fail NAME [DETAIL]`, `assert_eq NAME EXPECTED ACTUAL`, `assert_contains NAME HAYSTACK NEEDLE`, `assert_not_contains NAME HAYSTACK NEEDLE`, `finish` (prints summary, returns non-zero if any failure). `make test-unit` runs all tests in `buildpack-deps:noble-scm` (Ubuntu 24.04 + git) by streaming `scripts/` and `tests/` via tar.
- Produces: `scripts/git-credential-ghtoken get` reads git credential input on stdin; for `host=github.com` prints `username=x-access-token` and `password=<token>`; token path from `AI_DEV_TOKEN_FILE` (default `/run/secrets/ai-dev/github-token`).

- [ ] **Step 1: Write the test helpers and runner**

`tests/lib.sh`:
```bash
# Minimal assertion helpers for shell tests. Source this file, call the
# assert_* functions, and end the test file with `finish`.
TESTS_RUN=0
TESTS_FAILED=0

pass() {
  TESTS_RUN=$((TESTS_RUN + 1))
  printf 'ok   %s\n' "$1"
}

fail() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf 'FAIL %s\n' "$1"
  if [ -n "${2:-}" ]; then printf '     %s\n' "$2"; fi
}

assert_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$2], got [$3]"; fi
}

assert_contains() {
  case "$2" in
    *"$3"*) pass "$1" ;;
    *) fail "$1" "[$2] does not contain [$3]" ;;
  esac
}

assert_not_contains() {
  case "$2" in
    *"$3"*) fail "$1" "[$2] unexpectedly contains [$3]" ;;
    *) pass "$1" ;;
  esac
}

finish() {
  printf '%d run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
  [ "$TESTS_FAILED" -eq 0 ]
}
```

`tests/run.sh`:
```bash
#!/usr/bin/env bash
# Runs every tests/test-*.sh and exits non-zero if any of them fails.
set -u
cd "$(dirname "$0")/.."
status=0
for t in tests/test-*.sh; do
  echo "== $t"
  bash "$t" || status=1
done
exit "$status"
```

`Makefile` (recipe lines indented with TAB):
```make
# Host-side entry points for the ai-dev container. Run these on macOS.
SHELL := /bin/bash
TEST_IMAGE := buildpack-deps:noble-scm

.PHONY: test-unit

# Tests are streamed into a throwaway container with tar because Docker
# Desktop File Sharing does not include this repository.
test-unit:
	tar -c scripts tests | docker run --rm -i $(TEST_IMAGE) bash -c 'mkdir -p /src && cd /src && tar -x && bash tests/run.sh'
```

- [ ] **Step 2: Write the failing test**

`tests/test-git-credential-ghtoken.sh`:
```bash
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
helper="$(dirname "$0")/../scripts/git-credential-ghtoken"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

printf 'ghp_test123\n' > "$tmp/token"
request() { printf 'protocol=https\nhost=%s\n\n' "$1"; }

out="$(request github.com | AI_DEV_TOKEN_FILE="$tmp/token" bash "$helper" get)"
assert_eq "get for github.com returns the token" \
  "$(printf 'username=x-access-token\npassword=ghp_test123')" "$out"

out="$(request gitlab.com | AI_DEV_TOKEN_FILE="$tmp/token" bash "$helper" get)"
assert_eq "get for another host returns nothing" "" "$out"

out="$(request github.com | AI_DEV_TOKEN_FILE="$tmp/token" bash "$helper" store)"
assert_eq "store is ignored" "" "$out"

out="$(request github.com | AI_DEV_TOKEN_FILE="$tmp/token" bash "$helper" erase)"
assert_eq "erase is ignored" "" "$out"

printf '  ghp_spaced \r\n' > "$tmp/messy"
out="$(request github.com | AI_DEV_TOKEN_FILE="$tmp/messy" bash "$helper" get)"
assert_eq "whitespace and CRLF are stripped" \
  "$(printf 'username=x-access-token\npassword=ghp_spaced')" "$out"

out="$(printf 'protocol=https\nhost=github.com' | AI_DEV_TOKEN_FILE="$tmp/token" bash "$helper" get)"
assert_contains "input without trailing blank line works" "$out" "password=ghp_test123"

: > "$tmp/empty"
if request github.com | AI_DEV_TOKEN_FILE="$tmp/empty" bash "$helper" get >/dev/null 2>"$tmp/err"; then
  fail "empty token file is an error"
else
  assert_contains "empty token file is an error" "$(cat "$tmp/err")" "missing or empty"
fi

if request github.com | AI_DEV_TOKEN_FILE="$tmp/nope" bash "$helper" get >/dev/null 2>"$tmp/err"; then
  fail "missing token file is an error"
else
  assert_contains "missing token file is an error" "$(cat "$tmp/err")" "missing or empty"
fi

finish
```

- [ ] **Step 3: Run test to verify it fails**

Run: `make test-unit`
Expected: FAIL lines (helper file does not exist: `bash: .../git-credential-ghtoken: No such file or directory`), runner exits non-zero.

- [ ] **Step 4: Write the helper**

`scripts/git-credential-ghtoken`:
```bash
#!/usr/bin/env bash
# Git credential helper that serves the GitHub token mounted from macOS.
# /etc/gitconfig registers it as `helper = ghtoken` for https://github.com.
# Only `get` is answered; `store` and `erase` are ignored because the token
# file belongs to the host and is mounted read-only.
set -euo pipefail

token_file="${AI_DEV_TOKEN_FILE:-/run/secrets/ai-dev/github-token}"

[ "${1:-}" = "get" ] || exit 0

host=""
while IFS= read -r line || [ -n "$line" ]; do
  [ -z "$line" ] && break
  case "$line" in
    host=*) host="${line#host=}" ;;
  esac
done

[ "$host" = "github.com" ] || exit 0

if [ ! -s "$token_file" ]; then
  echo "git-credential-ghtoken: token file $token_file is missing or empty" >&2
  exit 1
fi

token="$(tr -d '[:space:]' < "$token_file")"
printf 'username=x-access-token\npassword=%s\n' "$token"
```
Then: `chmod +x scripts/git-credential-ghtoken tests/run.sh`

- [ ] **Step 5: Run tests to verify they pass**

Run: `make test-unit`
Expected: all `ok`, `8 run, 0 failed`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add Makefile tests scripts/git-credential-ghtoken
git commit -m "feat: add git credential helper for the mounted GitHub token

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: gh wrapper

**Files:**
- Create: `scripts/gh`, `tests/test-gh-wrapper.sh`

**Interfaces:**
- Consumes: `tests/lib.sh`, `make test-unit` (Task 1).
- Produces: `/usr/local/bin/gh` (installed in Task 6) that exports `GH_TOKEN` from `AI_DEV_TOKEN_FILE` (default `/run/secrets/ai-dev/github-token`) and execs `AI_DEV_REAL_GH` (default `/usr/bin/gh`).

- [ ] **Step 1: Write the failing test**

`tests/test-gh-wrapper.sh`:
```bash
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
wrapper="$(dirname "$0")/../scripts/gh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/real-gh" <<'EOF'
#!/usr/bin/env bash
printf 'token=[%s] args=[%s]\n' "${GH_TOKEN:-}" "$*"
EOF
chmod +x "$tmp/real-gh"

printf ' ghp_wrapped\r\n' > "$tmp/token"
out="$(AI_DEV_TOKEN_FILE="$tmp/token" AI_DEV_REAL_GH="$tmp/real-gh" bash "$wrapper" pr list --limit 1)"
assert_eq "passes the trimmed token and all args" "token=[ghp_wrapped] args=[pr list --limit 1]" "$out"

printf 'ghp_rotated\n' > "$tmp/token"
out="$(AI_DEV_TOKEN_FILE="$tmp/token" AI_DEV_REAL_GH="$tmp/real-gh" bash "$wrapper" auth status)"
assert_contains "reads the token on every call" "$out" "token=[ghp_rotated]"

out="$(AI_DEV_TOKEN_FILE="$tmp/missing" AI_DEV_REAL_GH="$tmp/real-gh" GH_TOKEN= bash "$wrapper" --version 2>"$tmp/err")"
assert_eq "missing token still runs gh" "token=[] args=[--version]" "$out"
assert_contains "missing token warns" "$(cat "$tmp/err")" "missing or empty"

finish
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test-unit`
Expected: FAIL lines in `tests/test-gh-wrapper.sh`; exit non-zero.

- [ ] **Step 3: Write the wrapper**

`scripts/gh`:
```bash
#!/usr/bin/env bash
# Wrapper for the GitHub CLI. Loads the mounted token into GH_TOKEN on every
# call, so a token rotated on macOS takes effect without restarting anything.
set -euo pipefail

token_file="${AI_DEV_TOKEN_FILE:-/run/secrets/ai-dev/github-token}"
real_gh="${AI_DEV_REAL_GH:-/usr/bin/gh}"

if [ -s "$token_file" ]; then
  GH_TOKEN="$(tr -d '[:space:]' < "$token_file")"
  export GH_TOKEN
else
  echo "gh wrapper: token file $token_file is missing or empty; running gh without a token" >&2
fi

exec "$real_gh" "$@"
```
Then: `chmod +x scripts/gh`

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test-unit`
Expected: all `ok`, every test file reports `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add scripts/gh tests/test-gh-wrapper.sh
git commit -m "feat: add gh wrapper that reads the mounted token per call

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Isolation self-check (`ai-dev-check`)

**Files:**
- Create: `scripts/ai-dev-check`, `tests/test-ai-dev-check.sh`

**Interfaces:**
- Consumes: `tests/lib.sh`, `make test-unit`.
- Produces: `ai-dev-check` prints `PASS ...`/`FAIL ...` lines and a summary; exit 0 only if all pass. Overrides for tests: `AI_DEV_TOKEN_FILE`, `AI_DEV_MOUNTINFO` (default `/proc/self/mountinfo`), `AI_DEV_SOCKET_DIR` (default `/tmp`), `AI_DEV_ALLOWED_MOUNTS` (space-separated, default `/workspace /home/ai-coder/.claude /home/ai-coder/.config/git /run/secrets/ai-dev`), `AI_DEV_DOCKER_CONFIG` (default `${DOCKER_CONFIG:-$HOME/.docker}/config.json`), and git's own `GIT_CONFIG_SYSTEM` / `GIT_CONFIG_GLOBAL`.

Checks (spec section 5): `SSH_AUTH_SOCK` unset; no `vscode-ssh-auth-*.sock` in the socket dir; every git credential helper comes from the system gitconfig and is `ghtoken`; Docker config has no `credsStore`/`credHelpers`; every host bind mount (fstype `virtiofs`, `fakeowner`, `grpcfuse`, `fuse.grpcfuse`, `osxfs`) is in the allowed list; token file non-empty.

- [ ] **Step 1: Write the failing test**

`tests/test-ai-dev-check.sh`:
```bash
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
check="$(cd "$(dirname "$0")/.." && pwd)/scripts/ai-dev-check"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/home" "$tmp/sockets" "$tmp/cwd"
printf 'ghp_x\n' > "$tmp/token"
printf '[credential "https://github.com"]\n\thelper = ghtoken\n' > "$tmp/system-gitconfig"
: > "$tmp/global-gitconfig"
cat > "$tmp/mountinfo" <<'EOF'
101 100 0:39 /hansenyao/ai-workspace /workspace rw,relatime - virtiofs virtiofs0 rw
102 100 0:39 /hansenyao/.ai-dev/claude /home/ai-coder/.claude rw,relatime - virtiofs virtiofs0 rw
103 100 0:39 /hansenyao/.ai-dev/git /home/ai-coder/.config/git rw,relatime - virtiofs virtiofs0 rw
104 100 0:39 /hansenyao/.ai-dev/secrets /run/secrets/ai-dev ro,relatime - virtiofs virtiofs0 rw
105 100 254:1 /docker/containers/abc/hosts /etc/hosts rw,relatime - ext4 /dev/vda1 rw
EOF

# Runs the check against the fixtures; extra VAR=value args override them.
run_check() {
  (cd "$tmp/cwd" && env -u SSH_AUTH_SOCK \
    HOME="$tmp/home" \
    GIT_CONFIG_SYSTEM="$tmp/system-gitconfig" \
    GIT_CONFIG_GLOBAL="$tmp/global-gitconfig" \
    AI_DEV_TOKEN_FILE="$tmp/token" \
    AI_DEV_MOUNTINFO="$tmp/mountinfo" \
    AI_DEV_SOCKET_DIR="$tmp/sockets" \
    "$@" bash "$check")
}

out="$(run_check)"; status=$?
assert_eq "clean environment passes" "0" "$status"
assert_not_contains "clean environment has no FAIL lines" "$out" "FAIL"

out="$(run_check SSH_AUTH_SOCK=/tmp/vscode-ssh-auth-1.sock)"; status=$?
assert_eq "SSH_AUTH_SOCK set fails" "1" "$status"
assert_contains "SSH_AUTH_SOCK reported" "$out" "FAIL SSH_AUTH_SOCK is set"

touch "$tmp/sockets/vscode-ssh-auth-abc.sock"
out="$(run_check)"; status=$?
assert_eq "forwarded agent socket fails" "1" "$status"
assert_contains "agent socket reported" "$out" "vscode-ssh-auth-abc.sock"
rm "$tmp/sockets/vscode-ssh-auth-abc.sock"

printf '[credential]\n\thelper = /tmp/vscode-remote-containers-123.js\n' > "$tmp/global-gitconfig"
out="$(run_check)"; status=$?
assert_eq "extra credential helper fails" "1" "$status"
assert_contains "extra helper reported" "$out" "vscode-remote-containers-123.js"
: > "$tmp/global-gitconfig"

: > "$tmp/system-gitconfig"
out="$(run_check)"; status=$?
assert_eq "missing ghtoken helper fails" "1" "$status"
printf '[credential "https://github.com"]\n\thelper = ghtoken\n' > "$tmp/system-gitconfig"

mkdir -p "$tmp/home/.docker"
printf '{"credsStore":"dev-containers-xyz"}\n' > "$tmp/home/.docker/config.json"
out="$(run_check)"; status=$?
assert_eq "docker credsStore fails" "1" "$status"
assert_contains "docker credential reported" "$out" "FAIL Docker credential helper"
rm -rf "$tmp/home/.docker"

cp "$tmp/mountinfo" "$tmp/mountinfo.ok"
echo '106 100 0:39 /hansenyao/.ssh /home/ai-coder/.ssh ro,relatime - virtiofs virtiofs0 rw' >> "$tmp/mountinfo"
out="$(run_check)"; status=$?
assert_eq "unexpected host mount fails" "1" "$status"
assert_contains "unexpected mount reported" "$out" "/home/ai-coder/.ssh"
cp "$tmp/mountinfo.ok" "$tmp/mountinfo"

: > "$tmp/token"
out="$(run_check)"; status=$?
assert_eq "empty token fails" "1" "$status"
assert_contains "token reported" "$out" "FAIL GitHub token"

finish
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test-unit`
Expected: FAIL lines in `tests/test-ai-dev-check.sh` (script missing); exit non-zero.

- [ ] **Step 3: Write the check**

`scripts/ai-dev-check`:
```bash
#!/usr/bin/env bash
# Verifies that this container cannot reach macOS credentials or files beyond
# the intended mounts. Exits non-zero if any check fails.
# See docs/superpowers/specs/2026-10-12-ai-dev-container-design.md, section 5.
set -uo pipefail

token_file="${AI_DEV_TOKEN_FILE:-/run/secrets/ai-dev/github-token}"
mountinfo="${AI_DEV_MOUNTINFO:-/proc/self/mountinfo}"
socket_dir="${AI_DEV_SOCKET_DIR:-/tmp}"
allowed_mounts="${AI_DEV_ALLOWED_MOUNTS:-/workspace /home/ai-coder/.claude /home/ai-coder/.config/git /run/secrets/ai-dev}"
docker_config="${AI_DEV_DOCKER_CONFIG:-${DOCKER_CONFIG:-$HOME/.docker}/config.json}"
system_gitconfig="${GIT_CONFIG_SYSTEM:-/etc/gitconfig}"

failures=0
ok() { printf 'PASS %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; failures=$((failures + 1)); }

# SSH agent forwarding (VS Code forwards it whenever its own SSH_AUTH_SOCK is set).
if [ -n "${SSH_AUTH_SOCK:-}" ]; then
  bad "SSH_AUTH_SOCK is set ($SSH_AUTH_SOCK): an SSH agent may be forwarded"
else
  ok "SSH_AUTH_SOCK is not set"
fi

shopt -s nullglob
agent_sockets=("$socket_dir"/vscode-ssh-auth-*.sock)
shopt -u nullglob
if [ "${#agent_sockets[@]}" -gt 0 ]; then
  bad "forwarded SSH agent sockets exist: ${agent_sockets[*]}"
else
  ok "no forwarded SSH agent sockets in $socket_dir"
fi

# Git credential helpers: only ghtoken from the system gitconfig is allowed.
helpers="$(git config --show-origin --get-regexp '^credential\..*helper$' 2>/dev/null || true)"
if [ -z "$helpers" ]; then
  bad "no git credential helper configured (expected ghtoken in $system_gitconfig)"
else
  unexpected="$(printf '%s\n' "$helpers" | awk -v origin="file:$system_gitconfig" '$1 != origin || $3 != "ghtoken"')"
  if [ -n "$unexpected" ]; then
    bad "unexpected git credential helpers: $unexpected"
  else
    ok "git credential helper is only ghtoken from $system_gitconfig"
  fi
fi

# Docker credential helper injected by VS Code.
if [ -f "$docker_config" ] && grep -qE '"(credsStore|credHelpers)"' "$docker_config"; then
  bad "Docker credential helper configured in $docker_config"
else
  ok "no Docker credential helper"
fi

# Host bind mounts: only the allowed mount points may come from macOS.
host_mounts="$(awk '{
  for (i = 1; i <= NF; i++) if ($i == "-") { fs = $(i + 1); break }
  if (fs ~ /^(virtiofs|fakeowner|grpcfuse|fuse\.grpcfuse|osxfs)$/) print $5
}' "$mountinfo")"
extra=""
for m in $host_mounts; do
  case " $allowed_mounts " in
    *" $m "*) ;;
    *) extra="$extra $m" ;;
  esac
done
if [ -n "$extra" ]; then
  bad "unexpected host mounts:$extra"
else
  ok "host mounts are limited to: $allowed_mounts"
fi

# GitHub token.
if [ -s "$token_file" ]; then
  ok "GitHub token file present"
else
  bad "GitHub token file $token_file is missing or empty"
fi

if [ "$failures" -eq 0 ]; then
  echo "ai-dev-check: all checks passed"
  exit 0
fi
echo "ai-dev-check: $failures check(s) failed"
exit 1
```
Then: `chmod +x scripts/ai-dev-check`

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test-unit`
Expected: all `ok`; every test file reports `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add scripts/ai-dev-check tests/test-ai-dev-check.sh
git commit -m "feat: add ai-dev-check isolation self-check

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Host setup script

**Files:**
- Create: `scripts/host/setup`, `tests/test-setup.sh`

**Interfaces:**
- Consumes: `tests/lib.sh`, `make test-unit`.
- Produces: `scripts/host/setup` (used by `make setup` in Task 7). Creates `~/ai-workspace`, `~/.ai-dev/{claude,git,secrets}` (`~/.ai-dev` and `secrets` mode 700); prompts for `user.name`/`user.email` on stdin only if `~/.ai-dev/git/config` lacks them; sets an existing token file to mode 600 or prints how to create it; prints the File Sharing reminder. Never overwrites an existing identity or token.

- [ ] **Step 1: Write the failing test**

`tests/test-setup.sh`:
```bash
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
setup="$(cd "$(dirname "$0")/.." && pwd)/scripts/host/setup"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

out="$(printf 'Alice Example\nalice@example.com\n' | HOME="$tmp" bash "$setup" 2>&1)"; status=$?
assert_eq "first run succeeds" "0" "$status"
for d in ai-workspace .ai-dev/claude .ai-dev/git .ai-dev/secrets; do
  if [ -d "$tmp/$d" ]; then pass "creates $d"; else fail "creates $d"; fi
done
assert_eq ".ai-dev is mode 700" "700" "$(stat -c %a "$tmp/.ai-dev")"
assert_eq "secrets is mode 700" "700" "$(stat -c %a "$tmp/.ai-dev/secrets")"
assert_eq "writes user.name" "Alice Example" "$(git config --file "$tmp/.ai-dev/git/config" user.name)"
assert_eq "writes user.email" "alice@example.com" "$(git config --file "$tmp/.ai-dev/git/config" user.email)"
assert_contains "explains how to create the token" "$out" "fine-grained"
assert_contains "reminds about File Sharing" "$out" "File sharing"

printf 'ghp_x\n' > "$tmp/.ai-dev/secrets/github-token"
chmod 644 "$tmp/.ai-dev/secrets/github-token"
out="$(HOME="$tmp" bash "$setup" < /dev/null 2>&1)"; status=$?
assert_eq "re-run without input succeeds" "0" "$status"
assert_contains "re-run keeps identity" "$out" "already set"
assert_eq "re-run did not change user.name" "Alice Example" "$(git config --file "$tmp/.ai-dev/git/config" user.name)"
assert_eq "token kept" "ghp_x" "$(cat "$tmp/.ai-dev/secrets/github-token")"
assert_eq "token set to mode 600" "600" "$(stat -c %a "$tmp/.ai-dev/secrets/github-token")"

rm -rf "$tmp/.ai-dev/git/config"
out="$(printf '\n\n' | HOME="$tmp" bash "$setup" 2>&1)"; status=$?
assert_eq "empty identity is rejected" "1" "$status"
assert_contains "empty identity message" "$out" "required"

finish
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test-unit`
Expected: FAIL lines in `tests/test-setup.sh`; exit non-zero.

- [ ] **Step 3: Write the setup script**

`scripts/host/setup`:
```bash
#!/usr/bin/env bash
# First-time host setup for ai-dev (run on macOS via `make setup`).
# Creates the workspace and state directories and the git identity used for
# commits made in the container, and checks for the GitHub token file.
# Safe to re-run: existing identity and token are never overwritten.
set -euo pipefail

workspace="$HOME/ai-workspace"
state="$HOME/.ai-dev"
git_config="$state/git/config"
token_file="$state/secrets/github-token"

mkdir -p "$workspace" "$state/claude" "$state/git" "$state/secrets"
chmod 700 "$state" "$state/secrets"

if git config --file "$git_config" user.name >/dev/null 2>&1 &&
  git config --file "$git_config" user.email >/dev/null 2>&1; then
  echo "Git identity already set in $git_config"
else
  read -r -p "Git user.name for commits made in the container: " name || true
  read -r -p "Git user.email for commits made in the container: " email || true
  if [ -z "${name:-}" ] || [ -z "${email:-}" ]; then
    echo "Both user.name and user.email are required." >&2
    exit 1
  fi
  git config --file "$git_config" user.name "$name"
  git config --file "$git_config" user.email "$email"
  echo "Wrote $git_config"
fi

if [ -s "$token_file" ]; then
  chmod 600 "$token_file"
  echo "GitHub token found at $token_file"
else
  cat <<EOF

No GitHub token yet. Create a fine-grained token at
  https://github.com/settings/personal-access-tokens/new
  - Repository access: Only select repositories (the ones the AI may push to)
  - Contents: Read and write
  - Pull requests: Read and write (optional, for gh pr create)
  - Do NOT grant Workflows
  - Expiration: 90 days
Copy it, then run:
  pbpaste > "$token_file" && chmod 600 "$token_file"
EOF
fi

cat <<EOF

Reminder: Docker Desktop -> Settings -> Resources -> File sharing must list only
  $workspace
  $state
Run 'make check-host' to verify.
EOF
```
Then: `chmod +x scripts/host/setup`

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test-unit`
Expected: every test file reports `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add scripts/host/setup tests/test-setup.sh
git commit -m "feat: add host setup script

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Dedicated VS Code launcher

**Files:**
- Create: `scripts/host/ai-code`, `vscode/settings.json`, `tests/test-ai-code.sh`
- Modify: `Makefile` (stream `vscode/` into the test container)

**Interfaces:**
- Consumes: `tests/lib.sh`, `make test-unit`.
- Produces: `scripts/host/ai-code [ARGS...]` (used by `make vscode` in Task 7). Copies `vscode/settings.json` to `<base>/data/User/settings.json`, installs `ms-vscode-remote.remote-containers` into `<base>/extensions` if absent, then runs `code --new-window ARGS`; every `code` call has `SSH_AUTH_SOCK` removed and passes `--user-data-dir <base>/data --extensions-dir <base>/extensions`. Overrides: `AI_DEV_CODE_BIN` (default `/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code`), `AI_DEV_VSCODE_DIR` (default `$HOME/Library/Application Support/ai-dev-vscode`).

- [ ] **Step 1: Write the settings file**

`vscode/settings.json`:
```json
{
  "dev.containers.copyGitConfig": false,
  "dev.containers.gitCredentialHelperConfigLocation": "none",
  "dev.containers.dockerCredentialHelper": false,
  "dev.containers.githubCLILoginWithToken": false
}
```

- [ ] **Step 2: Include `vscode/` in the unit-test tarball**

In `Makefile`, change the `test-unit` recipe's `tar -c scripts tests` to `tar -c scripts tests vscode`.

- [ ] **Step 3: Write the failing test**

`tests/test-ai-code.sh`:
```bash
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
repo="$(cd "$(dirname "$0")/.." && pwd)"
launcher="$repo/scripts/host/ai-code"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Fake VS Code CLI: logs each call; lists extensions from a state file.
mkdir -p "$tmp/bin dir"
cat > "$tmp/bin dir/code" <<EOF
#!/usr/bin/env bash
printf 'call sock=[%s] args=[%s]\n' "\${SSH_AUTH_SOCK:-}" "\$*" >> "$tmp/log"
if [ "\${*: -1}" = "--list-extensions" ]; then cat "$tmp/extensions" 2>/dev/null; fi
if [[ "\$*" == *"--install-extension ms-vscode-remote.remote-containers"* ]]; then
  echo ms-vscode-remote.remote-containers > "$tmp/extensions"
fi
EOF
chmod +x "$tmp/bin dir/code"
base="$tmp/Application Support/ai-dev-vscode"

run_launcher() {
  SSH_AUTH_SOCK=/private/tmp/launchd-agent AI_DEV_CODE_BIN="$tmp/bin dir/code" \
    AI_DEV_VSCODE_DIR="$base" bash "$launcher" "$@"
}

run_launcher; status=$?
assert_eq "first launch succeeds" "0" "$status"
log="$(cat "$tmp/log")"
assert_not_contains "SSH_AUTH_SOCK never reaches VS Code" "$log" "sock=[/"
assert_contains "uses the dedicated user data dir" "$log" "--user-data-dir $base/data"
assert_contains "uses the dedicated extensions dir" "$log" "--extensions-dir $base/extensions"
assert_contains "installs Dev Containers on first launch" "$log" "--install-extension ms-vscode-remote.remote-containers"
assert_contains "opens a new window" "$log" "--new-window"
assert_eq "writes the settings" "$(cat "$repo/vscode/settings.json")" "$(cat "$base/data/User/settings.json")"

: > "$tmp/log"
run_launcher /some/arg; status=$?
assert_eq "second launch succeeds" "0" "$status"
log="$(cat "$tmp/log")"
assert_not_contains "does not reinstall the extension" "$log" "--install-extension"
assert_contains "forwards extra arguments" "$log" "--new-window /some/arg"

if AI_DEV_CODE_BIN="$tmp/none" AI_DEV_VSCODE_DIR="$base" bash "$launcher" 2>"$tmp/err"; then
  fail "missing VS Code is an error"
else
  assert_contains "missing VS Code message" "$(cat "$tmp/err")" "VS Code CLI not found"
fi

finish
```

- [ ] **Step 4: Run test to verify it fails**

Run: `make test-unit`
Expected: FAIL lines in `tests/test-ai-code.sh`; exit non-zero.

- [ ] **Step 5: Write the launcher**

`scripts/host/ai-code`:
```bash
#!/usr/bin/env bash
# Opens a dedicated VS Code instance for attaching to the ai-dev container.
# The Dev Containers extension forwards the macOS SSH agent whenever its own
# process has SSH_AUTH_SOCK set, and has no setting to turn that off, so this
# instance is started without SSH_AUTH_SOCK. It also uses its own user data
# and extensions directories, leaving the normal VS Code untouched.
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
code_bin="${AI_DEV_CODE_BIN:-/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code}"
base="${AI_DEV_VSCODE_DIR:-$HOME/Library/Application Support/ai-dev-vscode}"
data_dir="$base/data"
ext_dir="$base/extensions"

if [ ! -x "$code_bin" ]; then
  echo "VS Code CLI not found at $code_bin" >&2
  exit 1
fi

mkdir -p "$data_dir/User" "$ext_dir"
cp "$repo_dir/vscode/settings.json" "$data_dir/User/settings.json"

code() {
  env -u SSH_AUTH_SOCK "$code_bin" --user-data-dir "$data_dir" --extensions-dir "$ext_dir" "$@"
}

if ! code --list-extensions | grep -qx 'ms-vscode-remote.remote-containers'; then
  code --install-extension ms-vscode-remote.remote-containers
fi

code --new-window "$@"
```
Then: `chmod +x scripts/host/ai-code`

- [ ] **Step 6: Run tests to verify they pass**

Run: `make test-unit`
Expected: every test file reports `0 failed`.

- [ ] **Step 7: Commit**

```bash
git add Makefile scripts/host/ai-code vscode/settings.json tests/test-ai-code.sh
git commit -m "feat: add dedicated VS Code launcher without SSH agent forwarding

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Dev image and smoke test

**Files:**
- Create: `Dockerfile`, `.dockerignore`, `config/gitconfig`, `config/profile.sh`, `scripts/smoke-test`

**Interfaces:**
- Consumes: `scripts/git-credential-ghtoken`, `scripts/gh`, `scripts/ai-dev-check` (Tasks 1–3).
- Produces: image `ai-dev:latest` with default user `ai-coder`, workdir `/workspace`, `CMD ["sleep", "infinity"]`; `/usr/local/bin/{git-credential-ghtoken,gh,ai-dev-check,smoke-test}`; `smoke-test` exits 0 only if every check passes, and skips the Docker section when `SMOKE_SKIP_DOCKER=1`. Env: `DOCKER_HOST=tcp://127.0.0.1:2375`, `CLAUDE_CONFIG_DIR=/home/ai-coder/.claude`.

- [ ] **Step 1: Write the smoke test (the failing test for this task)**

`scripts/smoke-test`:
```bash
#!/usr/bin/env bash
# Verifies every toolchain in the image works, the git/GitHub wiring is in
# place, and (unless SMOKE_SKIP_DOCKER=1) the nested Docker engine works.
set -uo pipefail

failures=0
work="$(mktemp -d)"
cleanup() {
  if [ -f "$work/pg/compose.yaml" ]; then
    docker compose -p ai-dev-smoke -f "$work/pg/compose.yaml" down -v >/dev/null 2>&1
  fi
  rm -rf "$work"
}
trap cleanup EXIT

section() { printf '\n== %s\n' "$1"; }

# check NAME COMMAND...: runs COMMAND, prints PASS with its first output line or FAIL with all output.
check() {
  local name="$1" out
  shift
  if out="$("$@" 2>&1)"; then
    printf 'PASS %s: %s\n' "$name" "$(printf '%s\n' "$out" | head -n 1)"
  else
    printf 'FAIL %s\n%s\n' "$name" "$out"
    failures=$((failures + 1))
  fi
}

# expect NAME EXPECTED COMMAND...: like check, but stdout must equal EXPECTED.
# stderr is ignored on success (tools like uv log progress there).
expect() {
  local name="$1" want="$2" out
  shift 2
  out="$("$@" 2>"$work/stderr")"
  if [ "$out" = "$want" ]; then
    printf 'PASS %s\n' "$name"
  else
    printf 'FAIL %s: expected [%s], got [%s]\n%s\n' "$name" "$want" "$out" "$(cat "$work/stderr")"
    failures=$((failures + 1))
  fi
}

section "Tool versions"
check node node --version
check pnpm pnpm --version
check python3 python3 --version
check uv uv --version
check gcc gcc --version
check clang clang --version
check cmake cmake --version
check ninja ninja --version
check gdb gdb --version
check rustc rustc --version
check cargo cargo --version
check go go version
check java java -version
check mvn mvn -v
check gh /usr/local/bin/gh --version
check claude claude --version
check docker docker --version
check "docker compose" docker compose version
check psql psql --version

section "Hello world builds"
cd "$work"
expect "node runs" "hello" node -e 'console.log("hello")'
expect "uv runs python with a dependency" "hello" uv run --no-project --with six python -c 'import six; print("hello")'

mkdir -p cpp && cat > cpp/CMakeLists.txt <<'EOF'
cmake_minimum_required(VERSION 3.20)
project(hello CXX)
add_executable(hello main.cpp)
EOF
cat > cpp/main.cpp <<'EOF'
#include <iostream>
int main() { std::cout << "hello" << std::endl; }
EOF
check "cmake configure+build" bash -c 'cmake -S cpp -B cpp/build -G Ninja && cmake --build cpp/build'
expect "c++ binary runs" "hello" ./cpp/build/hello

check "cargo new" cargo new --quiet --vcs none rusthello
expect "rust binary runs" "Hello, world!" cargo run --quiet --manifest-path rusthello/Cargo.toml

mkdir -p gohello && cat > gohello/main.go <<'EOF'
package main

import "fmt"

func main() { fmt.Println("hello") }
EOF
check "go mod init" bash -c 'cd gohello && go mod init example.com/hello'
expect "go runs" "hello" bash -c 'cd gohello && go run .'

mkdir -p java && cat > java/Hello.java <<'EOF'
public class Hello {
  public static void main(String[] args) { System.out.println("hello"); }
}
EOF
check "javac" javac -d java java/Hello.java
expect "java runs" "hello" java -cp java Hello

section "Git and GitHub wiring"
expect "git credential helper registered" "ghtoken" git config --system --get credential.https://github.com.helper
expect "scp-style GitHub URL rewritten to HTTPS" "https://github.com/o/r.git" git ls-remote --get-url git@github.com:o/r.git
expect "ssh:// GitHub URL rewritten to HTTPS" "https://github.com/o/r.git" git ls-remote --get-url ssh://git@github.com/o/r.git
printf 'ghp_smoke\n' > "$work/token"
expect "git credential fill uses the token file" "password=ghp_smoke" bash -c \
  "printf 'protocol=https\nhost=github.com\n\n' | AI_DEV_TOKEN_FILE='$work/token' GIT_TERMINAL_PROMPT=0 git credential fill | grep '^password='"
expect "gh resolves to the wrapper" "/usr/local/bin/gh" command -v gh

if [ "${SMOKE_SKIP_DOCKER:-0}" = "1" ]; then
  section "Nested Docker (skipped: SMOKE_SKIP_DOCKER=1)"
else
  section "Nested Docker"
  check "docker daemon reachable" docker version --format '{{.Server.Version}}'
  check "docker run hello-world" docker run --rm hello-world
  mkdir -p "$work/pg" && cat > "$work/pg/compose.yaml" <<'EOF'
services:
  db:
    image: postgres:17-alpine
    environment:
      POSTGRES_PASSWORD: smoke
    ports:
      - "55432:5432"
EOF
  check "compose up postgres" docker compose -p ai-dev-smoke -f "$work/pg/compose.yaml" up -d --wait
  check "postgres ready on localhost" bash -c \
    'for i in $(seq 1 30); do pg_isready -h localhost -p 55432 && exit 0; sleep 1; done; exit 1'
  expect "postgres query via localhost" "1" env PGPASSWORD=smoke psql -h localhost -p 55432 -U postgres -tAc 'select 1'
fi

printf '\n'
if [ "$failures" -eq 0 ]; then
  echo "smoke-test: all checks passed"
  exit 0
fi
echo "smoke-test: $failures check(s) failed"
exit 1
```
Then: `chmod +x scripts/smoke-test`

- [ ] **Step 2: Write the config files**

`config/gitconfig` (installed as `/etc/gitconfig`):
```ini
# System git config for the ai-dev container.
# GitHub access uses the token mounted at /run/secrets/ai-dev/github-token.
[credential "https://github.com"]
	helper = ghtoken
# Repositories cloned on macOS with SSH URLs push over HTTPS + token here.
[url "https://github.com/"]
	insteadOf = git@github.com:
	insteadOf = ssh://git@github.com/
# Single-user container: files under bind mounts may show a different owner.
[safe]
	directory = *
```

`config/profile.sh` (installed as `/etc/profile.d/ai-dev.sh`; Ubuntu's `/etc/profile` resets PATH for login shells):
```bash
# Restore the ai-dev tool paths for login shells.
export PATH="/home/ai-coder/.local/bin:/opt/cargo/bin:/usr/local/go/bin:/home/ai-coder/go/bin:$PATH"
```

`.dockerignore`:
```
.git
docs
tests
vscode
scripts/host
Makefile
*.md
```

- [ ] **Step 3: Write the Dockerfile**

`Dockerfile`:
```dockerfile
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

WORKDIR /workspace
CMD ["sleep", "infinity"]
```

- [ ] **Step 4: Build the image**

Run: `docker build -t ai-dev:latest .` (10–20 minutes the first time)
Expected: build succeeds. If a step fails, fix that step and rebuild; do not add packages not listed in the spec beyond what a failing step requires.

- [ ] **Step 5: Run the smoke test without nested Docker**

Run: `docker run --rm -e SMOKE_SKIP_DOCKER=1 ai-dev:latest smoke-test`
Expected: every line `PASS`, last line `smoke-test: all checks passed`. (Needs network for pnpm, uv `six`.)

- [ ] **Step 6: Check user, sudo, and login-shell PATH**

Run: `docker run --rm ai-dev:latest bash -c 'id -un; sudo -n true && echo sudo-ok; bash -lc "command -v claude cargo go"'`
Expected:
```
ai-coder
sudo-ok
/home/ai-coder/.local/bin/claude
/opt/cargo/bin/cargo
/usr/local/go/bin/go
```

- [ ] **Step 7: Commit**

```bash
git add Dockerfile .dockerignore config scripts/smoke-test
git commit -m "feat: add dev image with toolchains, Claude Code and smoke test

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Compose stack, Makefile targets, and File Sharing check

**Files:**
- Create: `compose.yaml`, `scripts/host/check-file-sharing`
- Modify: `Makefile`

**Interfaces:**
- Consumes: image build context (Task 6), `scripts/host/setup` (Task 4), `scripts/host/ai-code` (Task 5).
- Produces: `make setup|build|up|down|shell|check|check-host|rebuild|vscode|test-unit`; running containers `ai-dev` and `ai-dev-docker`.

- [ ] **Step 1: Write the File Sharing check**

`scripts/host/check-file-sharing`:
```bash
#!/usr/bin/env bash
# Verifies Docker Desktop File Sharing is restricted to ~/ai-workspace and
# ~/.ai-dev by asking Docker to bind-mount the home directory itself, which
# must be refused.
set -euo pipefail

probe="${1:-$HOME}"

if ! docker info >/dev/null 2>&1; then
  echo "FAIL Docker is not running" >&2
  exit 1
fi

if out="$(docker run --rm -v "$probe:/probe:ro" alpine true 2>&1)"; then
  echo "FAIL Docker can mount $probe. Restrict Docker Desktop -> Settings -> Resources -> File sharing to ~/ai-workspace and ~/.ai-dev." >&2
  exit 1
fi

if printf '%s' "$out" | grep -qi 'not shared from the host'; then
  echo "PASS Docker cannot mount $probe (File Sharing is restricted)"
  exit 0
fi

echo "FAIL could not verify File Sharing; docker said: $out" >&2
exit 1
```
Then: `chmod +x scripts/host/check-file-sharing`

- [ ] **Step 2: Write `compose.yaml`**

```yaml
# ai-dev: AI development container plus an isolated nested Docker engine.
# See docs/superpowers/specs/2026-10-12-ai-dev-container-design.md.
name: ai-dev

services:
  docker:
    image: docker:29.9.0-dind
    container_name: ai-dev-docker
    privileged: true
    restart: unless-stopped
    # Starting the command with `dockerd` stops the entrypoint from adding its
    # default 0.0.0.0 listener. Docker 29 requires --tls=false for plain TCP.
    # Loopback only: reachable from the dev service, which shares this
    # network namespace.
    command: ["dockerd", "--host=unix:///var/run/docker.sock", "--host=tcp://127.0.0.1:2375", "--tls=false"]
    environment:
      DOCKER_TLS_CERTDIR: ""
    volumes:
      # Same path as in dev, so `docker run -v /workspace/...` works.
      - ${HOME}/ai-workspace:/workspace
      - docker-data:/var/lib/docker
    healthcheck:
      test: ["CMD", "docker", "-H", "tcp://127.0.0.1:2375", "info"]
      interval: 5s
      timeout: 5s
      retries: 30
      start_period: 10s

  dev:
    build: .
    image: ai-dev:latest
    container_name: ai-dev
    network_mode: service:docker
    depends_on:
      docker:
        condition: service_healthy
    init: true
    restart: unless-stopped
    volumes:
      - ${HOME}/ai-workspace:/workspace
      - ${HOME}/.ai-dev/claude:/home/ai-coder/.claude
      - ${HOME}/.ai-dev/git:/home/ai-coder/.config/git
      - ${HOME}/.ai-dev/secrets:/run/secrets/ai-dev:ro
      - cache:/home/ai-coder/.cache
      - npm:/home/ai-coder/.npm
      - cargo-registry:/opt/cargo/registry
      - gomod:/home/ai-coder/go/pkg/mod
      - m2:/home/ai-coder/.m2
      - history:/home/ai-coder/.history

volumes:
  docker-data:
    name: ai-dev-docker-data
  cache:
    name: ai-dev-cache
  npm:
    name: ai-dev-npm
  cargo-registry:
    name: ai-dev-cargo-registry
  gomod:
    name: ai-dev-gomod
  m2:
    name: ai-dev-m2
  history:
    name: ai-dev-history
```

- [ ] **Step 3: Replace the Makefile with the full version**

`Makefile` (recipe lines indented with TAB):
```make
# Host-side entry points for the ai-dev container. Run these on macOS.
SHELL := /bin/bash
COMPOSE := docker compose
TEST_IMAGE := buildpack-deps:noble-scm
WORKSPACE := $(HOME)/ai-workspace
STATE := $(HOME)/.ai-dev

.PHONY: setup build up down shell check check-host rebuild vscode test-unit require-setup

setup:
	@scripts/host/setup

build:
	$(COMPOSE) build

up: require-setup
	$(COMPOSE) up -d

down:
	$(COMPOSE) down

shell:
	docker exec -it -u ai-coder -w /workspace ai-dev bash

check: check-host
	docker exec -u ai-coder ai-dev ai-dev-check
	docker exec -u ai-coder ai-dev smoke-test

check-host:
	@scripts/host/check-file-sharing

rebuild: require-setup
	$(COMPOSE) build --pull
	$(COMPOSE) up -d --force-recreate

vscode:
	@scripts/host/ai-code

# Tests are streamed into a throwaway container with tar because Docker
# Desktop File Sharing does not include this repository.
test-unit:
	tar -c scripts tests vscode | docker run --rm -i $(TEST_IMAGE) bash -c 'mkdir -p /src && cd /src && tar -x && bash tests/run.sh'

# Refuse to start without the mount sources; otherwise Docker would create
# them itself (or fail with an unclear error).
require-setup:
	@for d in "$(WORKSPACE)" "$(STATE)/claude" "$(STATE)/git" "$(STATE)/secrets"; do \
	  if [ ! -d "$$d" ]; then echo "Missing $$d - run 'make setup' first." >&2; exit 1; fi; \
	done
```

- [ ] **Step 4: Test `make up` before setup (Review Focus 3)**

Run: `HOME=/tmp/ai-dev-nohome make up; echo "exit=$?"`
Expected: `Missing /tmp/ai-dev-nohome/ai-workspace - run 'make setup' first.` and `exit=2` (make reports the failed recipe). No containers are created (`docker ps -a --filter name=ai-dev` is empty).

- [ ] **Step 5: USER STEP — host setup and File Sharing**

Stop and ask the user to:
1. Run `make setup` in their own terminal (`! make setup` in Claude Code), entering their git name and email.
2. Create the fine-grained token as printed and save it with `pbpaste > ~/.ai-dev/secrets/github-token && chmod 600 ~/.ai-dev/secrets/github-token`.
3. In Docker Desktop → Settings → Resources → File sharing, remove every entry and add `~/ai-workspace` and `~/.ai-dev` (as absolute paths, e.g. `/Users/<name>/ai-workspace`), then Apply & restart.

Wait for confirmation before continuing.

- [ ] **Step 6: Verify File Sharing**

Run: `make check-host`
Expected: `PASS Docker cannot mount /Users/<name> (File Sharing is restricted)`.

- [ ] **Step 7: Bring the stack up and run all checks**

Run: `make build && make up && make check`
Expected: `ai-dev-check: all checks passed` and `smoke-test: all checks passed` (now including the Nested Docker section). `docker logs ai-dev-docker 2>&1 | grep -i 'API listen'` shows only `/var/run/docker.sock` and `127.0.0.1:2375`.

- [ ] **Step 8: Confirm nested containers are isolated from Docker Desktop**

Run: `docker exec -u ai-coder ai-dev docker ps -a --format '{{.Names}}'`
Expected: does not list `ai-dev` or `ai-dev-docker` (the nested engine sees only its own containers).

- [ ] **Step 9: Run unit tests once more, then commit**

Run: `make test-unit` → every file `0 failed`.
```bash
git add compose.yaml Makefile scripts/host/check-file-sharing
git commit -m "feat: add compose stack with nested Docker and Makefile entry points

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: VS Code verification, acceptance checks, and docs

**Files:**
- Create: `README.md`, `CLAUDE.md`

**Interfaces:**
- Consumes: everything above; requires the user for VS Code, Claude login, and GitHub pushes.

- [ ] **Step 1: USER STEP — attach from the dedicated VS Code instance**

Ask the user to run `make vscode`, then Cmd+Shift+P → **Dev Containers: Attach to Running Container** → `ai-dev`, open `/workspace`, open a terminal, and run `ai-dev-check`.
Expected: `ai-dev-check: all checks passed`. If the SSH check fails, record the output and stop: the dedicated-instance approach did not remove `SSH_AUTH_SOCK`, and the design must be revisited with the user.

- [ ] **Step 2: USER STEP — Claude login and session persistence (acceptance 2)**

In that VS Code terminal the user runs `cd /workspace && mkdir -p persist-test && cd persist-test && claude`, logs in, sends one message, exits. Then on macOS: `make down && docker compose rm -f && make up`. Re-attach and run `cd /workspace/persist-test && claude --continue`.
Expected: no login prompt; the previous conversation is shown. Afterwards `rm -rf ~/ai-workspace/persist-test`.

- [ ] **Step 3: USER STEP — GitHub push checks (acceptance 3, 4, 6)**

With the user's chosen repositories, in the container:
1. Clone an authorized repo with an SSH URL on macOS into `~/ai-workspace/`, create a branch, commit, `git push -u origin <branch>` from the container → succeeds.
2. `git push` to a repository the token does not cover → fails with a 403/permission error.
3. Replace `~/.ai-dev/secrets/github-token` on macOS with a newly generated token, then without restarting run `gh auth status` and `git push` → both use the new token.
Delete the test branch afterwards.

- [ ] **Step 4: Docker Desktop restart check (Review Focus 2)**

Ask the user to quit and restart Docker Desktop (or run it yourself if permitted). Then run: `docker ps --filter name=ai-dev --format '{{.Names}} {{.Status}}'` and `docker exec -u ai-coder ai-dev docker version --format '{{.Server.Version}}'`.
Expected: both containers `Up`; the second command prints `29.9.0`. If `dev` has no network, document `make up` as the recovery in README "Troubleshooting".

- [ ] **Step 5: Write `README.md`**

```markdown
# ai-dev

A Docker development environment for running Claude Code on macOS without giving it access to the rest of your Mac.

- Claude runs in the `ai-dev` container as `ai-coder` and can use `--dangerously-skip-permissions`.
- It sees only `~/ai-workspace` (mounted at `/workspace`) plus its own state in `~/.ai-dev`.
- It pushes to GitHub with a fine-grained token limited to the repositories you choose.
- It can run Docker (databases, etc.) in a nested engine that is separate from your Docker Desktop containers.
- Toolchains: Node.js 24, Python 3.12 + uv, C/C++ (GCC, Clang, CMake, Ninja), Rust, Go, Java 21 + Maven, GitHub CLI.

Design: `docs/superpowers/specs/2026-10-12-ai-dev-container-design.md`.

## What is and is not protected

Protected: files outside `~/ai-workspace` and `~/.ai-dev`, your SSH keys and agent, other credentials on the Mac, GitHub repositories the token does not cover, and repository CI secrets (the token has no Workflows permission).

Not protected: anything inside the container (workspace code, the token) can be sent over the network. Only put projects in `~/ai-workspace` that you are willing to expose to the AI.

## First-time setup

1. **Restrict Docker Desktop File Sharing (required).** Docker Desktop → Settings → Resources → File sharing: remove all entries and add `/Users/<you>/ai-workspace` and `/Users/<you>/.ai-dev`. The nested Docker engine runs privileged, so this list is the real boundary between the AI and your Mac. Other containers you run that bind-mount paths under `/Users` need their directories added here.
2. **Create a GitHub fine-grained token** at https://github.com/settings/personal-access-tokens/new: Only select repositories; Contents: Read and write; Pull requests: Read and write (optional); no Workflows; 90-day expiration.
3. `make setup` — creates the directories, asks for the git name/email used for commits, and tells you where to save the token (`~/.ai-dev/secrets/github-token`).
4. `make build && make up`
5. `make check` — must end with `all checks passed`.
6. `make vscode` — opens a dedicated VS Code window. Cmd+Shift+P → **Dev Containers: Attach to Running Container** → `ai-dev`, then open `/workspace/<project>`.
7. In the VS Code terminal run `claude` and log in (open the printed URL in your Mac browser and paste the code back).

Always use `make vscode` to attach. The normal VS Code forwards your Mac's SSH agent into the container.

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
| `make vscode` | Open the dedicated VS Code instance |
| `make test-unit` | Run the script unit tests |

## Where things live

| What | Where |
|---|---|
| Projects | `~/ai-workspace` → `/workspace` |
| Claude login, sessions, settings | `~/.ai-dev/claude` |
| Git identity for container commits | `~/.ai-dev/git/config` |
| GitHub token | `~/.ai-dev/secrets/github-token` (replace the file to rotate; no restart needed) |
| Package caches, shell history | Docker volumes `ai-dev-*` |
| Nested Docker images/containers | Docker volume `ai-dev-docker-data` (`docker volume rm ai-dev-docker-data` after `make down` wipes it) |
| Dedicated VS Code data | `~/Library/Application Support/ai-dev-vscode` |

## Upgrading

Edit the version `ARG`s at the top of the `Dockerfile` (or nothing, to pick up the latest Claude Code and Rust), then `make rebuild`. Claude Code auto-update is disabled in the container.

## Troubleshooting

- **`dev` has no network after the `docker` container restarted on its own:** run `make up` to recreate `dev`.
- **`make check-host` fails:** File Sharing still includes your home directory; see setup step 1.
- **Push fails with 403:** the repository is not selected in the token, or the token expired.
```

- [ ] **Step 6: Write `CLAUDE.md`**

```markdown
# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Infrastructure for a macOS Docker environment ("ai-dev") in which Claude Code runs isolated from the host. There is no application code: the deliverables are a Dockerfile, a compose stack, host-side scripts behind a Makefile, and in-container helper scripts. The design spec is `docs/superpowers/specs/2026-10-12-ai-dev-container-design.md`; read it before changing behavior.

## Commands

- `make test-unit` — run all script unit tests (`tests/test-*.sh`) in a throwaway `buildpack-deps:noble-scm` container.
- Run one test file: `tar -c scripts tests vscode | docker run --rm -i buildpack-deps:noble-scm bash -c 'mkdir -p /src && cd /src && tar -x && bash tests/test-ai-dev-check.sh'`
- `make build` / `make up` / `make check` — build the image, start the stack, run the File Sharing check + `ai-dev-check` + `smoke-test`.
- `docker run --rm -e SMOKE_SKIP_DOCKER=1 ai-dev:latest smoke-test` — smoke-test the image without the nested engine.

## Architecture

- `compose.yaml` runs two containers: `ai-dev-docker` (`docker:dind`, privileged, dockerd on `127.0.0.1:2375` only) and `ai-dev` (the `Dockerfile` image, unprivileged, `network_mode: service:docker`). Sharing the network namespace is what lets `dev` reach dockerd and nested containers' published ports on `localhost` without TLS.
- Host state is mounted from `~/.ai-dev/{claude,git,secrets}` as directories, never single files (git writes config by rename; single-file mounts also go stale when macOS editors replace the file).
- GitHub auth: `/etc/gitconfig` (from `config/gitconfig`) registers `scripts/git-credential-ghtoken` for github.com and rewrites SSH GitHub URLs to HTTPS. `scripts/gh` wraps `/usr/bin/gh` and loads the token per call.
- VS Code: the Dev Containers extension forwards the host SSH agent whenever `SSH_AUTH_SOCK` is set and has no setting to stop it, so `scripts/host/ai-code` launches a separate VS Code instance without that variable. `scripts/ai-dev-check` is the authority on whether any host credential leaked in.
- Scripts take `AI_DEV_*` environment overrides (token path, mountinfo path, etc.) so tests can run them against fixtures.

## Rules that are easy to break

- Docker Desktop File Sharing is restricted to `~/ai-workspace` and `~/.ai-dev`, so this repo cannot be bind-mounted into containers. Stream files in with `tar` as `make test-unit` does.
- Never add a mount of `/var/run/docker.sock`, the host's `~/.claude`, `~/.gitconfig` or `~/.ssh`, and never make `dev` privileged.
- Install toolchains outside `/home/ai-coder` (except Claude Code and the Rust homes) so volume mounts cannot shadow them; pre-create every volume mount point in the Dockerfile as `ai-coder`.
- Ubuntu 24.04 ships user `ubuntu` with UID 1000; the Dockerfile deletes it before creating `ai-coder`.
- Makefile recipes must be indented with tabs.
- All docs, comments and script output are in English.
```

- [ ] **Step 7: Final check and commit**

Run: `make test-unit && make check`
Expected: all unit tests `0 failed`; `ai-dev-check` and `smoke-test` both `all checks passed`; `check-host` PASS.
```bash
git add README.md CLAUDE.md
git commit -m "docs: add README and CLAUDE.md

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
