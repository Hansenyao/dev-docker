#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
repo="$(cd "$(dirname "$0")/.." && pwd)"
launcher="$repo/scripts/host/ai-code"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Fake VS Code app bundle. The CLI (bin/code) logs each call and lists
# extensions from a state file; the app binary (MacOS/Code) logs how it was
# started, including the variables that decide the launch environment.
app="$tmp/Visual Studio Code.app"
mkdir -p "$app/Contents/Resources/app/bin" "$app/Contents/MacOS"
cat > "$app/Contents/Resources/app/bin/code" <<EOF
#!/usr/bin/env bash
printf 'cli args=[%s]\n' "\$*" >> "$tmp/log"
if [ "\${*: -1}" = "--list-extensions" ]; then cat "$tmp/extensions" 2>/dev/null; fi
if [[ "\$*" == *"--install-extension ms-vscode-remote.remote-containers"* ]]; then
  echo ms-vscode-remote.remote-containers > "$tmp/extensions"
fi
EOF
cat > "$app/Contents/MacOS/Code" <<EOF
#!/usr/bin/env bash
printf 'app sock=[%s] node=[%s] cli=[%s] args=[%s]\n' "\${SSH_AUTH_SOCK:-}" \
  "\${ELECTRON_RUN_AS_NODE:-}" "\${VSCODE_CLI:-}" "\$*" >> "$tmp/log"
EOF
chmod +x "$app/Contents/Resources/app/bin/code" "$app/Contents/MacOS/Code"
base="$tmp/Application Support/ai-dev-vscode"

run_launcher() {
  SSH_AUTH_SOCK=/private/tmp/launchd-agent ELECTRON_RUN_AS_NODE=1 AI_DEV_CODE_APP="$app" \
    AI_DEV_VSCODE_DIR="$base" bash "$launcher" "$@"
}

# The app is started in the background; wait for it to log its start.
wait_for_app() {
  for _ in $(seq 50); do
    grep -q '^app ' "$tmp/log" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

run_launcher; status=$?
assert_eq "first launch succeeds" "0" "$status"
wait_for_app
log="$(cat "$tmp/log")"
assert_contains "starts the app binary, not the CLI (the CLI uses open, which restores launchd's environment)" "$log" "app sock=["
assert_contains "SSH_AUTH_SOCK never reaches VS Code" "$log" "app sock=[] node=[] cli=[1]"
assert_contains "uses the dedicated user data dir" "$log" "--user-data-dir $base/data"
assert_contains "uses the dedicated extensions dir" "$log" "--extensions-dir $base/extensions"
assert_contains "installs Dev Containers on first launch" "$log" "cli args=[--user-data-dir $base/data --extensions-dir $base/extensions --install-extension ms-vscode-remote.remote-containers]"
assert_contains "opens a new window" "$log" "--new-window"
assert_eq "writes the settings" "$(cat "$repo/vscode/settings.json")" "$(cat "$base/data/User/settings.json")"

: > "$tmp/log"
run_launcher /some/arg; status=$?
assert_eq "second launch succeeds" "0" "$status"
wait_for_app
log="$(cat "$tmp/log")"
assert_not_contains "does not reinstall the extension" "$log" "--install-extension"
assert_contains "forwards extra arguments" "$log" "--new-window /some/arg"

if AI_DEV_CODE_APP="$tmp/none" AI_DEV_VSCODE_DIR="$base" bash "$launcher" 2>"$tmp/err"; then
  fail "missing VS Code is an error"
else
  assert_contains "missing VS Code message" "$(cat "$tmp/err")" "VS Code not found"
fi

finish
