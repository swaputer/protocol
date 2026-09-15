# Stage 7D-U2 — Base Sepolia zero-value experimental release

Status: **deployed on Base Sepolia; unaudited experimental; zero real value**.

Stage 7C remains incomplete. There is no independent auditor or report, S7B-002
remains open Medium, mainnet is forbidden, and this release must not be called
audited, secure or production-ready. The immutable audit candidate remains
`swaputer-v1.1-stage7c-rc2` at
`afa54c2e02e7e91430b14b6884faff5e3f5867d9`; the tag was not moved.

## v1.2 final escrow-market deployment

On August 30, 2026, the later v1.2 executor-context implementation and final
fully collateralized SRC20 market were deployed as a separate zero-value Base
Sepolia experiment. This does not supersede the Stage 7C gate and does not make
either release audited or suitable for real-value funds.

- World: `0x2e6da13a641feb223c8e8deacbc689aed41de0ce32d408fd1f35b564f21dd33b`.
- Factory: `0x25be74e0FaB494D7cF0e7d681a3897f9d82908c1`.
- Router: `0x6719Fa2876EBce93c32490905C53e05ac1Da0109`.
- Kernel: `0x135Eb1547f2350f85C1853899341f4cDe8531d30`.
- Hook: `0x169c60b43f14968691128d0d1EeC120d82458044`.
- GasToken: `0xC86ACee2A9fCf996cFaD1F31d6CC23Ee6ca0b27c`.
- MintableSRC20 AccountId:
  `0x01784c2662ebe10347da4a91d31e098defc323fc7ee8b38747235bccac0085c2`.
- MarketEscrow AccountId:
  `0x010339efc76ef9510a814bedce3f2c56332812a41dd9383c619b25e041924360`.
- EVM escrow market: `0xa3a7AeE97552B0546EC00401C8b795eA0BdfcBa1`.
- Official PositionManager position: ERC-721 token `27216`, liquidity `3e18`.

The deployment used 18 successful transactions and `43,068,833` aggregate
receipt gas. Transaction fees, including L1 data fees, were
`0.000259449105865394` test ETH. Total deployer balance decrease, including
pool assets and VM inputs, was `0.123919665553754111` test ETH, leaving
`0.376080334446245889` of the explicit `0.5` test-ETH cap.

Seven successful VM executions consumed `2,368` bytes and burned exactly
`2,368,000,000,000,000` SVMG base units. Each execution emitted exactly one
Kernel `VMLog`. The two market self-test orders both settled, leaving zero
locked ETH, zero escrow liability, zero market ETH, zero token allowance and
zero Permit2 allowance.

The machine-readable evidence is
`deployments/base-sepolia/swapvm-v1.2-final-market.json`. It explicitly records
that this deployment was built from a dirty, uncommitted source tree; the cited
Git commit alone therefore cannot reproduce the v1.2 artifacts. That is a
release blocker for any real-value or production use.

### v1.2 single-sided SVMG migration

The 1:1-price v1.2 pool above was subsequently superseded by a new sealed World
at the requested initial price `1 SVMG = 0.00001 ETH`. Position `#27216` was
fully decreased to zero. The new official PositionManager position `#27217`
uses ticks `[110040, 115080]`, both below initial tick `115135`, so it supplied
no native ETH and only SVMG.

The GasToken fixed supply remains one billion SVMG. Integer liquidity units
accepted `999,999,999.999999999999999958 SVMG`; exactly 42 token wei remained
because increasing liquidity by one unit would exceed total supply. New World,
GasToken, Kernel, Hook and final-market bindings are:

- World `0x34e0ee268b9ff628d76cf0213fbfd448c34d357ecf90bed536959669b6b53c9f`.
- GasToken `0xe9168D00E2Cfb9AE60b4DeA18be77d84eE5dF04b`.
- Kernel `0xDEa4512A2D03bbeB19dF29429534dcdd299909D8`.
- Hook `0xc4e1ab4F4172c16DaC6B1cFB5d73D08237F04044`.
- Market `0x94CF8c8Ca7c0dBc8663fC66FfAD153B42d2cCc8e`.
- MintableSRC20 `0x01e429657b9e5afe4307a982c9c5dcbb6c569afeaa1830184ee4df8a0f0288ea`.
- MarketEscrow `0x01aea1f488e039878d18fccb8f31943137858e9f60dce49d3427630094d2fd52`.

