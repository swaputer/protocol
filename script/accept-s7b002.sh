#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

output="security-results/stage7m-s7b002.json"
allow_dirty=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --allow-dirty)
      allow_dirty=1
      shift
      ;;
    --output)
      [[ $# -ge 2 ]] || { echo "--output requires a path" >&2; exit 2; }
      output="$2"
      shift 2
      ;;
    *)
      echo "usage: accept-s7b002.sh [--allow-dirty] [--output FILE]" >&2
      exit 2
      ;;
  esac
done

npm run build --prefix tooling/deployment-manifest
node --test script/s7b002-evidence.test.mjs

run_args=(run --output "$output")
verify_args=(verify "$output" --current)
if [[ "$allow_dirty" == 1 ]]; then
  run_args+=(--allow-dirty)
else
  verify_args+=(--formal)
fi

node script/s7b002-evidence.mjs "${run_args[@]}"
node script/s7b002-evidence.mjs "${verify_args[@]}"
