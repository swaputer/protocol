#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

audit_ref="${1:-}"
if [[ -n "$audit_ref" ]]; then
  python3 script/audit_snapshot.py verify --ref "$audit_ref"
else
  python3 script/audit_snapshot.py verify
fi

npm run check:manifests --prefix tooling/receipt-codec
python3 script/check-contract-sizes.py

if git ls-files --error-unmatch wallet.txt >/dev/null 2>&1; then
  echo "AUDIT_SNAPSHOT_ERROR wallet.txt is tracked" >&2
  exit 1
fi
if ! git check-ignore -q -- wallet.txt; then
  echo "AUDIT_SNAPSHOT_ERROR wallet.txt is not ignored" >&2
  exit 1
fi
if git diff --cached --name-only | grep -Fxq 'wallet.txt'; then
  echo "AUDIT_SNAPSHOT_ERROR wallet.txt is staged" >&2
  exit 1
fi

archive_ref=""
if [[ -n "$audit_ref" ]]; then
  archive_ref="$audit_ref"
elif git diff --cached --name-only | grep -Fxq 'audit/source-files.sha256'; then
  if ! git diff --quiet; then
    echo "AUDIT_SNAPSHOT_ERROR unstaged changes differ from the staged audit tree" >&2
    exit 1
  fi
  archive_ref="$(git write-tree)"
fi

if [[ -n "$archive_ref" ]]; then
  archive_names="$(mktemp)"
  trap 'rm -f "$archive_names"' EXIT
  git archive --format=tar "$archive_ref" | tar -tf - >"$archive_names"
  if grep -Eq '(^|/)(wallet\.txt|\.env($|\.)|broadcast/|cache/|out/|node_modules/|dist/|\.security-tools/)' "$archive_names"; then
    echo "AUDIT_SNAPSHOT_ERROR forbidden path in archive" >&2
    exit 1
  fi
  if grep -Eq '\.(sqlite|sqlite-shm|sqlite-wal|pem|key|keystore|p12|pfx)$' "$archive_names"; then
    echo "AUDIT_SNAPSHOT_ERROR secret/database suffix in archive" >&2
    exit 1
  fi
fi

echo '{"archiveNames":"PASS","frozenManifest":"PASS","walletTracked":false,"walletIgnored":true,"status":"PASS"}'
