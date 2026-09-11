# Swaputer repository structure

Swaputer is split across seven private repositories under the `swaputer`
GitHub account.

| Repository | Responsibility |
| --- | --- |
| `protocol` | Contracts, Foundry tests, protocol specifications, release manifests, and security evidence. |
| `explorer` | Read-only protocol explorer, Go indexer, REST API, and WebSocket feed. |
| `ecosystem` | Wallet-connected Mint, Market, Bridge, and Terminal applications in the Swaputer desktop/mobile shell. |
| `studio` | Desktop-only TinySol editor, compiler, simulator, and deployment interface. |
| `docs` | VitePress developer documentation site. |
| `tooling` | TinySol, receipt codec, read-only CLI, Inspector, and internal development tools. |
| `operations` | Docker testnet stack, monitoring, backups, recovery drills, continuous on-chain tests, and integration gates. |

## Protocol repository

| Directory | Responsibility |
| --- | --- |
| `src` | EVM protocol contracts. Frozen on-chain names remain unchanged for compatibility. |
| `test` | Unit, fuzz, invariant, and fork tests. |
| `script` | Foundry deployment, exercise, and protocol acceptance scripts. |
| `reference` | Frozen reference package artifacts. |
| `deployments` | Canonical network deployments and protocol release evidence. |
| `docs/spec` | Consensus and signature specifications consumed by implementations. |
| `docs/security` | Threat model, findings, policies, and security invariants. |
| `release` | Historical frozen release-candidate evidence. |
| `audit` | Historical audit handoff snapshots; no independent audit report exists. |
| `tooling` | Symlink to the pinned private `swaputer/tooling` submodule. |

## Naming boundary

User-facing products, the Kernel ABI, documentation, indexer schemas, and APIs
use **SVM** and **Events**. Raw Ethereum `logs`, `logIndex`, `eth_getLogs`, and
EVM `LOG0`–`LOG4` names remain unchanged because they belong to Ethereum.

## Local secrets

Real RPC URLs and credentials belong in ignored `.env.local` files. Wallets and
private keys must never be committed to any Swaputer repository.
