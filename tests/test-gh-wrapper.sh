#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
wrapper="$(dirname "$0")/../scripts/gh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/real-gh" <<'STUB'
#!/usr/bin/env bash
printf 'token=[%s] args=[%s]\n' "${GH_TOKEN:-}" "$*"
STUB
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
