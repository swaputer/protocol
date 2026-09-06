#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# Stage 7D-U1 is additive and may not weaken the complete internal security gate.
./script/accept-stage7b.sh

npm run build --prefix tooling/deployment-manifest
npm run typecheck --prefix tooling/deployment-manifest
npm test --prefix tooling/deployment-manifest

npm run build --prefix tooling/indexer
npm run typecheck --prefix tooling/indexer
npm run test:mock --prefix tooling/indexer
npm run migrate:test --prefix tooling/indexer

forge test --match-path test/SwapVMStage7DU1Policy.t.sol -vvv
node tooling/stage7d/stage7d-u1-e2e.mjs
./script/check-stage7d-u1-docs.sh

forge fmt --check
forge build --sizes
forge snapshot --check

npm audit --prefix tooling/receipt-codec
npm audit --prefix tooling/indexer
npm audit --prefix tooling/tinysol
npm audit --prefix tooling/deployment-manifest

rc2_tag='swaputer-v1.1-stage7c-rc2'
rc2_commit='afa54c2e02e7e91430b14b6884faff5e3f5867d9'
[[ "$(git rev-parse "${rc2_tag}^{commit}")" == "$rc2_commit" ]] || {
  echo 'STAGE7D_RC2_ERROR tag moved' >&2
  exit 1
}
./script/verify-audit-snapshot.sh "$rc2_tag"

git diff --check
echo '{"stage7c":"incomplete","stage7dU1":"PASS","publicRpcUsed":false,"mainnetAllowed":false}'
