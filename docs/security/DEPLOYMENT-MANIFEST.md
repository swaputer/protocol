# Deployment manifest — Stage 7A2 implemented model

## Two distinct commitments

1. `SwapVMWorldFactory.WorldConfig.configHash` is the onchain commitment. The
   Factory computes it with Solidity `abi.encode`, stores it once, and emits it
   in both `WorldConfigSet` and `WorldSealed`.
2. `integrity.manifestHash` is an offchain publication commitment over canonical
   JSON. It covers the larger release statement and explicitly excludes its own
   field and `integrity.signature` to avoid self-reference.

These hashes have different domains and must never be compared as if equal.
Factory does not generate JSON and does not sign on behalf of the publisher.

## Implemented schema and API

The normative tooling schema for this stage is
`tooling/deployment-manifest/schema/deployment-manifest-v1.schema.json`.
`tooling/deployment-manifest/src/types.ts` exposes the corresponding readonly
TypeScript type. Schema version (`"1"`) and protocol version (`"1.1"`) are
separate fields, and top-level `router` is required.

The manifest records:

- chainId;
- PoolManager, Factory, ReferenceRegistry, WorldDeployer, creation-code stores,
  GasToken, Kernel, Hook and Router address/EXTCODEHASH identities;
- store payload hashes for exact Kernel/Hook creation code;
- ETH/TOKEN PoolKey and `worldId = PoolId.unwrap(poolKey.toId())`;
- byte gas price and frozen code/stack/memory/call-depth/receipt limits;
- GasToken decimals, initial supply/holder and distribution commitment;
- reference program hashes and TinySol compiler identity;
- confirmed deployment block hash/number, tx hash and event index;
- source commit plus independent source-tree and artifact commitments;
- frozen spec/ISA hashes;
- optional offline publisher EIP-191/secp256k1 signature.

Canonical JSON recursively sorts keys, encodes UTF-8 without insignificant
whitespace and rejects non-safe JSON numbers. Large integers are canonical base
10 strings. Unknown fields and environment-specific additions are rejected.

## Exact onchain config hash

The Factory and TypeScript codec use:

```text
keccak256(abi.encode(
  WORLD_CONFIG_TYPEHASH,
  chainId, factory, poolManager, poolManagerCodeHash,
  router, referenceRegistry, worldId, worldDeployer,
  gasToken, kernel, hook,
  initialSupply, initialHolder, distributionCommitment,
  byteGasPrice, poolFee, tickSpacing, initialSqrtPriceX96,
  gasTokenCodeHash, kernelCodeHash, hookCodeHash
))
```

The cross-language golden vector is
`0x2e83890640ddf1743e749e9f0aa79c8ebb6705b8c9ba74dabeee961665bd4fa3`.

PoolManager identity is a separate Factory/manifest binding and is not folded
into `worldId` beyond the normal PoolKey definition, which has no Manager field.

## Before and after deployment

Deploy-time/offline planning may commit:

- schema/protocol versions, chainId and selected existing PoolManager code hash;
- exact compiler/source/artifact/store payload hashes;
- Factory creation transaction inputs;
- economic and VM ceilings, initial distribution commitment and salts;
- predicted Token, per-world deployer, Kernel and permission-bit Hook addresses.

Only after confirmation may the canonical manifest add:

- actual addresses and EXTCODEHASH values;
- `worldId`, stored `configHash` and sealed block;
- deployment tx hash, confirmed block number/hash and event index;
- independently reconstructed pool/config state;
- final `manifestHash` and optional publisher signature.

`deployment.blockHash` cannot be part of the Factory's earlier config commitment.
No timestamp, machine path, hostname, RPC URL, private key or wallet path is a
manifest field. A dirty working tree cannot be presented as a clean source
commit: the release must record both a real source-control commit and separately
reproducible tree/artifact commitments.

## Publication signature

The supported optional format is EIP-191 over the 32-byte manifest hash:

```text
keccak256("\x19Ethereum Signed Message:\n32" || manifestHash)
```

The signature object includes signer, algorithm `EIP-191`, message and a 65-byte
low-s secp256k1 signature. `attachEip191Signature` is a library API intended for
an offline publisher process. The CLI deliberately has no key flag. A valid
signature establishes publication provenance only; it does not make chain data
true and cannot replace reconstruction.

## Independent verification

An independent verifier must:

1. validate the strict schema and canonical integer/hex forms;
2. recompute PoolKey worldId, WorldConfig hash and manifest hash;
3. check PoolKey token/Hook and deployment Factory/Router cross-bindings;
4. compare every address and EXTCODEHASH with a separately acquired confirmed
   chain observation;
5. verify Factory Manager binding, sealed state and config events/transaction;
6. check frozen spec/ISA, compiler, reference and creation-code artifact hashes;
7. optionally recover the publisher signature;
8. reject the deployment on any mismatch.

`verifyObservation` accepts explicit observations and opens no RPC. RPC
acquisition belongs to an operational verifier outside this core codec, and
multiple independent endpoints/checkpoints should be used for a real release.