Seventeen transactions used `32,130,365` gas and
`0.000192975104925646` test ETH in transaction fees. Removing the old
position recovered `0.145659032637411508` test ETH, so the operation increased
the publisher balance by `0.145457672955336633` test ETH. The complete NOP,
DEPLOY/CALL and escrow-market replay produced eight ordered Kernel VMLogs,
burned exactly `2,369` byte-fee units, settled both orders and left zero market
or allowance liability. Current evidence is
`deployments/base-sepolia/swapvm-v1.2-single-sided-market.json`.

## Network and release identity

- Chain: Base Sepolia `84532` (`0x14a34`).
- PoolManager: `0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408`.
- PoolManager EXTCODEHASH:
  `0x03c45db6d09b14da7c1f7239a5a49697f976d395277e6d2acb6fbed3f9e0249f`.
- Pool: native ETH / rc2 `SwaputerToken`; no ERC-20 test ETH was deployed.
- Token identity: `SwapVM Gas Token`, symbol `SVMG`, 18 decimals. No `tSVM`
  bytecode change was made.
- World ID:
  `0x9c414214b34b78217698b02c5b1a7af65f6d43c500ed2bd865ea4c54ed4360b9`.
- Onchain config hash:
  `0x6578119d8de5704dcf494d6e3794669805e7b98142b03f5ebdfcc1dca899970d`.
- Sealed block: `46102183`; block hash
  `0xc204686da4d4486ddc3cf5e0ebf09991a3fc4b3515848ce5c181a60c7bb70f4f`.
- Finality check: the independently queried Base `finalized` head reached
  `46102648`, above the sealed block, after more than the configured 600 L2
  confirmation blocks.
- Canonical unsigned manifest:
  `deployments/base-sepolia/swapvm-v1.1-stage7d-u2.json`.
- Manifest hash:
  `0xad24eef9e1e2a7fd5c653a8981161835aa6c87ffe9f73ec478cf73e426a49b5e`.
  Its detached publisher signature is deliberately `null`; verification relies
  on independent chain reconstruction, not a signature.

The release config is `config/base-sepolia-release.json`. RPC locations are
provided at runtime through environment variables; no credential, private key,
mnemonic or RPC secret is stored. The authorized key was held only in process
memory. It was not printed, copied, hashed, archived or committed.

## Deterministic addresses and salts

| Component | Address | live EXTCODEHASH |
| --- | --- | --- |
| Kernel creation-code store | `0x4AF2984F528fC0c4F33Cb0e2F566A6Be3362f44d` | `0x55dadc60aee012382d97c092c4a36e0f6f2a052af9f0a03ab61105111fd57ef1` |
| Hook creation-code store | `0x659b39dbAb1E0cd25c83bfe3B4338D41cF123B35` | `0x051a9d05c4b871e4567c39f8c0917b827978be2d7b4116f62b9122c604400ed4` |
| Factory | `0xF327e35FEA7EE7c92a765D1f00eD6A2A3db5b340` | `0x998edaa60813f9083c4fcfade4ae0bf54457967625bef2be6d7085e7f69c80e6` |
| ReferenceRegistry | `0xa4488C58Cd94E09f578262a08973175C36273F03` | `0x2946cb82853b48b67899d247ee1296a213c461af319c1d41db796326591235b6` |
| Router | `0xEDAbF849F3F74FE3C92FCEa50968332f77B06F07` | `0x846a7d6bd1690a23cc62f73ce3ff29b911be061d6170d4145b404d76989337ac` |
| GasToken | `0xe7bE2F5Af5281D81394c1ed22a27EDe5fdbb8775` | `0xcaeb77868e084ce07ed0788b053310a4e56fb38cd68b2a3bd14e9c4b22a22f5d` |
| WorldDeployer | `0x9529f25DA0294180B11fB461e67f21D523174b71` | `0x2518d99be6d236bc0eaa4989d43fa4bbe9828489883c16b5fb71863bba4af8e1` |
| Kernel | `0xA048C894A738185c24B4A5020Fb6708dAb160283` | `0x3301d3b0be9deaa42954ba7ebcddc7c34ed8184550cb2d778cc917a0baa60290` |
| Hook | `0x8166eb00f52399Abdf725d1bB42A8344928A0044` | `0x424d6273ac753f812a873df5c67dc59189d849e8823d6b879258a82f2cf74ab3` |
| Official Uniswap v4 PositionManager | `0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80` | `0xe8329b35b8b34290b6cf03affc0836f7b23205229cc96ffdc66544b93112c076` |

