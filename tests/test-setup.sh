#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
setup="$(cd "$(dirname "$0")/.." && pwd)/scripts/host/setup"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

out="$(printf 'Alice Example\nalice@example.com\n' | HOME="$tmp" bash "$setup" 2>&1)"; status=$?
assert_eq "first run succeeds" "0" "$status"
for d in ai-workspace .ai-dev/claude .ai-dev/git .ai-dev/secrets/github; do
  if [ -d "$tmp/$d" ]; then pass "creates $d"; else fail "creates $d"; fi
done
assert_eq ".ai-dev is mode 700" "700" "$(stat -c %a "$tmp/.ai-dev")"
assert_eq "secrets is mode 700" "700" "$(stat -c %a "$tmp/.ai-dev/secrets")"
assert_eq "writes user.name" "Alice Example" "$(git config --file "$tmp/.ai-dev/git/config" user.name)"
assert_eq "writes user.email" "alice@example.com" "$(git config --file "$tmp/.ai-dev/git/config" user.email)"
assert_contains "explains how to create the tokens" "$out" "fine-grained"
assert_contains "explains one token file per owner" "$out" ".ai-dev/secrets/github/<owner>"
assert_contains "reminds about File Sharing" "$out" "File sharing"

printf 'ghp_x\n' > "$tmp/.ai-dev/secrets/github/safeheron"
chmod 644 "$tmp/.ai-dev/secrets/github/safeheron"
out="$(HOME="$tmp" bash "$setup" < /dev/null 2>&1)"; status=$?
assert_eq "re-run without input succeeds" "0" "$status"
assert_contains "re-run keeps identity" "$out" "already set"
assert_eq "re-run did not change user.name" "Alice Example" "$(git config --file "$tmp/.ai-dev/git/config" user.name)"
assert_contains "re-run lists token owners" "$out" "GitHub tokens found for: safeheron"
assert_eq "token kept" "ghp_x" "$(cat "$tmp/.ai-dev/secrets/github/safeheron")"
assert_eq "token set to mode 600" "600" "$(stat -c %a "$tmp/.ai-dev/secrets/github/safeheron")"
assert_eq "token directory is mode 700" "700" "$(stat -c %a "$tmp/.ai-dev/secrets/github")"

rm -rf "$tmp/.ai-dev/git/config"
out="$(printf '\n\n' | HOME="$tmp" bash "$setup" 2>&1)"; status=$?
assert_eq "empty identity is rejected" "1" "$status"
assert_contains "empty identity message" "$out" "required"

finish
