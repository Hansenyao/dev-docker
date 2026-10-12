#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
check="$(cd "$(dirname "$0")/.." && pwd)/scripts/ai-dev-check"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/home" "$tmp/sockets" "$tmp/cwd" "$tmp/bin"

# Fake curl answers Dev Containers IPC requests with $FAKE_IPC_GIT or
# $FAKE_IPC_DOCKER (raw JSON replies, as the extension sends them).
# $FAKE_CURL_EXIT makes it fail like curl (7: cannot connect, 28: timeout).
cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
[ -z "${FAKE_CURL_EXIT:-}" ] || exit "$FAKE_CURL_EXIT"
case "$*" in
  *git-credential-helper*) printf '%s' "${FAKE_IPC_GIT:-}" ;;
  *docker-credential-helper*) printf '%s' "${FAKE_IPC_DOCKER:-}" ;;
esac
EOF
# Fake docker reports $FAKE_DOCKER_OS as the daemon's operating system.
cat > "$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
[ -n "${FAKE_DOCKER_OS:-}" ] || exit 1
printf '%s\n' "$FAKE_DOCKER_OS"
EOF
chmod +x "$tmp/bin/curl" "$tmp/bin/docker"
mkdir -p "$tmp/tokens"
printf 'ghp_x\n' > "$tmp/tokens/safeheron"
printf 'ghp_y\n' > "$tmp/tokens/Hansenyao"
printf '[credential "https://github.com"]\n\thelper = ghtoken\n' > "$tmp/system-gitconfig"
: > "$tmp/global-gitconfig"
cat > "$tmp/mountinfo" <<'MOUNTS'
101 100 0:39 /hansenyao/ai-workspace /workspace rw,relatime - virtiofs virtiofs0 rw
102 100 0:39 /hansenyao/.ai-dev/claude /home/ai-coder/.claude rw,relatime - virtiofs virtiofs0 rw
103 100 0:39 /hansenyao/.ai-dev/git /home/ai-coder/.config/git rw,relatime - virtiofs virtiofs0 rw
104 100 0:39 /hansenyao/.ai-dev/secrets /run/secrets/ai-dev ro,relatime - virtiofs virtiofs0 rw
105 100 254:1 /docker/containers/abc/hosts /etc/hosts rw,relatime - ext4 /dev/vda1 rw
MOUNTS

# Runs the check against the fixtures; extra VAR=value args override them.
run_check() {
  (cd "$tmp/cwd" && env -u SSH_AUTH_SOCK \
    HOME="$tmp/home" \
    GIT_CONFIG_SYSTEM="$tmp/system-gitconfig" \
    GIT_CONFIG_GLOBAL="$tmp/global-gitconfig" \
    AI_DEV_TOKEN_DIR="$tmp/tokens" \
    AI_DEV_MOUNTINFO="$tmp/mountinfo" \
    AI_DEV_SOCKET_DIR="$tmp/sockets" \
    AI_DEV_DOCKER_SOCK="$tmp/docker.sock" \
    PATH="$tmp/bin:$PATH" \
    FAKE_DOCKER_OS="Alpine Linux v3.24 (containerized)" \
    "$@" bash "$check")
}

out="$(run_check)"; status=$?
assert_eq "clean environment passes" "0" "$status"
assert_not_contains "clean environment has no FAIL lines" "$out" "FAIL"
assert_contains "lists the token owners" "$out" "GitHub tokens for: Hansenyao safeheron"

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

# Dev Containers IPC socket: the Mac must not hand out credentials through it.
touch "$tmp/sockets/vscode-remote-containers-ipc-abc.sock"
out="$(run_check \
  FAKE_IPC_GIT='{"stdout":"","stderr":"fatal: could not read Username","code":128}' \
  FAKE_IPC_DOCKER='{"stdout":"credentials not found in native keychain","stderr":"","code":1}')"; status=$?
assert_eq "IPC socket without credentials passes" "0" "$status"
assert_contains "IPC probe reported" "$out" "PASS Dev Containers IPC hands out no git or Docker credentials"

out="$(run_check FAKE_IPC_GIT='{"stdout":"protocol=https\nhost=github.com\nusername=Hansenyao\npassword=s3cr3t-value\n","stderr":"","code":0}')"; status=$?
assert_eq "git credential over IPC fails" "1" "$status"
assert_contains "git credential leak reported" "$out" "FAIL Dev Containers IPC hands out host credentials: git(github.com)"
assert_not_contains "git secret is not printed" "$out" "s3cr3t-value"

out="$(run_check FAKE_IPC_GIT='{"stdout":"protocol=https\nhost=github.com\nusername=\npassword=\n","stderr":"","code":0}')"; status=$?
assert_eq "empty git password over IPC passes" "0" "$status"

out="$(run_check FAKE_IPC_DOCKER='{"stdout":"{\"ServerURL\":\"https://index.docker.io/v1/\",\"Username\":\"me\",\"Secret\":\"s3cr3t-value\"}","stderr":"","code":0}')"; status=$?
assert_eq "docker credential over IPC fails" "1" "$status"
assert_contains "docker credential leak reported" "$out" "docker(index.docker.io)"
assert_not_contains "docker secret is not printed" "$out" "s3cr3t-value"
out="$(run_check FAKE_CURL_EXIT=28)"; status=$?
assert_eq "IPC timeout fails" "1" "$status"
assert_contains "IPC timeout reported" "$out" "git(github.com)(no reply, curl exit 28)"

out="$(run_check FAKE_CURL_EXIT=7)"; status=$?
assert_eq "stale IPC socket passes" "0" "$status"
rm "$tmp/sockets/vscode-remote-containers-ipc-abc.sock"

# Docker: no host socket, and the daemon is the nested engine.
touch "$tmp/docker.sock"
out="$(run_check)"; status=$?
assert_eq "docker socket present fails" "1" "$status"
assert_contains "docker socket reported" "$out" "FAIL $tmp/docker.sock exists"
rm "$tmp/docker.sock"

out="$(run_check FAKE_DOCKER_OS="Docker Desktop")"; status=$?
assert_eq "Docker Desktop daemon fails" "1" "$status"
assert_contains "Docker Desktop daemon reported" "$out" "FAIL docker talks to the Docker Desktop engine"

out="$(run_check FAKE_DOCKER_OS=)"; status=$?
assert_eq "unreachable daemon passes" "0" "$status"

cp "$tmp/mountinfo" "$tmp/mountinfo.ok"
echo '106 100 0:39 /hansenyao/.ssh /home/ai-coder/.ssh ro,relatime - virtiofs virtiofs0 rw' >> "$tmp/mountinfo"
out="$(run_check)"; status=$?
assert_eq "unexpected host mount fails" "1" "$status"
assert_contains "unexpected mount reported" "$out" "/home/ai-coder/.ssh"
cp "$tmp/mountinfo.ok" "$tmp/mountinfo"

: > "$tmp/tokens/safeheron"
: > "$tmp/tokens/Hansenyao"
out="$(run_check)"; status=$?
assert_eq "only empty token files fails" "1" "$status"
assert_contains "token reported" "$out" "FAIL no GitHub token"

rm -rf "$tmp/tokens"
out="$(run_check)"; status=$?
assert_eq "missing token directory fails" "1" "$status"

finish
