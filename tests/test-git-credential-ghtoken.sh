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
