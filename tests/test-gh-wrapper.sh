#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
wrapper="$(cd "$(dirname "$0")/.." && pwd)/scripts/gh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/real-gh" <<'STUB'
#!/usr/bin/env bash
printf 'token=[%s] args=[%s]\n' "${GH_TOKEN:-}" "$*"
STUB
chmod +x "$tmp/real-gh"

mkdir -p "$tmp/tokens" "$tmp/one" "$tmp/outside"
printf ' ghp_org\r\n' > "$tmp/tokens/safeheron"
printf 'ghp_personal\n' > "$tmp/tokens/Hansenyao"
printf 'ghp_only\n' > "$tmp/one/Hansenyao"

# A repository whose origin belongs to safeheron.
git init -q "$tmp/repo"
git -C "$tmp/repo" remote add origin https://github.com/safeheron/wallet.git

# run_gh DIR TOKEN_DIR ARGS...: runs the wrapper from DIR.
run_gh() {
  local dir="$1" tokens="$2"
  shift 2
  (cd "$dir" && env -u GH_TOKEN -u GH_REPO AI_DEV_TOKEN_DIR="$tokens" AI_DEV_REAL_GH="$tmp/real-gh" bash "$wrapper" "$@")
}

out="$(run_gh "$tmp/repo" "$tmp/tokens" pr list --limit 1)"
assert_eq "uses the origin owner's trimmed token and passes all args" \
  "token=[ghp_org] args=[pr list --limit 1]" "$out"

out="$(run_gh "$tmp/repo" "$tmp/tokens" pr view -R Hansenyao/dotfiles 1)"
assert_contains "-R owner/repo wins over origin" "$out" "token=[ghp_personal]"

out="$(run_gh "$tmp/outside" "$tmp/tokens" issue list --repo hansenyao/dotfiles)"
assert_contains "--repo owner/repo, case-insensitive" "$out" "token=[ghp_personal]"

out="$(run_gh "$tmp/outside" "$tmp/tokens" issue list --repo=github.com/safeheron/wallet)"
assert_contains "--repo=HOST/owner/repo" "$out" "token=[ghp_org]"

git -C "$tmp/repo" remote set-url origin git@github.com:Hansenyao/dotfiles.git
out="$(run_gh "$tmp/repo" "$tmp/tokens" pr list)"
assert_contains "scp-style origin URL" "$out" "token=[ghp_personal]"
git -C "$tmp/repo" remote set-url origin https://github.com/safeheron/wallet.git

printf 'ghp_rotated\n' > "$tmp/tokens/safeheron"
out="$(run_gh "$tmp/repo" "$tmp/tokens" auth status)"
assert_contains "reads the token on every call" "$out" "token=[ghp_rotated]"

out="$(run_gh "$tmp/outside" "$tmp/one" api user)"
assert_contains "no owner and a single token: uses it" "$out" "token=[ghp_only]"

out="$(run_gh "$tmp/outside" "$tmp/tokens" api user 2>"$tmp/err")"
assert_eq "no owner and several tokens: runs without a token" "token=[] args=[api user]" "$out"
assert_contains "no owner and several tokens: warns" "$(cat "$tmp/err")" "-R owner/repo"

out="$(run_gh "$tmp/outside" "$tmp/tokens" issue list -R unknown-org/x 2>"$tmp/err")"
assert_eq "unknown owner runs without a token" "token=[] args=[issue list -R unknown-org/x]" "$out"
assert_contains "unknown owner warns" "$(cat "$tmp/err")" "no token for owner unknown-org"

finish
