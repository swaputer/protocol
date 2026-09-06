#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

slither_bin="${SLITHER_BIN:-slither}"
if [[ -x "$repo_root/.security-tools/slither/bin/slither" ]]; then
  slither_bin="$repo_root/.security-tools/slither/bin/slither"
fi

result="$(mktemp -t swapvm-slither.XXXXXX.json)"
log="$(mktemp -t swapvm-slither.XXXXXX.log)"
trap 'rm -f "$result" "$log"' EXIT
rm -f "$result"
set +e
"$slither_bin" . --compile-force-framework foundry --skip-clean \
  --filter-paths '(^|/)(lib|test|script)/' --json "$result" >"$log" 2>&1
status=$?
set -e
if [[ $status -ne 0 && ! -s "$result" ]]; then
  tail -n 200 "$log"
  exit "$status"
fi
if ! python3 script/check-slither.py "$result"; then
  tail -n 200 "$log"
  exit 1
fi
