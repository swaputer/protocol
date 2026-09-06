# Auditor brief

## Workflow A — onchain and Uniswap v4 safety

Trace the complete production path and its atomic rollback properties:

1. `SwapVMHook` custom accounting, unspecified-currency return delta, `take`, burn and exact-input-only VM entry.
2. PoolManager unlock, delta accounting, `take`/`settle`, recipient delivery and zero terminal transient deltas.
3. `SwapVMRouter` active transient commitment, callback identity/data binding, payer budget, forced ETH and
   accidentally transferred TOKEN isolation, recipient reentrancy and sell bypass.
4. Factory/WorldDeployer CREATE/CREATE2 prediction, one-shot deployment, permission-bit mining, PoolManager
   codehash binding, pool initialization, sealing and `configHash` immutability.
5. Kernel EIP-712 actor/router/world/recipient/executor/input/price binding, nonce/replay behavior, height,
   receipts and exact burn accounting.
6. MiniVM validation, journal commit/rollback, CALL/STATICCALL/CREATE, storage/world isolation, static
   descendants, shared byte meter, call/memory/receipt limits and exceptional halts.
7. GasToken fixed supply, Hook-only burn and ERC-20 transfer/supply invariants.
8. Immutable reference hashes, package validation, SRC programs and CPAMM accounting.

Focus on cross-component failure ordering: a failure after swap, deployment, nested write or virtual event
must revert PoolManager settlement, VM state, nonce/height, logs and TOKEN supply together.

## Workflow B — toolchain and data integrity

Review the independent offchain parsing and commitment boundaries:

1. Strict `VMReceiptV1` codec, no partial result, Kernel summary uniqueness/order and unknown-record losslessness.
2. VMLog selection, canonical indexing, idempotence, SQLite migrations and reorg/orphan convergence.
3. ABI descriptors and verified-reference trust only under exact `worldId + emitter + immutable codeHash` binding.
4. ISA generation, assembler/disassembler, package validation, TinySol compiler and reproducible fixtures.
5. TypeScript simulator/Solidity differential semantics and exact/conservative/unavailable fee-estimation labels.
6. Deployment-manifest strict JSON, canonicalization, unsigned hash boundary, EIP-191 recovery, low-s enforcement,
   observation reconstruction and artifact/source/compiler/reference commitments.
7. This snapshot's source hashes, artifact hashes, fixed submodule gitlinks and locked npm dependencies.

Do not infer application-event authenticity from Transfer-shaped topics. Do not treat publisher signatures,
the indexer, simulator or UI as chain-consensus authorities.