The Hook address ends in permission bits `0x0044`. Runtime checks proved
`kernel.hook == hook`, `hook.kernel == kernel`, both components bind the
official PoolManager, Hook binds the listed GasToken, and both byte-gas-price
getters equal `10^12`.

- Token salt:
  `0x3759c435ce279ce074811ee5a2644fe5b2ef4bb873ca21ad5ee903565433faef`.
- Bootstrap salt:
  `0xdf010f36bf156164481ba9fe4a254f6d5b826a38894ac0106bf86fd1ad573d5e`.
- Hook salt:
  `0x000000000000000000000000000000000000000000000000000000000000488c`.

Predicted Token, WorldDeployer, nonce-1 Kernel and permission-mined Hook
addresses exactly equal the deployed addresses.

## Deployment order, liquidity and gas budget

The deployment used 17 Base Sepolia transactions: two creation-code stores;
Factory (which creates Registry then Router); one atomic `createWorld` that
creates Token, one-shot WorldDeployer, Kernel and Hook, initializes the pool and
seals the World; three liquidity approve/add/revoke calls; five successful
buys; Router approve/sell/revoke; and two intentionally reverting buys.

Preflight reserved 40,000,000 aggregate gas and an 8,000,000 single-transaction
ceiling. Actual aggregate receipt gas was `29,641,361`; the maximum was
`6,989,903` for `createWorld`. Actual L2 gas fees were
`179,232,428,867,202` wei (`0.000179232428867202` test ETH).

The deployer began hard-cap accounting with
`12.413260640785848061` test ETH and ended with
`12.315520810938438418`. Cumulative net test-ETH outflow was
`0.097739829847409643`, leaving `0.402260170152590357` under the explicit
`0.5` test-ETH cap. The cap was checked before and after each manually sent
failure transaction.

Initial pool parameters were fee `3000`, tick spacing `60`, `sqrtPriceX96 =
2^96`, ticks `[-600, 600]`, liquidity delta `3e18`, and LP salt
`0x86493143d114be41cfdbaa5b553111d295f183d33ee4e479f24e49c51a66180e`.
Settlement consumed about `0.088659032637411510` native test ETH and the same
number of SVMG base units. Both temporary ERC-20 allowances were revoked to
zero.

The initial liquidity was supplied through Uniswap's official test-only
`PoolModifyLiquidityTest`. That made the shared router contract the position
owner, so a third party could target the same test position. The issue was
remediated on Base Sepolia before further soak testing: transaction
`0xbbc47ebae8d562d914e05446983e9bfde1445cc6fd73b54624034b4f8babea91`
removed all `3e18` legacy liquidity, and official PositionManager transaction
`0x9f28e6c577a9cf11e8e26b1939e02d19d1869b73300d02bc75490087a22b31dc`
minted ERC-721 position `#27200` to the publisher address. The replacement uses
the same pool, ticks and `3e18` liquidity. Its PoolManager position owner is the
official PositionManager and its salt is `bytes32(uint256(27200))`.
At the then-current pool price, that liquidity locked
`0.097531755591118256` native test ETH and `0.079812490846607803` SVMG; unused
portions of the `0.1`/`0.1` transaction maxima were returned.

The official PositionManager binds the same PoolManager and canonical Permit2
`0x000000000022D473030F116dDEE9F6B43aC78BA3`. Both approval layers were bounded
to `0.1 SVMG` during mint and then revoked; the final ERC-20 Permit2 allowance,
Permit2 amount allowance and SwapVM Router allowance are all zero. A live-state
fork reproduced the complete replacement and proved an unrelated address's
decrease request reverts with `NotApproved` without changing liquidity. The
test-only replacement/fork proof is
`script/Stage7DU2PositionManager.s.sol`; it does not modify a production
contract.

