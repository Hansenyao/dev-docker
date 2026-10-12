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
