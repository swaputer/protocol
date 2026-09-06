#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

npm run build --prefix tooling/receipt-codec
npm run typecheck --prefix tooling/receipt-codec
npm test --prefix tooling/receipt-codec
npm run check:manifests --prefix tooling/receipt-codec

npm run build --prefix tooling/indexer
npm run typecheck --prefix tooling/indexer
npm test --prefix tooling/indexer
npm run migrate:test --prefix tooling/indexer
npm run registry:check --prefix tooling/indexer

npm run build --prefix tooling/tinysol
npm run typecheck --prefix tooling/tinysol
npm test --prefix tooling/tinysol
npm run isa:check --prefix tooling/tinysol
npm run references:check --prefix tooling/tinysol
npm run corpus:check --prefix tooling/tinysol
npm run compiler-identity:check --prefix tooling/tinysol
npm run fixtures:check --prefix tooling/tinysol
npm run examples:check --prefix tooling/tinysol
npm run simulator:fixtures:check --prefix tooling/tinysol

forge fmt --check
forge build --sizes
forge test -vvv
npm run test:e2e --prefix tooling/indexer
npm run test:compiler-e2e --prefix tooling/indexer
node tooling/stage6e/stage6e-e2e.mjs
forge snapshot --check

npm audit --prefix tooling/receipt-codec
npm audit --prefix tooling/indexer
npm audit --prefix tooling/tinysol
git diff --check
