# SwapVM Stage 1-5 dependencies

All Solidity dependencies are Git submodules pinned to full commit hashes. No dependency follows a floating branch at build time.

| Dependency | Commit | Notes |
| --- | --- | --- |
| Uniswap `v4-core` | `59d3ecf53afa9264a16bba0e38f4c5d2231f80bc` | Official Uniswap repository; `v4.0.0-12-g59d3ecf5` |
| Uniswap `v4-periphery` | `dce236d4e2057422d0791d9a973a58765eb46f65` | Official Uniswap repository; this commit pins the same `v4-core` commit above |
| Foundry `forge-std` | `77041d2ce690e692d6e03cc812b57d1ddaa4d505` | Tag `v1.9.7` |
| Solmate (transitive from `v4-core`) | `4b47a19038b798b4a33d9749d25e570443520647` | Commit recorded by the pinned `v4-core` submodule |

The project compiles with Solidity `0.8.26`, Cancun EVM semantics, IR compilation, and optimizer runs set to `200`. Stage 4 lowered the runs setting from the Stage 3 checkpoint's `20,000` so the bounded virtual-record implementation remains deployable under EIP-170; this changes generated EVM code and gas tradeoffs, not SwapVM semantics.

CI pins Foundry `v1.5.1` (commit `b0a9dd9ceda36f63e2326ce530c10e6916f4b8a2`) so the exact gas snapshot is not compared across moving compiler-toolchain releases.

Install the exact dependency tree after cloning with:

```sh
git submodule update --init --recursive
```

The Stage 1-5 tests import Uniswap's real `PoolManager`, official pool types/libraries, `PoolModifyLiquidityTest`, `PoolSwapTest`, and `HookMiner`. The Stage 2-5 fixture Router settles through the real `PoolManager.unlock` path. No substitute outer AMM is used. The deterministic reference-package generator additionally uses Python 3 and PyCryptodome's Keccak implementation; it is a development tool and not a Solidity runtime dependency.

Stage 6A adds a TypeScript source workspace under `tooling/receipt-codec`. Its runtime codec has no third-party dependencies. Development dependencies are locked in `package-lock.json` and declared at exact versions: Node.js 20 or newer, TypeScript `5.7.3`, `@types/node` `22.10.2`, and `@noble/hashes` `1.7.1`. The hash library is used only to verify selector and freeze-manifest Keccak hashes; it is not imported by the codec runtime. The allowlisted runtime was briefly published as `@swaputer/receipt-codec@0.1.0` and withdrawn on September 6, 2026; the source workspace remains marked private to prevent accidental whole-workspace publication.

Stage 6B adds the private `tooling/indexer` workspace on Node.js 22. It reuses `@swaputer-labs/receipt-codec` through an exact local file dependency and locks all packages in its own `package-lock.json`. Runtime dependencies are `better-sqlite3` `13.0.3` (MIT, SQLite persistence and synchronous transaction boundary) and `@noble/hashes` `1.7.1` (MIT, exact outer `VMLog` Keccak topic). Development dependencies are TypeScript `5.7.3`, `@types/node` `22.10.2`, and `@types/better-sqlite3` `9.6.0`, all MIT. No ORM, RPC vendor SDK or ABI framework is used. The SQLite native dependency is confined to the offchain indexer process and never enters onchain or receipt-codec code.

Stage 6C adds no package dependency. It reuses the indexer's pinned hash library for selectors and deterministic descriptor hashes, SQLite for migration 002, and the local receipt codec's strict record types. The built-in verified registry is generated only from repository reference artifacts and checked during build/typecheck; external descriptors are always registered as `declared_unverified`.

Stage 6D1 adds the `tooling/tinysol` source workspace on Node.js 22. Its only runtime dependency is the already-pinned MIT `@noble/hashes` `1.7.1`, used for Keccak-256 ABI, package and manifest hashes. Development dependencies are TypeScript `5.7.3` and `@types/node` `22.10.2`, both exact. No parser framework, EVM assembler, LLVM component, RPC client or wallet dependency is introduced. The workspace has an independent lockfile and uses Node's built-in test runner, crypto, filesystem and process APIs. The allowlisted compiler/runtime/CLI was briefly published as `@swaputer/tinysol@0.3.0` and withdrawn on September 6, 2026; the source workspace remains marked private to preserve the controlled package boundary.

