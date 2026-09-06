# Audit scope classification

## Security critical production code

- `src/SwapVMHook.sol`
- `src/SwapVMKernel.sol`
- `src/SwapVMMiniVM.sol` — integrated into Kernel; not a standalone deployed component
- `src/SwapVMGasToken.sol`
- `src/SwapVMReferenceRegistry.sol`
- `src/SwapVMRouter.sol`
- `src/SwapVMWorldFactory.sol`
- `src/SwapVMWorldDeployer.sol`
- `src/SwapVMCreationCodeStore.sol`
- `src/interfaces/ISwapVMWorldFactory.sol`
- `reference/` immutable canonical program packages

## Security critical offchain code

- `tooling/receipt-codec/src`, scripts, schema fixtures and tests
- `tooling/indexer/src`, migrations, registry generator and tests
- `tooling/tinysol/src`, generators, fixtures, examples and tests
- `tooling/deployment-manifest/src`, schema and tests
- `tooling/stage6e/stage6e-e2e.mjs`

## Supporting evidence and reproducibility

- `docs/spec/`, `docs/security/`, Stage implementation reports and language documentation
- `script/`, `security-results/`, `.github/workflows/test.yml`, `.gas-snapshot`
- `foundry.toml`, npm package/lock files, `.gitmodules`, `requirements-security.txt`
- `audit/` handoff, machine commitments and verifier
- top-level submodule gitlinks recorded by exact commit in `audit/submodules.json`

## Test-only

- `test/`
- `script/Stage6BE2E.s.sol`, `Stage6D2E2E.s.sol`, `Stage6EE2E.s.sol`, `Stage7A2Deploy.s.sol`
- Uniswap test routers/helpers imported from fixed submodules

## Excluded

See `EXCLUSIONS.md`. In particular, local secrets/signing material, generated build/install output, runtime
databases, public-network deployment, UI/frontend and operational infrastructure are not in the snapshot.

The exact regular-file allowlist is `source-files.sha256`; classification/discovery rules are
`source-scope.json`. Submodule source is reviewed at the gitlinks in `submodules.json` and is not expanded
into the top-level source hash list.
