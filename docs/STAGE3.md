# SwapVM v1.0 — Stage 3 implementation report

## Implemented scope

Stage 3 extends the Stage 1/2 real-Uniswap-v4 prototype without changing the frozen wire format, ISA, package format or freeze artifacts:

- exact `ProgramPackageV1` decoding (`SVM1`, VM version 1, big-endian constructor/runtime entries and code length, ABI hash and exact code bytes), whole-package `keccak256` identity, opcode validation and entry-boundary validation;
- immutable per-World package storage and contract code instances, canonical tagged contract IDs and per-creator `uint64` creation nonces;
- swap-gated root `DEPLOY`, constructor calldata execution, immutable runtime entry selection and root-success atomic registration;
- nested `CALL` and `STATICCALL` with frozen stack arguments, isolated frame stack/memory/calldata/return-data, copied output, propagated static mode and contract storage namespaces;
- `CREATE` from an already registered same-World package hash, constructor execution, deterministic ID derivation, same-transaction calls to pending deployments and creator-nonce commit;
- one shared executed-byte meter across the entire call tree, maximum depth 32, 65,536 bytes of memory per frame and 262,144 bytes across active frames;
- one root-success storage/deployment journal, so constructor failure, child failure, out-of-byte-gas, depth/memory failure, PoolManager settlement failure or burn failure leaves no package, instance, creator nonce, actor nonce, storage, height, supply change or VM log;
- `MiniContractDeployed(bytes32,bytes32,bytes32)` records for root and internal deployments, followed by the frozen Kernel `WorldExecution` summary, all aggregated into the execution's single `VMLog`.

The existing Hook settlement remains unchanged: only native ETH-to-TOKEN exact-input buys enter SwapVM. On success it takes the actual `executedBytes * byteGasPrice` from the unspecified output currency, burns those TOKEN immediately, returns the same positive Hook delta, and the buyer receives gross output minus the burn. TOKEN-to-ETH exact-input and exact-output sells still execute no VM, burn nothing and leave VM state unchanged.

The production Kernel exposes no arbitrary program installer. `SwaputerKernelStage2Harness.install` remains a test-only facility for isolated ISA and nested-call fixtures; production packages enter through signed root `DEPLOY` and internal `CREATE` only. No external EVM call opcode or target is introduced.

## Package, deployment and call atomicity

Root `DEPLOY` parses its payload as a four-byte big-endian package length, the exact package bytes and all remaining constructor calldata. The signed `targetOrCodeHash` must equal the package hash. Its contract ID is derived from World, recovered actor AccountId, the actor's current creator nonce and code hash. The constructor runs at the declared constructor entry, while subsequent calls begin at the runtime entry.

Internal `CREATE` accepts a registered code hash and constructor-input memory slice. Deployments remain pending in the execution journal until the root succeeds, but nested code can resolve and call a pending contract in the same action. Storage writes are journaled by `(contractId, slot)`. A successful root commits all writes and deployments before advancing the actor nonce and execution height and emitting exactly one receipt log; any revert unwinds the complete v4 swap transaction.

Nested `CALL`/`STATICCALL` frames inherit World and transaction context while receiving the correct `ADDRESS`, `CALLER`, calldata and static flag. The parent resumes with the child's cumulative byte count, storage/deployment journals and return data. No caught-failure status exists in v1: exceptional child failure reverts the root.

## Verification results

The Stage 3 checkpoint verification used Foundry `1.5.1-stable`, Solidity `0.8.26`, Cancun semantics, IR compilation and optimizer runs `20,000`:

- `forge fmt`, `forge build --sizes`, `forge test -vvv` and `forge snapshot` all succeeded;
- 52 tests passed and none failed across Stage 1-3;
- eight fuzz properties ran 512 cases each, including arbitrary constructor calldata/value deployment and deterministic contract ID/storage/burn checks;
- four stateful real-v4 invariants each ran 64 runs × 32 calls = 2,048 actions with zero handler reverts, continuously reconciling height, actor nonce, byte counts, TOKEN supply, Hook balance and PoolManager transient deltas;
- production runtime sizes are 23,873 bytes for `SwaputerKernel`, 7,859 bytes for `SwaputerHook` and 2,010 bytes for `SwaputerToken`; the Kernel retains 703 bytes below EIP-170;
- representative snapshot costs are 684,846 gas for root package deployment and constructor execution, 944,693 gas for a nested call with storage/return-data propagation, and 1,528,136 gas for the multi-transaction package/factory/internal-creation scenario. The depth/memory rejection test costs 23,083,612 gas because it deliberately constructs deep recursive test executions. These are Foundry test-function figures, not production Router estimates.

Stage 3 tests specifically decode the 438-byte root-deployment receipt, verify version/record count/selectors/contract/creator/code hash/summary fields, verify the internal deployment record plus final summary, exercise malformed magic/length/entry points, and prove successful/failed constructors, nested metering, static propagation, cross-contract storage isolation, return-data copying, call-depth limits, active-memory limits, creator nonces, exact supply burn and zero PoolManager transient deltas.

## Authentication status and residual risk

The v1.0 actor-binding conflict discovered during Stage 2 is resolved by the frozen v1.1 wire format and Kernel check documented in `docs/proposals/SwapVM-v1.1-actor-binding.md`. Authenticated `CALL` and `DEPLOY` now bind nonce state and AccountId derivation to the explicit signed actor. v1.0 signed actions are rejected.

The custom VM, package/deployment logic and v4 accounting are unaudited. Production Router, WorldFactory and World sealing, SRC standards, mini-AMM, TinySol, virtual `LOG0..LOG4` records and later-stage system contracts are out of Stage 3 scope. The receipt record cap is enforced at 64 records. No public-network deployment was performed.
