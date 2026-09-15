# SwapVM v1.0 — Stage 2 implementation report

## Implemented scope

This tree extends the Stage 1 real-Uniswap-v4 prototype with the frozen Stage 2 kernel boundary:

- immutable EIP-712 domain and `VMAction` hash, low-`s` EOA recovery, per-World/per-actor sequential nonces and deadline checks;
- tagged EOA, contract, Kernel and zero `AccountId` namespaces;
- immutable World/contract-namespaced test program registration, persistent storage, root-success journaling and public `staticCall`;
- the frozen v1 validator, 1,024-word stack, 65,536-byte memory, calldata/return-data handling, storage, jumps, context, crypto and a single-frame executed-byte meter;
- signed exact-input ETH-to-TOKEN `CALL` integration through the real `PoolManager` unlock/settlement path;
- checked `actualBurn = executedBytes * byteGasPrice`, positive unspecified-currency Hook delta, immediate TOKEN burn and aggregate one-log receipt;
- Stage 1 empty-data NOP buys and ordinary sells remain compatible.

The production Kernel does not expose program installation. `SwaputerKernelStage2Harness.install` exists only under `test/` because canonical deployment, `ProgramPackageV1`, immutable code storage and `CREATE` begin in Stage 3.

Stage 2 deliberately recognizes but does not execute `CREATE`, nested `CALL`/`STATICCALL`, or virtual `LOG0..LOG4`; those are Stage 3/6 work. The meter is shared across the complete active execution in this Stage 2 implementation, which currently has one frame. It becomes call-tree-shared when nested frames are added in Stage 3.

## Settlement and atomicity

For a valid signed CALL, the Router binds recipient and executor, the Hook reconstructs the actual pool, exact ETH input, price limit and callback Router, and the Kernel validates the envelope before running immutable code. Writes remain in a journal until successful halt and all nonce, storage, byte count, height and receipt changes revert together if the PoolManager callback, VM execution, output checks, take or burn fails.

Successful execution returns its actual byte count to the Hook. The Hook takes exactly `executedBytes * byteGasPrice` output TOKEN, burns it from its own balance, and returns the same positive unspecified-currency delta. The Router settles the buyer's net output and verifies no PoolManager transient delta remains.

## Verification coverage

`test/SwapVMStage2.t.sol` covers real-v4 authenticated buys, receipt decoding, actual byte burn and supply reconciliation, state/static differential behavior, replay, relay/executor rules, expiry and signature malleability checks, explicit revert and out-of-byte-gas rollback, invalid jumps, malformed code, stack/memory/halt limits, tagged accounts, context/meter opcodes, crypto, calldata zero padding and differential arithmetic/bitwise/shift execution.

`test/invariant/SwapVMStage2Invariant.t.sol` mixes signed one-byte and loop programs, unsigned NOP buys and ordinary sells through the real PoolManager. It continuously reconciles height, actor nonce, last/total executed bytes, total supply, empty Hook balance and zero transient deltas.

Final local verification used Foundry `1.5.1-stable`:

- `forge fmt --check` and `forge build --sizes` succeeded;
- `forge test -vvv`: 44 tests passed, 0 failed (Stage 1 and Stage 2 together);
- seven fuzz properties ran 512 cases each;
- four stateful invariants each ran 64 runs × 32 calls = 2,048 real-v4 actions with zero handler reverts;
- production runtime sizes are 15,670 bytes for `SwaputerKernel`, 7,859 bytes for `SwaputerHook`, and 2,010 bytes for `SwaputerToken`, all below EIP-170;
- `forge snapshot` succeeded. The authenticated 20-byte state-changing buy test uses 425,554 gas, the 28-byte loop/static meter test 215,830 gas, the state-reading `staticCall` differential test 502,336 gas, and the Stage 1 end-to-end NOP buy 265,635 gas. These include test setup/call-path effects and are not production Router estimates.

## v1.1 authentication resolution

Stage 2 uncovered a protocol-level conflict in v1.0: the frozen `VMEnvelope` and EIP-712 `VMAction` contained no expected actor. A signature reused against a changed digest could recover a different fresh actor whose nonce was also zero.

SwapVM v1.1 resolves the conflict by adding an explicit signed `address actor`, changing the EIP-712 domain version to `"1.1"`, and requiring `ecrecover(digest, signature) == actor` before nonce lookup. VM AccountId derivation now uses only that verified actor. Recipient and permissionless-relay semantics remain independent.

The previous positive exploit regression has been replaced by rejection tests covering changed first-nonce envelopes, actor substitution and v1.0 domain/type signatures. v1.0 signed actions are intentionally incompatible; unsigned NOP behavior, ISA, receipt codec and program packages are unchanged.

See `docs/proposals/SwapVM-v1.1-actor-binding.md` and the v1.1 frozen specification. This correction removes the known actor-reclassification issue but does not replace an independent audit.

## Out of scope and residual risk

Stage 3+ features remain absent: swap-gated DEPLOY, canonical packages/code store, creator nonces, nested calls/creation/metering, SRC standards, mini-AMM, virtual records, TinySol, production Router, WorldFactory/sealing and public deployment. The custom interpreter and v4 accounting are unaudited. All Stage 2 registrations and Routers in `test/` are fixtures, not deployable protocol components.
