# Minimal assertion helpers for shell tests. Source this file, call the
# assert_* functions, and end the test file with `finish`.
TESTS_RUN=0
TESTS_FAILED=0

pass() {
  TESTS_RUN=$((TESTS_RUN + 1))
  printf 'ok   %s\n' "$1"
}

fail() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf 'FAIL %s\n' "$1"
  if [ -n "${2:-}" ]; then printf '     %s\n' "$2"; fi
}

assert_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$2], got [$3]"; fi
}

assert_contains() {
  case "$2" in
    *"$3"*) pass "$1" ;;
    *) fail "$1" "[$2] does not contain [$3]" ;;
  esac
}

assert_not_contains() {
  case "$2" in
    *"$3"*) fail "$1" "[$2] unexpectedly contains [$3]" ;;
    *) pass "$1" ;;
  esac
}

finish() {
  printf '%d run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
  [ "$TESTS_FAILED" -eq 0 ]
}