The replacement and post-migration NOP buy/sell used 10 transactions,
`1,053,319` gas and `6,356,700,876,652` wei of L2 gas fees. The publisher's net
balance change over the operation was `0.000879088386483790` test ETH, including
the `0.001` buy and roughly offsetting `0.0001` sell. After the later canonical
SRC-20 exercise, final cumulative release outflow is
`0.100653936620827827` test ETH, leaving `0.399346063379172173` under the `0.5`
test-ETH cap.

## Execution evidence

Eight exact-input native ETH/SVMG buys succeeded. Every transaction contained
exactly one log at the bound Kernel with topic
`VMLog(bytes32,uint64,bytes)`, even though it also contained PoolManager and
ERC-20 logs. Both sells contained zero Kernel VMLogs.

| Height / action | executedBytes | burn (SVMG base units) | gross output | net output |
| --- | ---: | ---: | ---: | ---: |
| 1 NOP | 1 | 1,000,000,000,000 | 996,668,773,744,192 | 995,668,773,744,192 |
| 2 SRC-20 DEPLOY | 142 | 142,000,000,000,000 | 1,991,352,169,375,517 | 1,849,352,169,375,517 |
| 3 SRC-20 CALL | 278 | 278,000,000,000,000 | 1,988,709,389,976,794 | 1,710,709,389,976,794 |
| 4 TinySol DEPLOY | 78 | 78,000,000,000,000 | 1,986,071,868,049,562 | 1,908,071,868,049,562 |
| 5 TinySol CALL | 373 | 373,000,000,000,000 | 1,983,439,589,657,638 | 1,610,439,589,657,638 |
| 6 post-PositionManager NOP | 1 | 1,000,000,000,000 | 990,800,363,166,697 | 989,800,363,166,697 |
| 7 SRC-20 constructor mint DEPLOY | 142 | 142,000,000,000,000 | 990,210,206,278,152 | 848,210,206,278,152 |
| 8 SRC-20 transfer CALL | 278 | 278,000,000,000,000 | 989,554,617,202,800 | 711,554,617,202,800 |

Total executed bytes and burn are `1,293` and `1,293,000,000,000,000` base
units (`0.001293 SVMG`). Total supply fell exactly from
`1,000,000,000,000,000,000,000,000,000` to
`999,999,999,998,707,000,000,000,000`. Final execution height is `8`; the six
signed actions advanced the actor action nonce to `6`, and three successful
deployments advanced its creator nonce to `3`.

Strict receipt decoding and the initial public-chain indexing observed this
record order:

1. NOP: `WorldExecution`.
2. SRC-20 DEPLOY: constructor `Transfer`, `MiniContractDeployed`, `WorldExecution`.
3. SRC-20 CALL: `Transfer`, `WorldExecution`.
4. TinySol DEPLOY: `MiniContractDeployed`, `WorldExecution`.
5. TinySol CALL: declared-unverified `Transfer`, `WorldExecution`.
6. Post-PositionManager NOP: `WorldExecution` only; strict codec decoding gave
   `executedBytes = 1`, burn `1,000,000,000,000`, gross
   `990,800,363,166,697` and net `989,800,363,166,697`.
7. New canonical SRC-20 DEPLOY: constructor `Transfer`,
   `MiniContractDeployed`, `WorldExecution`.
8. New canonical SRC-20 CALL: `Transfer`, `WorldExecution`.

Every receipt has exactly one final Kernel `WorldExecution`. The reference
SRC-20 binds only by its immutable reference codeHash; the TinySol
Transfer-shaped record remains declared/unverified and cannot acquire reference
trust from its event shape.

## Canonical SRC-20 constructor mint and transfer exercise

Canonical SRC-20 v1 deliberately has no post-deployment `mint()` method. Its
fixed supply is minted exactly once by the constructor. The Base Sepolia test
therefore performed the protocol-correct sequence: DEPLOY with initial supply,
read-only state queries, then a signed `transfer(bytes32,uint256)` CALL.

- Name/symbol/decimals: `Swaputer Test SRC20` / `S20T` / `18`.
- Canonical package codeHash:
  `0x8699a93b015eb99ed1e30d713f1183f710eb92d6bbdb92fd7086490e84fde792`.
