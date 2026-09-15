# Stage 7A2 WorldFactory deterministic deployment design and implementation

This document replaces the sequential CREATE2 prediction described in Stage 7A1-R. Stage 7A1-P supplied the independent executable proof; Stage 7A2 implements the same shape in `src/SwaputerWorldFactory.sol`, `src/SwaputerWorldDeployer.sol`, and immutable creation-code stores without changing Hook or Kernel.

## 1. PoolManager model

`SwaputerWorldFactory` does not deploy PoolManager. Stage 7A2 shall use one immutable Factory per supported, already-deployed PoolManager:

- the Factory constructor binds `poolManager` and the expected `extcodehash`;
- there is no method to replace either value;
- every World uses a unique PoolKey in that PoolManager;
- `worldId = PoolId.unwrap(poolKey.toId())` exactly;
- PoolManager identity is committed independently by the Factory configuration and deployment manifest; it is not mixed into `worldId`.

This is model A from Stage 7A1-R. It has fewer branches and no Manager selection or governance surface at world creation time.

## 2. The actual Hook/Kernel address cycle

If both contracts are deployed directly by the Factory with CREATE2, their addresses are mutually recursive:

```text
K = CREATE2(factory, saltK, keccak256(KernelCreationCode || H || price))
H = CREATE2(factory, saltH, keccak256(HookCreationCode || manager || K || token || price || fee || tickSpacing))
```

`SwaputerKernel` must receive `H` in its constructor. `SwaputerHook` must receive the deployed `K`, and its constructor requires `K.hook() == address(this)`. Hook address permission bits also constrain `H`.

Consequently, “predict H, then predict K” is not an algorithm: changing K changes Hook init code and therefore H; changing H changes Kernel init code and therefore K. Merely reordering the same two CREATE2 calculations does not solve the fixed-point problem. The Stage 7A1-P tests demonstrate both divergent one-pass prediction and constructor failure from a naive two-pass deployment.

## 3. Per-world one-shot deployer

Stage 7A1-P proves the following cycle-breaking construction without changing Hook or Kernel constructors.

Let:

- `F` be the immutable production Factory address;
- `P` be a per-world one-shot deployer;
- `bootstrapSalt` select P;
- `probeInitCodeHash(F, kernelCreationCodeHash, hookCreationCodeHash)` be the fixed probe creation code plus its immutable Factory and fixed release-artifact commitments. These hashes are constant for a Factory release and do not contain Hook salt, K, H, or other per-World values.

Addresses are derived in this order:

```text
P = CREATE2(F, bootstrapSalt, probeInitCodeHash(F, fixedKernelCodeHash, fixedHookCodeHash))
K = CREATE(P, creatorNonce = 1)
H = CREATE2(P, hookSalt, keccak256(HookCreationCode || manager || K || token || price || fee || tickSpacing))
```

The circularity is gone because K is derived from P and nonce 1, not from Kernel init code. Once P and K are known, an offchain deployment tool mines `hookSalt` using P as the CREATE2 deployer until H has exactly:

```text
Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
```

The Factory is the CREATE2 deployer only for P. P is the ordinary CREATE deployer for K and the CREATE2 deployer for H. Calculations must use these exact addresses; Foundry's standard CREATE2 deployer is irrelevant and must not be assumed.

## 4. Implemented production algorithm in Stage 7A2

1. Deploy or otherwise determine all Hook constructor dependencies that affect its init code, including the GasToken.
2. Compute P from the actual Factory address, `bootstrapSalt`, and exact probe init-code hash.
3. Reject if P already has code.
4. Compute K as the first CREATE child of P, with creator nonce exactly 1.
5. Mine `hookSalt` offchain using P, exact Hook creation code and constructor arguments containing K.
6. Compute H and verify its v4 permission bits.
7. Factory deploys P with CREATE2 and verifies `address(P)` and `P.factory()`.
8. Factory calls P once. P sets its one-shot guard, deploys `SwaputerKernel(H, byteGasPrice)` with ordinary CREATE, and verifies the actual address equals K.
9. P deploys `SwaputerHook(manager, K, token, byteGasPrice, fee, tickSpacing)` with CREATE2 and `hookSalt`, then verifies the actual address equals H.
10. P and Factory verify `kernel.hook() == H`, `hook.kernel() == K`, `hook.poolManager() == manager`, both gas prices, pool parameters, v4 permission bits, and exact runtime code hashes for the fixed compiler/build and immutable arguments.

