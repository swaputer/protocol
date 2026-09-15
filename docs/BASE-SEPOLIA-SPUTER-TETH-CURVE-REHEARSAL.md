# Base Sepolia sPuter/tETH Curve Rehearsal

Status: no-broadcast test evidence. This document does not authorize an Ethereum Mainnet or Base Mainnet deployment.

## Scope

This rehearsal validates the proposed fixed-supply `sPuter` issuance curve against the official Base Sepolia Uniswap v4 `PoolManager` on a fork. It uses a freely mintable ERC-20 `tETH` quote token so that large simulated buys do not consume native Base Sepolia test ETH.

The current production `SwaputerWorldFactory`, `SwaputerHook`, and `SwaputerAppRouter` remain native-ETH-specific and were not modified. The test models the 3% protocol fee before each buy, while the official PoolManager applies the 0.30% pool fee and performs the exact tick/liquidity accounting.

No transaction was broadcast. No private key was read or used.

## Candidate issuance

| Parameter | Value |
| --- | ---: |
| Token name | Swaputer |
| Token symbol | sPuter |
| Decimals | 18 |
| Fixed supply | 10,000 sPuter |
| Quote token | ERC-20 tETH |
| Initial price | 0.0004 tETH per sPuter |
| Protocol fee modeled | 3% |
| Uniswap pool fee | 0.30% |
| Tick spacing | 60 |
| Initial tETH liquidity | 0 |
| Initial sPuter allocation | 100% |

## Base Sepolia fork ranges

The fork deployment ordered `sPuter` as currency0 and `tETH` as currency1. All positions were initially sPuter-only.

| Position | Target sPuter | Human price range (tETH/sPuter) | Exact ticks |
| ---: | ---: | ---: | ---: |
| 1 | 50 | 0.0004 to 0.0006 | `[-78240, -74160]` |
| 2 | 150 | 0.0006 to 0.0009 | `[-74160, -70080]` |
| 3 | 800 | 0.0009 to 0.0012 | `[-70080, -67200]` |
| 4 | 1,500 | 0.0012 to 0.0024 | `[-67200, -60300]` |
| 5 | 2,500 | 0.0024 to 0.0096 | `[-60300, -46440]` |
| 6 | 5,000 | 0.0096 to the protocol maximum | `[-46440, 887220]` |

The position-minting math deposited `9,999.999999999999999977 sPuter`; unavoidable integer rounding left 23 token wei outside the positions.

The test derives the opposite tick orientation automatically when contract address ordering puts tETH in currency0. The local PoolManager run covered that opposite ordering and produced equivalent economics.

## Exact fork checkpoints

| Cumulative gross tETH paid | Cumulative sPuter output | Spot price (tETH/sPuter) | PoolManager tETH balance | Modeled protocol fees |
| ---: | ---: | ---: | ---: | ---: |
| 1.00 | 996.512325072176602418 | 0.001205315455175123 | approximately 0.97 | 0.03 |
| 16.04 | 4,995.384424811544947631 | 0.009585962108364117 | approximately 15.5588 | 0.4812 |
| 90.49 | 7,996.588300768681027099 | 0.059928976414414031 | 87.7753 | 2.7147 |

The final PoolManager tETH balance includes pool principal plus the 0.30% LP fee. The separate protocol-fee balance is not part of LP reserves.

## Sell reversal

After a 1 tETH gross buy:

- buyer output: `996.512325072176602418 sPuter`;
- peak spot price: `0.001205315455175123 tETH/sPuter`;
- selling the same sPuter amount back returned `0.965880315682321475 tETH` before a sell-side protocol fee;
- the spot price returned to `0.000409153607096826 tETH/sPuter`.

Applying the current Swaputer 3% sell-side protocol fee to that output would leave approximately `0.936903906211851831 tETH` for the seller. This confirms that the multi-range curve is reversible and that a large sell moves the price rapidly back toward the initial boundary.

## Commands

Local Uniswap v4 Core run:

```sh
forge test --match-contract SwaputerSPuterLocalCurveTest -vv
```

Base Sepolia official PoolManager fork run:

```sh
forge test --fork-url "$BASE_SEPOLIA_RPC_URL" --match-contract SwaputerSPuterBaseSepoliaForkTest -vv
```

The public Base Sepolia RPC can also be used for a read-only fork. A private RPC key is not required by the test and must not be committed.

## Remaining boundary

This rehearsal validates the ERC-20 tETH/sPuter Uniswap curve, fees, token ordering, tick alignment, one-sided deposits, buy checkpoints, and sell reversal. It does not prove the current native-ETH-only Swaputer Hook/Router execution path against an ERC-20 quote token. Supporting ERC-20 tETH in the full VM execution path would be a separate protocol change with new Router, Hook, Factory, code hashes, address mining, and audit scope.
