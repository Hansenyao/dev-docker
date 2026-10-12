#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
check="$(cd "$(dirname "$0")/.." && pwd)/scripts/host/check-file-sharing"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Fake docker: `info` fails if $FAKE_DOCKER_DOWN is set; `run` succeeds if
# $FAKE_MOUNT_OK is set, otherwise refuses the mount like Docker Desktop.
mkdir -p "$tmp/bin" "$tmp/home"
cat > "$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  info) [ -z "${FAKE_DOCKER_DOWN:-}" ] ;;
  run)
    [ -n "${FAKE_MOUNT_OK:-}" ] && exit 0
    echo "docker: Error response from daemon: mounts denied: The path is not shared from the host and is not known to Docker."
    exit 125 ;;
esac
EOF
chmod +x "$tmp/bin/docker"

home="$tmp/home"
settings="$tmp/settings-store.json"
write_settings() {
  printf '{\n  "AutoStart": true,\n  "FilesharingDirectories": [\n' > "$settings"
  local first=1 d
  for d in "$@"; do
    [ "$first" = 1 ] || printf ',\n' >> "$settings"
    printf '    "%s"' "$d" >> "$settings"
    first=0
  done
  printf '\n  ],\n  "OpenUIOnStartupDisabled": true\n}\n' >> "$settings"
}

run_check() {
  env PATH="$tmp/bin:$PATH" HOME="$home" AI_DEV_DOCKER_SETTINGS="$settings" "$@" bash "$check" 2>&1
}

write_settings "$home/.ai-dev" "$home/ai-workspace"
out="$(run_check)"; status=$?
assert_eq "restricted sharing passes" "0" "$status"
assert_contains "home probe reported" "$out" "PASS Docker cannot mount $home"
assert_contains "shared list reported" "$out" "PASS Docker Desktop shares only: $home/.ai-dev $home/ai-workspace"

write_settings "$home/ai-workspace/project"
out="$(run_check)"; status=$?
assert_eq "directory inside an allowed one passes" "0" "$status"

write_settings "$home/.ai-dev" "$home/ai-workspace" "/Volumes" "/var/folders"
out="$(run_check)"; status=$?
assert_eq "extra shared directories fail" "1" "$status"
assert_contains "extra directories reported" "$out" "FAIL Docker Desktop also shares: /Volumes /var/folders"

write_settings "$home/ai-workspace-old"
out="$(run_check)"; status=$?
assert_eq "sibling with an allowed prefix fails" "1" "$status"

write_settings "$home/.ai-dev" "$home/ai-workspace"
out="$(run_check FAKE_MOUNT_OK=1)"; status=$?
assert_eq "mountable home fails" "1" "$status"
assert_contains "mountable home reported" "$out" "FAIL Docker can mount $home"

rm "$settings"
out="$(run_check)"; status=$?
assert_eq "missing settings file fails" "1" "$status"
assert_contains "missing settings reported" "$out" "FAIL cannot read Docker Desktop settings"

out="$(run_check FAKE_DOCKER_DOWN=1)"; status=$?
assert_eq "Docker not running fails" "1" "$status"

finish
