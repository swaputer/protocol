#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# Stage 7B is additive: the entire Stage 7A2 release gate remains mandatory.
./script/accept-stage7a2.sh

npm run build --prefix tooling/deployment-manifest
npm run typecheck --prefix tooling/deployment-manifest
npm test --prefix tooling/deployment-manifest
node --test --test-name-pattern='Stage 7B threat-class|OutOfByteGas|static descendants|call depth|receipt and memory' tooling/tinysol/dist/test/simulator.test.js

forge test --match-path 'test/SwapVMStage7B*.t.sol' -vvv
forge test --match-path 'test/invariant/SwapVMStage7B*Invariant.t.sol' -vvv
python3 script/check-contract-sizes.py
./script/run-slither.sh

if [[ "${1:-}" == "--deep" ]]; then
  # Factory CREATE2 paths are covered by the default stateful profile; the
  # deep profile focuses its larger call budget on funded Router settlement.
  FOUNDRY_PROFILE=security forge test --match-path test/invariant/SwapVMStage7BRouterInvariant.t.sol -vvv
  FOUNDRY_PROFILE=security forge test --match-path 'test/SwapVMStage7B*.t.sol' -vvv
  FOUNDRY_PROFILE=security forge test --match-path test/SwapVMStage6D3.t.sol -vvv
fi

forge fmt --check
forge snapshot --check
git diff --check
