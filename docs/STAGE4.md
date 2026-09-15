# SwapVM v1.0 — Stage 4 implementation report

## Implemented scope

Stage 4 publishes three deterministic, immutable `ProgramPackageV1` reference programs without adding a privileged Kernel asset ledger:

- SRC-165 interface discovery using exact four-byte interface IDs;
- SRC-20 balances, allowances, transfer, approval, delegated transfer, fixed supply and conventional virtual `Transfer`/`Approval` records;
- SRC-721 ownership, balances, token approval, operator approval, delegated transfer, URI hash and virtual `Transfer`/`Approval`/`ApprovalForAll` records;
- SRC-1155 per-ID balances, operator approval, single transfer, URI hash and virtual `TransferSingle`/`ApprovalForAll` records;
- an immutable, administrator-free `SwaputerProgramRegistry` that recognizes a reference only when interface ID, exact ABI hash and exact whole-package code hash all match;
- a deterministic reviewed assembler/generator and machine-readable artifacts containing exact ABI strings, selectors, event topics, package bytes and hashes.

The reference programs use frozen tagged `bytes32 AccountId` values. Mini-contract AccountIds can own all three asset types. Minting is constructor-only in these minimal references; caps, later mint/burn, royalties, soulbound rules and other policies remain application logic as required by the frozen specification.

The exact reference identities are:

| Standard | Interface ID | ABI hash | ProgramPackageV1 code hash |
| --- | --- | --- | --- |
| SRC-20 | `0x2633673d` | `0xf286f500d4395f9fbb4b97ce7d1ac7840507066f2de7d595433dca18b4490067` | `0x8699a93b015eb99ed1e30d713f1183f710eb92d6bbdb92fd7086490e84fde792` |
| SRC-721 | `0xfd386dba` | `0x123327446b41849e72eb3b41f073d20c3f12cf346af19f02d4aa6311a5285c00` | `0x473bc4130c5de9e9981bca274ea85f315c5e7f67aa6654f675ec3b49475c8aad` |
| SRC-1155 | `0xb9544cff` | `0x7daaf0b8583b5027779e7b2a4b8558b6b3bb0431fc7ff7c589f0a072ccd5e070` | `0x258c71844de4694f71453b9aabe1344ce6f43061ffc61fdc85e5940af66404ed` |

The exact ABI and return encodings are published in `reference/*.json`. Metadata returns are fixed `bytes32` values/hashes. The minimal SRC-1155 v1 reference exposes single transfer rather than a batch extension; a batch-capable package must publish a different ABI/interface/code hash.

## Virtual records and receipt bounds

Canonical asset mutations require virtual records, so Stage 4 implements the directly required `LOG0..LOG4` portion of the later aggregate-receipt stage. The interpreter injects the active contract AccountId as emitter, preserves actual constructor/nested-call execution order, and aggregates every record into the execution's sole Kernel `VMLog` before the final `WorldExecution` summary.

The frozen bounds are enforced atomically:

- at most four topics;
- at most 4,096 data bytes per record;
- at most 64 total records including Kernel records;
- at most 65,536 encoded payload bytes;
- every `LOGn` is forbidden throughout static execution;
- any record, payload, child, settlement or burn failure rolls back logs, asset state, package/deployment state, nonce, height and real TOKEN supply.

Internal deployment records are inserted after successful constructor execution. Root deployment records are inserted after the root constructor. The final execution summary remains the last record. No user bytecode can choose or impersonate its emitter.

## Conformance and invariant results

Final local verification used Foundry `1.5.1-stable`, Solidity `0.8.26`, Cancun semantics, IR compilation and optimizer runs `200`:

- `forge fmt --check`, `forge build --sizes`, `forge test -vvv` and `forge snapshot` succeeded;
- 61 tests passed, none failed;
- nine fuzz properties ran 512 cases each, including SRC-20 transfer conservation;
- six stateful invariants each ran 64 runs × 32 calls = 2,048 actions with zero handler reverts;
- the Stage-4 asset handler continuously alternated signed transfers between two actors and reconciled model balances, one-million-unit mini supply, actor nonces, execution height, actual byte burn, Hook balance and all PoolManager transient deltas;
- conformance covers SRC-165, metadata, supply/balance/ownership, approvals, delegated calls, contract-owned assets, virtual topics/data/emitter, failed overdraw rollback and static mutation rejection;
- adversarial receipt tests cover nested emitter order, oversized record data, record-count exhaustion and total-payload exhaustion.

With optimizer runs `200`, production runtime sizes are 21,658 bytes for `SwaputerKernel`, 5,769 bytes for `SwaputerHook`, 1,350 bytes for `SwaputerToken` and 1,325 bytes for `SwaputerProgramRegistry`. Kernel margin below EIP-170 is 2,918 bytes. The change from the Stage-3 checkpoint's 20,000 runs was necessary because the bounded virtual-record code otherwise exceeded EIP-170 by 936 bytes; no protocol or ISA semantics changed.

Representative Foundry test-function costs are 342,225 gas for exact registry verification, 717,130 gas for a nested two-emitter receipt, 22,038,533 gas for the multi-transaction SRC-20 conformance/rollback scenario, 13,733,401 gas for SRC-721 and 10,079,358 gas for SRC-1155. These figures include fixture and multiple real-v4 swaps and are not single production Router-call estimates.

## Authentication status and remaining scope

The v1.0 EIP-712 actor-binding conflict is resolved in frozen v1.1. Every reference-asset call and deployment now signs an explicit actor and the Kernel checks recovered equality before nonce lookup. The reference packages themselves are unchanged because the correction affects only the outer action envelope.

The reference packages, custom interpreter and v4 settlement remain unaudited. At the Stage-4 checkpoint, the Stage-5 reference mini-AMM was not yet implemented; its later implementation is documented in `docs/STAGE5.md`. Stage 6 still needs the reference indexer, malformed-payload/reorg suite, TinySol compiler, disassembler, simulator and independent byte estimator; only the virtual-log/receipt-builder prerequisite needed by canonical Stage-4 assets was brought forward. No public-network deployment was performed.
