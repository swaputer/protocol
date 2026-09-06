# SwapVM v1.1 Actor Binding

Status: accepted security correction for implementation

## Problem

SwapVM v1.0 signs the action fields but does not carry an explicit expected actor. For a modified digest, the original `(r,s,v)` generally recovers a different nonzero EOA. On nonce zero, that recovered address can also have nonce zero, so the Kernel can accept the modified envelope as the first action of a different actor.

This violates the v1.0 requirement that changing any signed action field invalidates the action.

## v1.1 correction

1. Add `address actor` to `VMEnvelope`.
2. Add `address actor` to the EIP-712 `VMAction` immediately after `worldId`.
3. Set the EIP-712 domain version to `"1.1"`.
4. Require `actor != address(0)`.
5. Recover the ECDSA signer and require `recovered == actor` before reading the actor nonce.
6. Derive the VM AccountId only from the verified explicit actor.
7. Preserve recipient and permissionless-relay semantics; actor need not equal recipient or executor.
8. Keep VM ISA version 1 and VMReceipt version 1 unchanged.

The v1.1 type string is:

```text
VMAction(uint8 op,bytes32 worldId,address actor,bytes32 targetOrCodeHash,bytes32 payloadHash,uint32 byteGasLimit,uint128 minNetTokenOut,uint128 exactEthAmountIn,uint160 sqrtPriceLimitX96,address recipient,address router,address authorizedExecutor,uint64 nonce,uint64 deadline)
```

## Compatibility

v1.0 signed actions are invalid under v1.1 because both the domain version and type hash change. Unsigned NOP buys, VM bytecode, AccountId encoding, program package hashes, SRC packages, CPAMM package and aggregate receipt encoding remain unchanged.

No v1.0 public deployment exists, so no onchain migration is required.

## Required regression properties

- changing any signed field while retaining the signature reverts;
- replacing `actor` while retaining the signature reverts;
- a valid first-nonce action cannot be reclassified as another fresh actor;
- a v1.0 digest/signature is rejected by v1.1;
- permissionless relay with zero executor preserves the signed actor;
- recipient may differ from actor without changing authority;
- replay and nonce behavior remain unchanged.