P exposes no arbitrary deployment, withdrawal, upgrade, or retry entry. It has immutable `factory` and creation-code-hash commitments, `onlyFactory`, and one-shot `used` state. Creation code supplied by the Factory is rejected unless its hash matches those commitments. Its first contract-creation operation must remain Kernel CREATE; adding an earlier CREATE would invalidate the nonce-1 derivation and must be caught by prediction tests.

The code bytes must not be embedded in P's runtime through Solidity `new SwaputerKernel` / `new SwaputerHook`: doing so made the first proof version exceed EIP-170. Stage 7A2 instead uses separately code-hash-bound immutable bytecode stores and preserves the same no-arbitrary-code property and artifact commitments. Factory constructor validation and Stage 7A2 tests recompute the exact pinned Kernel/Hook creation-code hashes.

## 5. Collision and rollback semantics

- occupied P: Factory rejects before CREATE2;
- reused `bootstrapSalt`: resolves to occupied P and fails;
- incorrect K prediction: P reverts after CREATE, rolling Kernel creation and `used` back;
- incorrect hook salt/prediction or occupied H: Hook CREATE2/constructor fails and rolls back Hook, Kernel, P when P was created in the same `createWorld` transaction, plus all Factory writes in that transaction;
- repeated call to a successfully consumed P: `ProbeAlreadyUsed`;
- non-Factory caller: `ProbeNotFactory` without consuming P;
- wrong Manager, Token, price, fee, tick spacing, init code, runtime code, or immutable getter: deployment fails before sealing.

An address collision cannot be recovered by silently selecting a different salt onchain. The offchain tool must construct a new candidate and the Factory must verify the complete commitment.

## 6. Sealing without modifying Hook or Kernel

Factory sealing is a deployment-authenticity and discovery layer, not VM consensus control.

Within one `createWorld` transaction the Factory shall:

1. deploy the World assets and the P/K/H graph;
2. construct the unique ETH/GasToken PoolKey;
3. call `PoolManager.initialize`;
4. verify addresses, code hashes, immutable getters, PoolKey and `worldId`;
5. write `WorldConfig` exactly once, emit its normalized `configHash`, and set `sealed = true`.

There is no mutation path after sealing. Before initialization PoolManager cannot execute a swap for that pool. The canonical Router accepts only a World recorded as sealed. Direct settlement integrations remain protected by the existing Hook world checks, Kernel signature/binding rules and PoolManager callback rules; Factory sealing cannot alter those frozen semantics.

## 7. Initial liquidity is separate

Pool initialization and World sealing do not imply liquidity. If the Factory does not custody a publisher's assets, initial liquidity is supplied in a separate, explicit bootstrap transaction. With no liquidity, swaps fail naturally.

Before declaring the World tradable, release tooling must verify:

- sealed WorldConfig and matching PoolKey/worldId;
- PoolManager, Token, Kernel, Hook, Router and Registry code/bindings;
- nonzero intended liquidity and price bounds;
- deployment configHash and reconstructed manifest inputs;
- a local/candidate-chain buy/sell smoke test under the release policy.

Factory receives no permanent custody, allowance, withdrawal, pause, ownership, proxy or upgrade capability.

## 8. Executable proof scope

`test/WorldDeployerProbe.sol` and `test/SwapVMStage7A1P.t.sol` prove the address derivation, permission bits, bidirectional bindings, `onlyFactory`, one-shot behavior, incorrect predictions, occupied targets, collisions and atomic rollback. They are test-only evidence and must not be deployed as production components. Stage 7A2 must implement a separately reviewed production equivalent and retain these tests as conformance tests.
