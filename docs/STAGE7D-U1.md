# Stage 7D-U1 — unaudited testnet release and operations preparation

Status: **complete as local operational preparation; unaudited experimental; not deployed**.

Stage 7C remains incomplete. No independent auditor or audit report exists, and S7B-002 remains an open
Medium availability/operations finding. This stage does not authorize mainnet, real funds, third-party
custody, a live bounty, or a public testnet transaction. The immutable historical candidate remains
`swaputer-v1.1-stage7c-rc2` at `afa54c2e02e7e91430b14b6884faff5e3f5867d9`.

## Implemented release controls

- `config/testnet-release.schema.json` and its deliberately non-authorizing example define only `local`
  or `testnet`, bind the existing PoolManager EXTCODEHASH, creation/runtime artifacts, stores, salts,
  predictions, economic limits, finality, RPC environment-variable names and zero-value policy.
- `swaputer-release preflight` verifies a captured observation without a network connection.
  `swaputer-release live-preflight` optionally obtains the same facts through read-only JSON-RPC selected
  only by an authorized environment-variable name. Neither command sends a transaction or accepts a key.
- `Stage7A2DeployScript` now rejects every environment except `local`/`testnet`, rejects known mainnet
  chain IDs, requires the exact unaudited rc2 identity and exposes no override/skip flag. Local mode is
  restricted to chain 31337.
- canonical deployment manifests now carry a mandatory machine-readable `release` object:
  `auditStatus=unaudited`, `economicValue=none`, `publicMainnetDeploymentAllowed=false`, and no audited
  artifact. Clients can fail closed without parsing prose.

## Isolated Anvil rehearsal

`tooling/stage7d/stage7d-u1-e2e.mjs` starts an isolated chain with an ephemeral in-memory local-only key,
never connects to a public RPC, and removes its temporary SQLite databases and manifests. Four full
production-Factory/production-Router releases passed with different salts and the following economic
vectors:

| Vector | byteGasPrice | Pool fee | Tick spacing | Result |
| --- | ---: | ---: | ---: | --- |
| 1 | 1,000,000,000 | 500 | 10 | canonical PASS |
| 2 | 1,000,000,000,000 | 3,000 | 60 | canonical PASS |
| 3 | 10,000,000,000,000 | 10,000 | 200 | branch A PASS, then orphaned |
| 4 | 10,000,000,000 | 3,000 | 60 | replacement branch PASS |

Each release deployed the real PoolManager, creation-code stores, Factory, Registry, Router, GasToken,
one-shot WorldDeployer, Kernel and permission-bit Hook; sealed a unique pool; bootstrapped project-owned
valueless liquidity; ran NOP buy, reference SRC-20 DEPLOY/CALL, TinySol MiniToken DEPLOY/CALL, sell,
explicit VM revert and OutOfByteGas rollback; then withdrew the project LP position. Each release indexed
exactly five successful VM executions. The failing buys committed no height or burn, and sell committed no
VM execution. Three canonical manifests were reconstructed from confirmed `WorldSealed` logs and runtime
code and passed strict manifest/chain-observation verification.

An Anvil snapshot/revert replaced vector 3 with vector 4. Re-scanning the vector-3 Kernel preserved all
five receipts as orphan history and left zero canonical executions. The replacement converged to five
canonical executions. Repeated scans and process-style database reopen were idempotent.

## Indexer operations

The indexer exports compact JSON health with chainId, Kernel, cursor, head, finalized height, RPC lag,
reorg count/depth, quarantined/malformed counts, execution-height gaps, unknown code hashes, ABI failures,
database bytes and canonical/finalized/orphan counts. It adds environment-name-only multi-RPC policy,
graceful shutdown, SQLite online backup, integrity-checked restore and raw-receipt-preserving derived-view
rebuild. Tests prove backup/restore and reject destination overwrite.

Operational responses are recommendation and migration actions only: stop official UI/Router
recommendation, deprecate the manifest/World, publish notice, stop new project liquidity, withdraw feasible
project LP, retain evidence, deploy a new immutable World and publish migration instructions. No pause,
freeze, forced third-party withdrawal or old-World upgrade exists.

## Security and disclosure package

`SECURITY.md` and `docs/security/` contain a draft bounty policy, severity matrix, responsible disclosure,
contact runbook and incident response. Reward values and response SLAs remain explicit `TBD` placeholders;
there is no funded or live bounty. Monitoring, alerts, recovery and testnet release procedures live under
`docs/operations/` and use no hosted dashboard or alert provider.

## Acceptance

The single entry point is:

```sh
./script/accept-stage7d-u1.sh
```

It begins by running the complete Stage 7B gate, then release/manifest tests, indexer health and recovery,
four Anvil release rehearsals, release-policy Solidity tests, documentation checks, Foundry format/build/
snapshot checks, all four npm audits, rc2 snapshot identity verification and `git diff --check`.

Remaining blockers for real funds are: independent Stage 7C audit and remediation/acceptance; resolution or
explicit independent assessment of S7B-002; funded bounty/contact/legal decisions; chain-specific
PoolManager and infrastructure validation; economic/MEV parameter approval; monitored zero-value public
testnet soak; operational staffing and explicit deployment authorization.
