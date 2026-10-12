#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
helper="$(dirname "$0")/../scripts/git-credential-ghtoken"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/tokens"
printf 'ghp_personal\n' > "$tmp/tokens/Hansenyao"
printf 'ghp_org\n' > "$tmp/tokens/safeheron"

# request HOST PATH: a git credential request; PATH may be empty.
request() {
  printf 'protocol=https\nhost=%s\n' "$1"
  if [ -n "${2:-}" ]; then printf 'path=%s\n' "$2"; fi
  printf '\n'
}
helper_get() { AI_DEV_TOKEN_DIR="$tmp/tokens" bash "$helper" get; }

out="$(request github.com safeheron/wallet.git | helper_get)"
assert_eq "picks the token of the repository owner" \
  "$(printf 'username=x-access-token\npassword=ghp_org')" "$out"

out="$(request github.com Hansenyao/dotfiles.git | helper_get)"
assert_contains "picks the personal token for personal repos" "$out" "password=ghp_personal"

out="$(request github.com SafeHeron/wallet.git | helper_get)"
assert_contains "owner match is case-insensitive" "$out" "password=ghp_org"

out="$(request github.com unknown-org/repo.git | helper_get 2>"$tmp/err")"; status=$?
assert_eq "unknown owner exits 0 so git reads the reply" "0" "$status"
assert_eq "unknown owner tells git to stop asking" "quit=1" "$out"
assert_contains "unknown owner explains which file to add" "$(cat "$tmp/err")" "no token for owner unknown-org"

out="$(request github.com | helper_get 2>"$tmp/err")"
assert_eq "missing path tells git to stop asking" "quit=1" "$out"
assert_contains "missing path explains useHttpPath" "$(cat "$tmp/err")" "useHttpPath"

out="$(request gitlab.com group/repo.git | helper_get)"
assert_eq "other hosts get no answer" "" "$out"

out="$(request github.com safeheron/wallet.git | AI_DEV_TOKEN_DIR="$tmp/tokens" bash "$helper" store)"
assert_eq "store is ignored" "" "$out"

out="$(request github.com safeheron/wallet.git | AI_DEV_TOKEN_DIR="$tmp/tokens" bash "$helper" erase)"
assert_eq "erase is ignored" "" "$out"

printf '  ghp_spaced \r\n' > "$tmp/tokens/messy"
out="$(request github.com messy/repo.git | helper_get)"
assert_contains "whitespace and CRLF are stripped" "$out" "$(printf 'password=ghp_spaced\n')"
assert_not_contains "no carriage return in the reply" "$out" $'\r'

out="$(printf 'protocol=https\nhost=github.com\npath=safeheron/wallet.git' | helper_get)"
assert_contains "input without trailing blank line works" "$out" "password=ghp_org"

: > "$tmp/tokens/emptyorg"
out="$(request github.com emptyorg/repo.git | helper_get 2>"$tmp/err")"
assert_eq "empty token file is treated as missing" "quit=1" "$out"

out="$(request github.com safeheron/wallet.git | AI_DEV_TOKEN_DIR="$tmp/nope" bash "$helper" get 2>"$tmp/err")"
assert_eq "missing token directory tells git to stop asking" "quit=1" "$out"

finish
