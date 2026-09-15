# Stage 6E: release-candidate total acceptance

Stage 6E closes the Stage 6 release-candidate gate without changing the frozen v1.1 specification, ISA, manifests, reference packages or production `SwaputerKernel`, `SwapVMMiniVM` and `SwaputerHook`. The executable gate is `./script/accept-stage6.sh`; local development and CI run the same command after installing the three locked npm workspaces.

## Production-path E2E

`tooling/stage6e/stage6e-e2e.mjs` starts an isolated Anvil chain and uses `script/Stage6EE2E.s.sol` to deploy the real Uniswap v4 `PoolManager`, `SwaputerHook`, `SwaputerKernel`, `SwaputerToken`, `SwaputerProgramRegistry`, settlement Router and ETH/TOKEN pool. It then submits, through `PoolManager.unlock`, a signed reference SRC-20 DEPLOY buy, a signed SRC-20 CALL buy, a compiled TinySol MiniToken DEPLOY/CALL pair, a TOKEN-to-ETH exact-input sell, an explicit VM revert and an OutOfByteGas buy. No Driver invokes the Kernel for this acceptance path.

The successful SRC-20 CALL is quoted before submission. The TypeScript simulator executes the exact concrete action and the estimator approves its maximum-exposure condition. The E2E then compares the transaction trace, strict receipt, token balances, total supply and Kernel storage against the simulation. One recorded local run produced:

| Evidence | Value |
| --- | ---: |
| transaction | `0x3bb91378f3890aee9038afed64dffa631002d3cedef56c19f3419b18b5fc9f10` (ephemeral local chain only) |
| Ethereum logs in transaction | 5 |
| matching Kernel `VMLog` | 1 |
| execution height | 2 |
| executed bytes | 278 |
| byte gas price | 1,000,000,000,000 |
| estimated and actual burn | 278,000,000,000,000 |
| gross TOKEN output | 996,997,017,979,937,173 |
| estimated and actual net output | 996,719,017,979,937,173 |
| maximum TOKEN exposure | 5,000,000,000,000,000 |
| minimum net output | 1 |

The ordered receipt is application `Transfer(bytes32,bytes32,uint256)` followed by the unique final Kernel `WorldExecution`. The trace return data is the ABI word `true`. The simulator and chain agree on output, 278 executed bytes, both balance mapping writes, record bytes/order and committed state. Supply decreases by exactly the burn and the actor balance increases by exactly the net output. The transaction's PoolManager/ERC-20 logs are ignored because selection requires both the bound Kernel address and exact `VMLog(bytes32,uint64,bytes)` topic.

The sell has zero attributable VM bytes, no Kernel log, no burn and no height change. Both failing buys have status zero and preserve height, supply, storage, deployments and records. The test-only Router reads v4 transient state after every path and requires its nonzero-delta count to be zero.

## Codec, indexer and ABI proof

Every actual outer log is decoded by Stage 6A, re-encoded byte-identically and checked for one final summary. Stage 6B indexes the four real branch-A buys as four executions; record counts equal the expanded receipts exactly. A second scan and a database close/reopen scan insert nothing. The raw CALL payload in SQLite is byte-identical to the transaction log.

The reference SRC-20 deployment binds to `verified_reference` only through its exact immutable code hash. The compiler MiniToken's Transfer-shaped event binds only to its explicitly registered `declared_unverified` descriptor; no verified-reference binding exists for that code hash. The four branch-A executions contain three decodable application events because the compiler MiniToken constructor emits no event.

After an Anvil snapshot/revert, four real replacement NOP buys form branch B. The same database reports one reorg, four canonical replacement executions and four retained orphan executions. Canonical derived events converge to zero, the three branch-A decoded events remain attached to orphan history, and the old raw receipt remains unchanged.

## Acceptance matrix

The unified command executes:

- receipt codec build, typecheck, 31 tests and v1.1/ISA/v1.0 manifest checks;
- indexer build, typecheck, 45 mock/ABI/reorg tests, migration 002 validation, registry drift checks and both earlier Anvil E2Es;
- TinySol build, typecheck, 62 tests, 132-opcode ISA/Solidity drift, four reference roundtrips, 292-code/12-package corpus, nine compiler fixture identities, 28 simulator scenarios plus 64 Solidity projections;
- Foundry formatting, production sizes, 98 tests including fuzz/invariants, and the locked gas snapshot;
- the real-v4 Stage 6E production-path and reorg E2E;
- all three `npm audit` checks and `git diff --check`.

Production runtime sizes remain `SwaputerKernel` 21,918 bytes, `SwaputerHook` 5,842 bytes, `SwaputerToken` 1,350 bytes and `SwaputerProgramRegistry` 1,606 bytes. The Stage 6E-only Router and failure executor are 3,807 and 1,359 bytes and are not production protocol components.

Frozen identities remain:

- v1.1 spec Keccak-256 `0x14cc901e0e64de666e9230a331bd40d52e3a4fd07d64c8d5f4cb01a63e5a3339`;
- ISA v1 Keccak-256 `0x2f0059846af771cb9f77e74d5f728744a9b8dbe69313d146b8a5e7fdcbe7c118`;
- historical v1.0 spec Keccak-256 `0x5afc0976e2aeba97a2f2fc3df131dcdfad74969ed6177416a7a1d23610da1c00`;
- compiler source fingerprint `0x90dc23464f9d04da55862e15dec7b4fd1d61421ca04b81074c11920a6e2af5ec` and lock SHA-256 `3e0d2b5bc7d7dcd143f252ad7f77d28c37ab5474504ddc2f9a2643690918d911`;
- indexer schema/migration version 2.

## Release boundary

Stage 6 is complete as a local release candidate. No consensus mismatch was found. This does not authorize public deployment: the contracts and toolchain remain unaudited; the Kernel has limited EIP-170 margin; independent review, deeper stateful/adversarial fuzzing, operational key/RPC/indexer hardening, economic and MEV analysis, incident response, a bug bounty and capped test deployment policy remain Stage 7 gates. No frontend, public RPC connection or public deployment is part of Stage 6E.
