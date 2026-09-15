# SwapVM v1.0 — Stage 5 implementation report

## Implemented scope

Stage 5 adds one deterministic constant-product AMM `ProgramPackageV1`. It is an ordinary mini-program: the Kernel has no AMM branch, reserve ledger, token shortcut or trusted selector path. The program exposes the frozen Stage-5 surface:

```text
createPair(token0, token1, fee)
addLiquidity(amount0, amount1, minShares)
removeLiquidity(shares, min0, min1)
swapExactIn(tokenIn, amountIn, minOut)
getReserves()
```

It additionally exposes `totalShares()`, `sharesOf(bytes32)` and SRC-165 discovery so tests, wallets and indexers can inspect LP accounting. Pair creation is one-time. Token identifiers must be nonzero and distinct, and the immutable fee is below the denominator of 1,000,000.

Every asset movement is an ordinary nested call to a deployed canonical SRC-20 program. Deposits use `transferFrom(actor, ammContractId, amount)` after explicit approval; withdrawals and swap outputs use `transfer(actor, amount)` with the AMM contract AccountId as the nested caller. Consequently token dispatch, allowance checks, balance mutations and virtual `Transfer` records all consume the same shared byte budget as AMM math.

The exact reference identity is:

| Standard | Interface ID | ABI hash | ProgramPackageV1 code hash |
| --- | --- | --- | --- |
| CPAMM | `0x94baf55f` | `0x867173fe3dcbf09ae1202bb62b8ec3913ef83cef075906344821673ec239807b` | `0x2d5b233b9056011f5a1fbed8781b5c12963ba6bcbcf9a79cfcc0d1ebaf8a3e4b` |

`SwaputerProgramRegistry` recognizes it only when interface ID, exact canonical ABI hash and whole-package hash all match.

## Math, bounds and atomicity

The first liquidity deposit mints `min(amount0, amount1)` shares. Later deposits mint the smaller of `amount0 * totalShares / reserve0` and `amount1 * totalShares / reserve1`; any excess is a donation to existing LPs. Removal returns `shares * reserve / totalShares` for each asset. Exact-input output is:

```text
adjustedIn = floor(amountIn * (1_000_000 - fee) / 1_000_000)
amountOut  = floor(reserveOut * adjustedIn / (reserveIn + adjustedIn))
```

Amounts, reserves and total shares are capped at `uint128.max`. Products of two bounded values therefore fit `uint256`; reserve additions are rechecked before storage. Zero amounts/shares/output, a failed minimum, an unknown input token, insufficient balance/allowance, overflow, nested-call failure or receipt/burn/settlement failure reverts the complete outer buy. The AMM state, both SRC-20 states, nonce, execution height, aggregate log and real Gas Token supply roll back together.

AMM virtual records follow nested execution order. For add, remove and swap, the two SRC-20 `Transfer` records precede the AMM's application record, and the Kernel `WorldExecution` summary remains last inside the one Ethereum `VMLog`.

## Verification results

Stage-5 focused verification covers:

- exact package registry recognition and mutation rejection;
- real-v4, signed buy-side deployment of two SRC-20 programs and the AMM;
- one-time pair creation, explicit approvals, liquidity addition, exact-input swap and proportional removal;
- exact reserve backing by the AMM's mini-token balances and exact LP-share accounting;
- constant-product non-decrease after fees and integer rounding;
- ordered nested token/AMM receipt emitters and topics;
- slippage and invalid-token rollback of reserves, balances, nonce, height, real supply and `VMLog`;
- static query success and static mutation rejection;
- a 512-case exact-input fuzz property;
- two stateful invariants, each running 64 runs × 32 calls = 2,048 successful bidirectional swaps with zero handler reverts. The model continuously reconciles reserves, AMM backing, actor balances, total mini-token conservation, constant-product floor, nonce, height, actual executed-byte burn, empty Hook balance and every PoolManager transient delta.

Final local verification used Foundry `1.5.1-stable`, Solidity `0.8.26`, Cancun semantics, IR compilation and optimizer runs `200`:

- `forge fmt --check`, `forge build --sizes`, `forge test -vvv` and `forge snapshot` succeeded;
- 72 tests passed, none failed;
- ten fuzz properties ran at least 512 cases each;
- eight stateful invariants each ran 64 runs × 32 calls = 2,048 actions, with zero handler reverts;
- representative Stage-5 test-function costs are 377,689 gas for exact registry verification, 52,300,167 gas for the nine-transaction deploy/create/approve/add/swap/remove conformance scenario, 37,451,561 gas for the setup plus two rollback cases, and 22,452,902 gas for setup plus static behavior. These include fixtures and multiple real-v4 swaps, so they are not single production Router-call estimates;
- production runtime sizes are 21,918 bytes for `SwaputerKernel`, 5,842 bytes for `SwaputerHook`, 1,350 bytes for `SwaputerToken`, and 1,606 bytes for the four-package `SwaputerProgramRegistry`. Kernel remains 2,658 bytes below EIP-170.

## Authentication status and remaining scope

The v1.0 EIP-712 actor-binding conflict is resolved in frozen v1.1. Stage-5 AMM actions sign an explicit actor and the Kernel verifies recovered equality before nonce lookup. ISA, receipt and CPAMM package hashes remain unchanged.

The package and interpreter are unaudited. Stage 6's reference indexer, malformed-payload/reorg suite, TinySol compiler, disassembler, simulator and independent byte estimator are not implemented. No public-network deployment was performed.