- New MiniVM AccountId:
  `0x01be07afb98cd6606773a2bc792de8c8c165b58fb6cf89b23ee6a434589cf9e5`.
- Constructor mint: `1,000,000 S20T` to the publisher's tagged EOA AccountId.
- Transfer: `123,456 S20T` to tagged AccountId
  `0x000000000000000000000000000000000000000000000000000000000000beef`.
- Final publisher balance: `876,544 S20T`.
- Final recipient balance: `123,456 S20T`.
- Final SRC-20 total supply: unchanged at `1,000,000 S20T`.

Strict receipt decoding proved the constructor record amount is exactly
`1,000,000e18`, with topics `(zero AccountId, publisher AccountId)`. The
transfer record amount is exactly `123,456e18`, with topics
`(publisher AccountId, recipient AccountId)`. Both transactions contained five
ordinary Ethereum logs in total but exactly one matching Kernel `VMLog`.
Independent `Kernel.staticCall` queries returned the same total supply and
balances without changing nonce, height, burn or logs.

The DEPLOY used `4,130,733` gas and burned `142,000,000,000,000` SVMG base
units. The transfer used `1,350,969` gas and burned
`278,000,000,000,000` SVMG base units. Together they used `5,481,702` gas,
paid `34,941,383,958,606` wei of L2 gas fees, and changed the publisher's test
ETH balance by `0.002035018386934394` including the two `0.001` ETH exact-input
buys. The reproducible test-only script is `script/Stage7DU2SRC20.s.sol`.

The normal sell used `0.0001 SVMG`, emitted three non-VM Ethereum logs, did not
change height or supply, and left Router allowance zero. The explicit VM revert
transaction
`0x47ddbb1005ca7b6ede04ddf8bc944422bbf51d070ad588dfccd56ba1d595aa9e`
and OutOfByteGas transaction
`0x41120719be57708bcb028cbcdc16764425c4dbe2ff8523dc1e36b694335ebd30`
both have receipt status `0`, zero logs, and committed no height, actor nonce,
burn, storage, deployment or event change.

## Indexer, manifest and tooling verification

The reference indexer scanned the actual public-chain VMLogs over blocks
`46102459..46102467`. First scan committed 9 blocks and 5 executions; a repeat
scan committed 0. It stored 10 records and 2 deployments with no quarantined
log, malformed receipt, execution-height gap or ABI failure. Derived decoding
processed three application records: two decoded and one intentionally unknown.

Health was `healthy`, with 5 canonical/finalized executions and zero RPC lag for
the bounded evidence range. SQLite online backup and restore both produced
208,896-byte databases with SHA-256
`a46b559fee5d531098173e3df498c16c5c80eda9afde46673f3220d338345342`;
the restored database retained all five executions.

The standard official Base RPC pruned block zero at the time of the scan, while
the indexer deliberately binds chain identity to the genesis hash. The scan
therefore used the configured no-secret secondary public RPC. This is an
operational availability risk, not a receipt or consensus mismatch.

`tooling/stage7d/stage7d-u2-finalize.mjs` reconstructs the unsigned manifest
from the confirmed `WorldSealed` receipt, live runtime bytecode, immutable
getters, rc2 artifact inventory, frozen spec/ISA, reference packages and TinySol
compiler identity. It then runs strict manifest and observation verification
before writing the canonical JSON artifact.

The complete `./script/accept-stage7d-u1.sh` prerequisite gate passed again
after the U2 files were added. It reported 196 Foundry tests passed, zero
failed; four npm audits reported zero vulnerabilities; frozen v1.1 spec/ISA
and historical v1.0 manifest checks passed; `forge fmt --check`,
`forge build --sizes`, `forge snapshot --check`, Slither triage, audit snapshot
identity and `git diff --check` passed. Key runtime sizes remain: Kernel 21,918
bytes, Hook 5,842, Router 6,686, Factory 12,362, WorldDeployer 2,548,
ReferenceRegistry 1,606 and GasToken 1,350.

## Transaction evidence

