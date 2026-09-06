# Stage 7D-U2 — Base Sepolia pre-broadcast preparation (historical checkpoint)

Status: **completed before broadcast; superseded by `docs/STAGE7D-U2.md`**.

The statements below describing an unsigned/unbroadcast release record the
mandatory checkpoint that was completed before the project later authorized
Base Sepolia broadcasting with a 0.5 test-ETH hard cap. They are retained as
release evidence, not as a description of current chain state.

This phase targets only Base Sepolia chain `84532`. It does not authorize Base
mainnet, any real-value asset, third-party custody or a claim that Swaputer is
audited, secure or production-ready. Stage 7C remains incomplete and S7B-002
remains open Medium.

## Official network identity

- Base network: Base Sepolia, chain ID `84532` (`0x14a34`).
- Standard read-only RPC is supplied at runtime only through
  `SWAPVM_BASE_SEPOLIA_RPC_PRIMARY`; no RPC URL or credential is committed.
- Secondary RPC is supplied only through `SWAPVM_BASE_SEPOLIA_RPC_SECONDARY`.
- Official Base explorer: `https://sepolia-explorer.base.org`.
- Uniswap's current official v4 deployment list identifies PoolManager
  `0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408` on Base Sepolia.
- A live `eth_getCode` observation measured 24,009 runtime bytes and
  EXTCODEHASH `0x03c45db6d09b14da7c1f7239a5a49697f976d395277e6d2acb6fbed3f9e0249f`.
- The same official list identifies testnet `PoolModifyLiquidityTest`
  `0x37429cd17cb1454c34e7f50b09725202fd533039`; live EXTCODEHASH is
  `0x5d39a7244938a909f70906d72c9814c8024046513f5699cd6fb30d10d7e0a5db`.

The external PoolManager bytecode is not the locally pinned v4-core test
PoolManager bytecode. The Factory therefore binds the observed external code
hash explicitly. Before authorization, a fork/simulation compatibility test
must prove pool initialization, native settlement, afterSwap return-delta and
transient-delta clearing against this exact deployed bytecode.

## Fixed World shape

The pool key is exactly native ETH (`currency0 = address(0)`) and the rc2
`SwapVMGasToken` (`currency1`). No ERC-20 test ETH is deployed. Gas token name,
symbol and decimals remain `SwapVM Gas Token`, `SVMG`, and `18`; changing the
symbol would change rc2 bytecode and is forbidden.

Draft economics are deliberately valueless: 1,000,000,000 SVMG fixed supply,
`byteGasPrice = 10^12`, `maxByteGasLimit = 1,000,000` and therefore a maximum
VM exposure of `10^18` base units (1 SVMG). The draft pool uses fee 3,000,
tick spacing 60 and `sqrtPriceX96 = 2^96`. Project-owned bootstrap limits are
1,000 SVMG and 0.1 Base Sepolia ETH, with no third-party funds.

The exact fork rehearsal used liquidity `3e18` over ticks `[-600, 600]` at
`2^96`. Settlement consumed `88,659,032,637,411,510` wei native and the same
number of SVMG base units. The remaining native value was refunded by the
official testnet liquidity router.

Release evidence waits 600 sealed L2 blocks (approximately 20 minutes at the
documented two-second block interval) and independently requires the observed
release block to be at or below the RPC `finalized` head before publication.
The indexer retains a 1,024-block maximum reorg investigation window; this is
an operational halt threshold, not a claim that Base normally reorgs that far.

## Planned transactions and gas

The current rc2 release flow is 15 transactions:

1. deploy Kernel creation-code store;
2. deploy Hook creation-code store;
3. deploy Factory (its constructor internally deploys immutable Registry, then Router);
4. call `createWorld` (Token, WorldDeployer, Kernel and Hook deployment, pool initialization and sealing);
5. approve the official Base Sepolia liquidity test router;
6. add project-owned test liquidity;
7. NOP buy;
8. SRC-20 DEPLOY buy;
9. SRC-20 CALL buy;
10. TinySol DEPLOY buy;
11. TinySol CALL buy;
12. sell;
13. intentional VM revert buy;
14. intentional OutOfByteGas buy;
15. withdraw the project-owned LP position after the test window.

The exact external-PoolManager fork measured deployment/sealing execution gas
of `4,513,875 + 1,455,752 + 4,258,663 + 6,959,044 = 17,187,334`. Combining
those values with the latest isolated rehearsal for the remaining calls gives
an indicative 15-transaction total of `28,718,179` gas and a maximum single
transaction of `6,959,044` gas. The release plan reserves 40,000,000 aggregate
gas and 8,000,000 for `createWorld`; these are ceilings, not transaction gas
estimates. At the observed read-only gas price of 6,000,000 wei/gas, the
indicative L2 execution component is `0.000172309074` test ETH. L1 data fees
are additional, so the pre-authorization operating budget reserves 0.01 test
ETH for all gas, plus at most 0.1 test ETH for liquidity. The deployer balance
must therefore be at least 0.11 test ETH at the final preflight block.

## Required test matrix

- official chain ID and PoolManager/liquidity-router code hashes;
- exact rc2 artifact and creation-code-store commitments;
- CREATE/CREATE2 predictions, salt collisions and exact Hook permission bits;
- sealed native ETH/SVMG pool identity;
- NOP, SRC-20 and TinySol DEPLOY/CALL buys with one Kernel VMLog each;
- simulator executed-byte/burn/net-output reconciliation;
- sell with zero VM execution and zero burn;
- revert and OutOfByteGas atomic rollback;
- PoolManager settlement completion;
- manifest reconstruction and `unaudited` release flag;
- indexer scan, restart/idempotence, health and raw-receipt preservation;
- project LP withdrawal and incident/deprecation runbook dry run.

## Address-dependent stop condition

The rc2 deploy script uses three consecutive EOA CREATE transactions for the
Kernel creation-code store, Hook creation-code store and Factory. Exact store,
Factory, Registry, Router, Token, WorldDeployer, Kernel and Hook addresses thus
require the deployer's public address and current Base Sepolia nonce. No wallet
file or secret may be used to infer those public inputs.

The pre-broadcast draft was finalized as `config/base-sepolia-release.json`
after the deployer public address and nonce were authorized. It contains exact
predictions, `containsPlaceholders = false`, and remains fail-closed to
`environment = testnet`, `auditStatus = unaudited`, and chain ID `84532`.

There is a second sequencing constraint: the current U1 live preflight requires
the two creation-code stores to exist and match their runtime hashes. It cannot
produce a passing pre-broadcast live report while those future addresses are
empty. This must be resolved with a separately reviewed predeployment
observation mode, or the release must be split into an explicitly authorized
store-bootstrap checkpoint followed by live preflight. It must not be bypassed
by substituting the empty-code hash.

The public deployer address/nonce, exact predictions, PoolManager compatibility
simulation, offline preflight, live read-only preflight, balance and gas ceiling
all passed before the first broadcast. The resulting transactions and
post-deployment verification are recorded in `docs/STAGE7D-U2.md`.
