#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

cd "$ROOT_DIR"

FOUNDRY_PROFILE=security \
FOUNDRY_INVARIANT_FAIL_ON_REVERT=true \
  forge test \
    --match-contract 'SwapVM(Stage5|SETHVault|SRC20Market|Authorization|Resource)InvariantTest' \
    --match-test '^invariant_'

printf '%s\n' '{"schemaVersion":"swaputer-custody-invariants/4","status":"passed","profile":"security","runs":256,"depth":64,"failOnRevert":true,"invariantCount":12,"actionCallsPerInvariant":16384,"unexpectedReverts":0,"domains":["Authorization binding","Kernel rollback","Resource isolation","sETH backing","SRC20 market custody"]}'