| Action | Transaction | status | gas used |
| --- | --- | ---: | ---: |
| Kernel store | `0xe03796d93865038a0aafa6d8bedf462f4088eeec92d2f0e5919a1b7a4c839137` | 1 | 4,878,731 |
| Hook store | `0xbea796f1c0c2d7508593acf471c5d190b6be5416833be6a38df3f762fe110b09` | 1 | 1,582,592 |
| Factory | `0x19a66f887f2b358243367baf350c0b2d4e856aa94873cafafb02c8f20124f0d3` | 1 | 4,611,428 |
| createWorld | `0x853060bcf2051a4ea6d7022dfdff3e3733c31663b4c8bfa37ddca0569ec08dd9` | 1 | 6,989,903 |
| Approve LP router | `0x6072376d4b687ca31fc158e7ba22c7a11cbf634a08a52a124afeda8efd2df0f6` | 1 | 46,249 |
| Add liquidity | `0x22504d2f5f0cc72c02d3bb066de277a2e225c823d4d9e1e076b44529a6e5ce39` | 1 | 266,838 |
| Revoke LP allowance | `0x103f51a745bac15e5b320665f56fd446183b829d4aeac64093fc1447fcffbdd2` | 1 | 23,965 |
| NOP buy | `0x51a33b363ed4b59c6bee7b68bd15a7f78517bd6d94e8a673fed46673680c92c9` | 1 | 213,935 |
| SRC-20 DEPLOY | `0x8afc338dfe47b664bff3fb7061c4d99169d95f47bec0a1d9b7cb9075ede090f3` | 1 | 4,852,128 |
| SRC-20 CALL | `0xb714b12e5a2382f050c61c33c47aa9e60234fa8ec9094504f256129e3ce04524` | 1 | 1,350,801 |
| TinySol DEPLOY | `0x58b97bee242399e986b5aa70efd055c5d2043a5e1672503f5e2698f6ce3efb4c` | 1 | 2,616,243 |
| TinySol CALL | `0x2e1484fbc39b180987606dcacec187f8eb838f123d0fb1de2da135f595180979` | 1 | 949,512 |
| Approve Router | `0x603504beb5d0d13b22b7351e9bd38a2128270c64f01c4372e310ca0044ac3078` | 1 | 45,925 |
| Sell | `0xba70e0da2dfcdd4f6b68ee63b50e2fe691764e9fa6b1f8eb912f5f4538c57d30` | 1 | 139,468 |
| Revoke Router allowance | `0x48f126d7f91d3c5420202b04bd391ae87ce8eed891f9c0d7154caf08dfdda830` | 1 | 25,965 |
| Expected VM revert | `0x47ddbb1005ca7b6ede04ddf8bc944422bbf51d070ad588dfccd56ba1d595aa9e` | 0 | 610,654 |
| Expected OutOfByteGas | `0x41120719be57708bcb028cbcdc16764425c4dbe2ff8523dc1e36b694335ebd30` | 0 | 437,024 |

### Official PositionManager remediation transactions

| Action | Transaction | status | gas used | gas fee (wei) |
| --- | --- | ---: | ---: | ---: |
| Remove legacy shared position | `0xbbc47ebae8d562d914e05446983e9bfde1445cc6fd73b54624034b4f8babea91` | 1 | 145,365 | 902,946,617,430 |
| Approve SVMG to Permit2 | `0x29cc2b8e1deb59b5fe01aef9c9446383f40aed25f163a7f11290173e601978f7` | 1 | 45,877 | 280,455,184,646 |
| Permit2 approve PositionManager | `0x5f8d3107ba080b878c32d009c2c08f0911a93aba1f7b3e4ec9e6a7013ddc6810` | 1 | 47,626 | 286,593,074,576 |
| Mint PositionManager NFT #27200 | `0x9f28e6c577a9cf11e8e26b1939e02d19d1869b73300d02bc75490087a22b31dc` | 1 | 408,662 | 2,451,972,000,000 |
| Revoke Permit2 amount | `0xa758a697e4d4876cbaafcd822a80d322a31880b92f85779a3424939b2f18d11c` | 1 | 30,396 | 182,376,000,000 |
| Revoke ERC-20 Permit2 allowance | `0x239aa264ed16f612cebde4ed795b3544b0f158e57bf63d726c80363622c81182` | 1 | 23,905 | 143,430,000,000 |
| Post-migration NOP buy | `0x0c1034c7acf7dda8dd4fa36df0a902240615d095e83ca1fa33e188e4a2019429` | 1 | 157,441 | 944,646,000,000 |
| Approve Router for sell | `0x8619172b3f7ca32db349e1235db56a475b1e1dfdb75bfa7f6a0bd1da327950d1` | 1 | 45,925 | 275,550,000,000 |
| Post-migration sell | `0x7fb3a32b15d9ea204b3738d128364d829a09f73128b131db42dfeca141a777f2` | 1 | 122,157 | 732,942,000,000 |
| Revoke Router allowance | `0x14d6de1096fcb6c048379b9fb5ced544c5bd6205ec0d2da49acda53abb3b2d35` | 1 | 25,965 | 155,790,000,000 |

