# Stage 7A1-P executable design proof

Stage 7A1-P resolves two pre-implementation questions without adding production Solidity: the Hook/Kernel address cycle and the canonical Router input model.

## Deliverables

- `test/WorldDeployerProbe.sol`: test-only immutable Factory, one-shot per-world deployer and helper Factory.
- `test/SwapVMStage7A1P.t.sol`: direct-cycle counterexamples plus deterministic deployment, binding, permissions, access control, collision and rollback tests.
- `docs/security/WORLD-FACTORY-DESIGN.md`: corrected address equations and Stage 7A2 deployment algorithm.
- `docs/security/ROUTER-INTERFACE.md`: exact minimal ABI using `SwapVMKernel.VMEnvelope` directly.
- updates to `docs/STAGE7-PLAN.md` and `docs/security/RELEASE-SURFACE-GAP.md`.

No file under `src/` and no frozen specification, ISA, manifest or reference package is changed by this stage.

## Address-cycle result

Direct Factory CREATE2 deployment is circular:

```text
K = CREATE2(factory, saltK, keccak256(KernelCreationCode || H || price))
H = CREATE2(factory, saltH, keccak256(HookCreationCode || manager || K || token || ...))
```

The tests show that a Hook prediction made from a placeholder K changes after K is derived, and that attempting to deploy the resulting pair fails the existing Hook constructor binding check. This is not solvable merely by calculating the two addresses in a different order.

The tested construction is:

```text
P = CREATE2(factory, bootstrapSalt, fixedProbeInitCodeHash)
K = CREATE(P, nonce = 1)
H = CREATE2(P, minedHookSalt, exactHookInitCodeHash(K, ...))
```

K no longer depends on H's init code, so H can be mined after P and K are fixed. The proof keeps the existing Hook and Kernel constructors unchanged.

The first implementation using Solidity `new` embedded both production creation codes in P and exceeded EIP-170. The accepted proof instead binds the exact Kernel and Hook base creation-code hashes in P, accepts code only from its immutable Factory, verifies both hashes, appends the exact constructor arguments, then executes low-level CREATE/CREATE2. This preserves the one-shot, non-arbitrary deployment surface while keeping runtime bytecode deployable.

## Proof assertions

The Stage 7A1-P suite explicitly checks:

1. naive one-pass address prediction is not a fixed point;
2. naive two-pass deployment fails Hook's `kernel.hook() == address(this)` check;
3. P/K/H predicted and actual addresses match;
4. Hook permission bits are exactly `afterSwap | afterSwapReturnDelta`;
5. Kernel↔Hook, PoolManager and byte-gas-price bindings match;
6. incorrect Kernel prediction rolls all new contracts back;
7. a failure through an already-deployed P rolls back its `used` flag and Kernel child;
8. incorrect Hook salt/binding rolls the complete create transaction back;
9. a successful P is one-shot;
10. reusing a bootstrap salt/occupied P fails;
11. an occupied Hook target fails and rolls new P/K back;
12. a non-Factory caller cannot consume or use P.

## Router freeze result

The Router has only four public operations:

```solidity
buyNOPExactInput(worldId, minTokenOut, sqrtPriceLimitX96, recipient)
buyVMExactInput(worldId, sqrtPriceLimitX96, SwapVMKernel.VMEnvelope envelope)
sellExactInput(worldId, exactTokenAmountIn, minEthAmountOut, sqrtPriceLimitX96, recipient)
unlockCallback(callbackData)
```

The VM route does not accept a second params struct, separate payload/hash, separate hookData, or duplicate gas/nonce/deadline fields. It passes `abi.encode(envelope)` once. Actual exact ETH input, price limit, Router and signed recipient are bound through the unchanged Hook/Kernel v1.1 authentication path. `byteGasPrice` comes from the immutable World Hook, not the caller.

## Stage 7A2 gate

The architecture is executable without a frozen-protocol change. Stage 7A2 may begin after this proof passes, but must not copy the test helper blindly: the production Factory, per-world deployer and Router must be implemented under `src/`, subjected to the existing full test matrix, and included in the later independent audit scope.

## Validation snapshot

- `forge test --match-path test/SwapVMStage7A1P.t.sol -vvv`: 10 passed, 0 failed, 0 skipped.
- `forge test -vvv`: 12 suites, 108 passed, 0 failed, 0 skipped, including existing fuzz and invariant runs.
- `forge fmt --check`: passed.
- `forge build --sizes`: passed.
- `forge snapshot --check`: passed after adding only the 10 new proof entries.
- `git diff --check`: passed.
- `WorldDeployerProbe`: 1,784-byte runtime, 1,973-byte initcode.
- `WorldDeployerProbeFactory`: 3,976-byte runtime, 4,956-byte initcode.
- Production `SwapVMKernel` remains 21,918 bytes and `SwapVMHook` remains 5,842 bytes; no `src/` code was changed.
