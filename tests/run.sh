#!/usr/bin/env bash
# Runs every tests/test-*.sh and exits non-zero if any of them fails.
set -u
cd "$(dirname "$0")/.."
status=0
for t in tests/test-*.sh; do
  echo "== $t"
  bash "$t" || status=1
done
exit "$status"
