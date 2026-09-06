# SwapVM v1.0 — Stage 1 implementation

## Implemented scope

Stage 1 implements one immutable native ETH / `SwapVMGasToken` v4 World:

1. An exact-input ETH-to-TOKEN swap reaches `SwapVMHook.afterSwap` with empty `hookData`.
2. The Hook reads the positive output/unspecified TOKEN delta as gross output and requires `grossTokenOut > byteGasPrice`.
3. The bound Kernel executes the canonical one-byte `STOP`, records `executedBytes = 1`, advances the World execution height, and emits one `VMLog` containing one Kernel `WorldExecution` record.
4. The Hook calls `PoolManager.take` for exactly `byteGasPrice` TOKEN, burns those tokens from its own balance, and returns the same positive unspecified-currency delta.
5. The official test Router receives and settles exactly `grossTokenOut - byteGasPrice` for the buyer. The PoolManager's transient delta count and the Router/Hook currency deltas are zero when unlock completes.

TOKEN-to-ETH exact-input and exact-output sells branch out before Kernel entry. Empty sell data returns a zero Hook delta; non-empty sell data reverts.

## Receipt encoding

The Stage 1 payload is a 269-byte `VMReceiptV1`:

- version `1`, flags `0`, record count `1`;
- one 261-byte record body;
- reserved Kernel emitter ID `0xff00…0001`;
- one topic, `keccak256("WorldExecution(bytes32,bytes32,uint32,uint256,uint256,uint256)")`;
- 192 bytes of canonical 32-byte words for zero actor, zero NOP root target, executed bytes, token burned, gross TOKEN output, and net TOKEN output.

## Verification coverage

`test/SwapVMStage1.t.sol` covers:

- exact Hook permission bits;
- frozen VM/receipt versions and ISA hash embedded in the Kernel;
- real PoolManager ETH-to-TOKEN buys and both TOKEN-to-ETH sell modes;
- gross, returned Hook delta, actual buyer balance, Hook balance, burn `Transfer`, and `totalSupply` reconciliation;
- strict receipt length/count/emitter/topic/summary decoding and unique indexer identification;
- insufficient-output atomic rollback, exact-output buy rejection, and sell-instruction rejection;
- PoolManager-only Hook access and bound-Hook-only Kernel access;
- transient-delta settlement;
- fuzzed buy sizes, sell modes/directions, delta signs, and integer conversion boundaries.

`test/invariant/SwapVMStage1Invariant.t.sol` runs random real-v4 buy/exact-input-sell/exact-output-sell sequences and continuously checks:

```text
executionHeight == successfulBuyCount
totalSupply == initialSupply - successfulBuyCount * byteGasPrice
last executedBytes == 0 before a buy, otherwise 1
Hook TOKEN balance == 0
all PoolManager transient deltas == 0
```

Final local verification used Foundry `1.5.1-stable`:

- `forge test -vvv`: 21 tests passed, 0 failed (including five 512-case fuzz tests);
- each of two stateful invariants: 64 runs × 32 calls = 2,048 randomized real-v4 actions, with zero handler reverts;
- `.gas-snapshot` generated successfully.

The gas report for this test configuration records 22,715 gas for the first `SwapVMKernel.executeNOP` call, a 25,263 gas median for `SwapVMHook.afterSwap` across buy/sell and boundary calls, and a 201,235 gas median for the official `PoolSwapTest.swap` calls in the suite. The end-to-end proof test snapshot is 263,775 gas. These are local test-harness figures, not production Router estimates.

## Out of scope

As required for Stage 1, this repository does not implement DEPLOY, CALL, signed envelopes, nonce handling, the general ISA interpreter, TinySol, SRC assets, mini-AMMs, a production Router, WorldFactory, public deployment, or upgrade machinery.

## Specification alignment and residual risk

No frozen protocol semantic or ISA conflict was found. The requested Stage 1 prototype brings the aggregate NOP receipt forward from the broader Stage 6 implementation order, but uses the frozen v1 receipt bytes and does not change their semantics.

This is an unaudited prototype. A production World still needs the frozen manifest/sealing flow (including explicit runtime code-hash sealing), canonical production Router, deployment/code-hash tooling, independent review of custom accounting, larger stateful campaigns, and the later-stage VM features. The Stage 1 Hook binds its PoolManager, Kernel, Gas Token, byte price, LP fee, tick spacing, currencies, and own Hook address immutably, but it is not a replacement for the complete deployment manifest. Neither the frozen files under `docs/spec/` nor their contents are changed by Stage 1.
