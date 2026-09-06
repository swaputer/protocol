#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

./script/accept-stage6.sh

npm run build --prefix tooling/deployment-manifest
npm run typecheck --prefix tooling/deployment-manifest
npm test --prefix tooling/deployment-manifest
npm audit --prefix tooling/deployment-manifest

forge fmt --check
forge build --sizes
forge test --match-path test/SwapVMStage7A1P.t.sol -vvv
forge test --match-path test/SwapVMStage7A2.t.sol -vvv
forge snapshot --check
git diff --check