### Canonical SRC-20 exercise transactions

| Action | Transaction | status | gas used | gas fee (wei) |
| --- | --- | ---: | ---: | ---: |
| DEPLOY + constructor mint | `0xe21be8cd976dff6a63c33ed604ff8673af4cec4e4bd8bbb4e1b1c68e9096d0dc` | 1 | 4,130,733 | 26,375,155,670,499 |
| Transfer | `0x85ad0af940250222bda711732b26478f631fe5301c585419c613cc143a9e3fce` | 1 | 1,350,969 | 8,566,228,288,107 |

### Experimental mintable SRC-20 exercise

The custom TinySol `MintableSRC20` package hash
`0x1a049200e47e150864788daeba7b106628283d0d6219ddf7be80f89ebb691b2e`
was deployed through the real `buyVMExactInput` and Uniswap v4 settlement path.
Its MiniVM ContractId is
`0x012928db8f5a86bc849ed1a66d4ff19bb5af3a9a49688aa9d6d060f41f82d8d8`.

| Action | Transaction | block | status | gas used | executed bytes | SVMG burned |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| DEPLOY | `0x06f56504fed0bdb9316f040dd2ed12903ae3e718fb03431352519afdbf26afca` | 46,105,455 | 1 | 3,990,743 | 13 | 13,000,000,000,000 |
| Mint 1,000 | `0x5a2df75f6a4002e354ad509f2bf4d13648ebe935e3ff8164d97bbb2421e2e789` | 46,105,457 | 1 | 1,097,793 | 278 | 278,000,000,000,000 |
| Transfer 250 | `0xdb54ce4d11211bb063e94cc818daf8880afdb412fd01a896ebf8b9bdecd26398` | 46,105,458 | 1 | 1,201,961 | 396 | 396,000,000,000,000 |

Each transaction contained exactly one Kernel `VMLog`. Stage 6A strict receipt
decoding produced execution heights 9, 10, and 11. The mint virtual Transfer
record used the zero AccountId as `from`; the transfer record moved 250 tokens
from the actor AccountId to the AccountId for `0xBEEF`. Read-only Kernel
`staticCall` queries at block 46,105,518 returned total supply 1,000 tokens,
actor balance 750, recipient balance 250, mint amount 1,000, cap 10,000,000,
and decimals 18. The machine-readable evidence is
`deployments/base-sepolia/mintable-src20-stage7d-u2.json`.

The three transactions consumed 6,290,497 EVM gas and 0.003 ETH of swap input.
The actor balance decreased by 0.003054579403029121 ETH for the complete round;
cumulative Stage 7D-U2 spending from the release-start balance is
0.103708516023856948 ETH, below the 0.5 ETH cap. This application remains
custom, `declared_unverified`, experimental and unaudited; it is not a canonical
SRC-20 reference program.

## Remaining blockers

- Stage 7C independent audit and remediation/acceptance are absent.
- S7B-002 remains open Medium.
- The bounty is a draft with no funded reward pool or live program.
- The official PositionManager replacement removes the shared-router ownership
  flaw, but the project-owned test liquidity and its operational custody remain
  unsuitable for real-value claims without independent audit and an approved
  liquidity policy.
- The manifest is unsigned and describes an unaudited testnet artifact only.
- Economic/MEV parameters have not been approved for value-bearing use.
- Public RPC archival/failover and continuous monitoring need staffed operations.
- No mainnet release artifact exists; policy and scripts must continue to fail closed.

The only permitted next activity is a monitored, zero-real-value Base Sepolia
soak and incident/deprecation rehearsal. Real funds and mainnet remain blocked.
