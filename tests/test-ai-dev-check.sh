#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
check="$(cd "$(dirname "$0")/.." && pwd)/scripts/ai-dev-check"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/home" "$tmp/sockets" "$tmp/cwd"
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