Stage 6D2 adds no dependency. The lexer, parser, semantic analysis, deterministic compiler, fixture generator and CLI extensions use the same exact Node.js/TypeScript/hash-library lock. The Stage 6C compiler-event E2E reuses the existing indexer, local Anvil and Foundry tooling; it does not add an RPC SDK, parser generator, ABI framework, simulator or wallet library.

Stage 6D3 adds exact runtime dependency `@noble/curves` `1.8.1` (MIT) to the TinySol workspace solely for local secp256k1 public-key recovery required by ISA `ECRECOVER`. The interpreter, journal, package/state model, byte estimator and differential corpus otherwise use project code and Node built-ins; they do not use RPC, an EVM emulator, a Solidity subprocess or wallet software. The Stage 6D3 workspace package was `0.3.0`, and the first replacement candidate used `@swaputer-labs/tinysol@0.3.1`. The current public package is `@swaputer-labs/tinysol@0.3.2`. Compiler package bytes are unchanged, while deterministic compiler sidecars were refreshed because the package manifest and exact workspace lock hash are part of compiler identity.

Stage 6E adds no runtime or development dependency and no fourth npm workspace. Its orchestration script uses Node.js built-ins plus the already built codec, indexer and TinySol packages, and invokes the pinned local Foundry/Anvil/cast toolchain. All state is isolated to an ephemeral local Anvil chain and temporary SQLite database; no public RPC or deployment dependency is introduced.

Stage 7A2 adds the private `tooling/deployment-manifest` Node.js 22 workspace.
It pins `@noble/hashes` `1.7.1` for Keccak-256, `@noble/curves` `1.8.1`
for offline secp256k1/EIP-191 publication signatures, TypeScript `5.7.3`, and
`@types/node` `22.10.2`; its independent lockfile fixes the full dependency
tree. The core codec/preflight logic opens no RPC or database connection and
the CLI deliberately has no private-key option. Stage 7D-U1 adds an optional
read-only standard JSON-RPC observer selected by an environment-variable name;
it cannot send transactions and never prints or persists the RPC URL. Stage
7A2/7D-U1 add no Solidity library dependency.

Stage 7B adds only a development-time static analyzer: `slither-analyzer==0.11.4`,
exact-pinned in `requirements-security.txt`. It is never imported by production
contracts or TypeScript runtime code. `script/run-slither.sh` invokes the Foundry
adapter with `--skip-clean`, filters dependency/test/script paths, and compares the
machine result to the explicit triage in `security-results/slither-summary.json`.

The npm package boundary publishes exactly three MIT packages:
`@swaputer-labs/receipt-codec@0.1.2`, `@swaputer-labs/tinysol@0.3.2`, and
`@swaputer-labs/cli@0.1.2`. Every source manifest remains `private: true`;
public archives are generated only from the Tooling repository's allowlisted
temporary staging output. Package preparation and CI never publish
automatically. The published CLI is a Node.js command-line package and exposes
no browser subpath. The withdrawn `@swaputer/*` names remain historical
publication evidence and are not reused or rewritten.

Stage 7D-U1 adds no package. The release rehearsal uses Node built-ins, the four
existing locked workspaces, and pinned Foundry/Anvil. Indexer health, backup and
restore use the already pinned `better-sqlite3`; no web dashboard, alert vendor,
RPC SDK, wallet library or secret manager is introduced.

Stage 7D-U2 uses the already deployed official Uniswap v4 Base Sepolia
PoolManager `0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408`. The post-deployment liquidity
remediation uses the official Base Sepolia PositionManager
`0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80` (live EXTCODEHASH
`0xe8329b35b8b34290b6cf03affc0836f7b23205229cc96ffdc66544b93112c076`)
and canonical Permit2 `0x000000000022D473030F116dDEE9F6B43aC78BA3`. These are external deployed
contracts, not new repository packages; local encoding continues to use the
pinned `v4-periphery` sources above.

The local v1.2 executor-context extension adds no dependency. TinySol continues
to use the same exact Node.js, TypeScript, `@noble/hashes` and `@noble/curves`
versions; only the generated ISA source changes from `SwapVM-ISA-v1.json` to
`SwapVM-ISA-v2.json` for the v1.2 line. The SRC20 market escrow package and
React market integration likewise add no Solidity or JavaScript dependency.
