# Experimental SRC20 Escrow Market

Status: **deployed on Base Sepolia for zero-value testing; unaudited experimental only**.

`SwapVMSRC20Market` settles native ETH against one immutable SRC20 program in one sealed SwapVM World. Buy-order ETH is held by the EVM market. Sell-order SRC20 is held by a dedicated immutable MiniVM `MarketEscrow` account. Neither component has an owner, proxy, pause, upgrade, sweep, or arbitrary withdrawal path.

This design depends on the v1.2 `TXEXECUTOR` context extension. It is not compatible with the historical v1.1 Base Sepolia markets.

The earlier Base Sepolia market experiments and the superseded v1.2 1:1-price market are explicitly deprecated in `deployments/base-sepolia/src20-market-deprecation.json`. Their deployment records remain immutable historical evidence, but the frontend does not contain or select any of their addresses.

## Components and bindings

- The EVM market is permanently bound to one Router, World, Kernel, SRC20 AccountId and exact SRC20 code hash.
- The EVM market is also permanently bound to one `MarketEscrow` AccountId and exact escrow code hash.
- The MiniVM escrow constructor stores the SRC20 AccountId and the EVM market address.
- `MarketEscrow.deposit` and `MarketEscrow.release` both require `tx.executor == trustedMarket`.
- Every market-mediated `VMAction` requires `authorizedExecutor == address(market)` and is signed by the token owner or release recipient.
- The market validates the complete 68-byte selector/account/amount payload before calling the Router.

## Buy order flow

1. Buyer posts an order and transfers exactly `price + vmEthAmount` to the EVM market.
2. Any SRC20 holder signs `token.transfer(buyerAccountId, amount)` with the market as authorized executor.
3. The seller calls `fillBuyOrder`.
4. The market spends the locked VM input through the immutable Router. The MiniVM transfer and the EVM ETH payment occur in one EVM transaction.
5. On success, the buyer owns the SRC20 and the seller receives the quoted ETH. On any failure all order, nonce, VM, receipt, burn and payment changes revert.

## Sell order flow

1. Seller approves the exact MiniVM escrow AccountId through SRC20 `approve` if existing allowance is insufficient.
2. Seller signs `escrow.deposit(sellerAccountId, amount)` with the EVM market as authorized executor.
3. `createSellOrder` spends the seller-provided VM input and the escrow program executes SRC20 `transferFrom(seller, escrow, amount)`. The order is recorded only after custody succeeds.
4. Any buyer signs `escrow.release(buyerAccountId, amount)` with the market as authorized executor and calls `settleSellOrder` with exactly `price + vmEthAmount`.
5. The market marks the order filled, releases SRC20 to the buyer through the Router, and pays ETH to the seller atomically.
6. A seller cancellation also requires a fresh signed `release(sellerAccountId, amount)` action and VM input. A sell order cannot be cancelled or expired without returning custody.

The allowance transaction and sell-order creation are intentionally separate EVM transactions. A failed second transaction can leave an allowance to the dedicated escrow program, but cannot move tokens: the escrow rejects every executor except the immutable market. The UI checks allowance and skips approval when it is already sufficient.

## Accounting and failure properties

- `lockedEth` covers only open buy-order price and VM liabilities; forced ETH is excluded from refunds.
- `escrowedTokenAmount` and `activeSellAmount` track open sell-order custody.
- After every sell mutation the MiniVM escrow returns its accounted balance in the same execution; the EVM market requires it to equal total liability.
- There is no reservation state or reservation ABI. An open sell order is already fully collateralized and any buyer can atomically fill it.
- The exact 18-decimal quote is `amount * unitPriceWei / 1e18` with checked `uint128` bounds.
- Reentrancy is rejected around all state-changing settlement paths.
- Failed approval, deposit, release, transfer, byte-limit, Router settlement, or ETH payment reverts the complete transaction.

## Program artifact

The reproducible source and package are under `tooling/tinysol/programs/market-escrow/`.

- `MarketEscrow` package/code hash: `0x6da9921193ebfe79468ef74f5b94925b66bf8230e145234a77868f1e5a85614b`
- ABI hash: `0x13265fd7026d7b2787962e9aef5ca2a4449988e4f9008a1689bdf68325e9a3e5`
- Code length: 592 bytes

The package uses `this.id`, a TinySol spelling of the existing MiniVM `ADDRESS` opcode. This is a language binding, not an ISA extension.

## Test evidence

`test/SwapVMSRC20Market.t.sol` uses the real Uniswap v4 `PoolManager`, production Factory, Router, Hook, Kernel and real pool settlement. Its seven focused scenarios cover:

- ETH-funded buy creation, arbitrary-holder fill and atomic payment;
- SRC20 allowance, transferFrom custody, buyer settlement and seller cancellation;
- insufficient allowance rollback;
- payload redirection rejection;
- rejection of unsigned sell cancellation or permissionless expiry;
- forced ETH isolation and PoolManager transient-delta cleanup.

`script/LocalV12EscrowMarket.s.sol` reproducibly deploys a complete isolated v1.2 World, the escrow-capable `MintableSRC20` package, the exact `MarketEscrow` package and the final EVM market. Its liquidity helper is test-only; the public release uses Uniswap's official PositionManager. `script/LocalV12EscrowMarketExercise.s.sol` then executes five real transactions against that deployed instance:

1. create a fully funded buy order;
2. fill it with a signed SRC20 transfer;
3. approve the escrow AccountId;
4. create a sell order and move SRC20 into escrow;
5. settle it with a buyer-signed escrow release.

The August 30, 2026 final local replay used two independent Anvil accounts and ended with 2,000 SRC20 transferred from seller to buyer, zero escrow balance, zero market ETH balance, zero `lockedEth`, and zero `escrowedTokenAmount`. The five exercise transactions used 165,580; 1,685,845; 1,500,544; 3,784,134; and 3,409,576 gas respectively. Local addresses are ephemeral test evidence, not public release bindings.

## Frontend release configuration

`apps/mint-ui` has no fallback to the obsolete v1.1 markets. The current bindings are defaults and can be overridden as one complete set:

```text
VITE_SWAPVM_PROTOCOL_VERSION=1.2
VITE_SWAPVM_WORLD_ID=0x...
VITE_SWAPVM_KERNEL_ADDRESS=0x...
VITE_SWAPVM_ROUTER_ADDRESS=0x...
VITE_SWAPVM_SRC20_ID=0x...
VITE_SWAPVM_MARKET_ADDRESS=0x...
VITE_SWAPVM_MARKET_ESCROW_ID=0x...
VITE_SWAPVM_MARKET_ESCROW_CODE_HASH=0x...
```

The active Base Sepolia release uses market `0xE183C4d7Ad2F5D882B4c6025DBf4f47cD0669446`, MintableSRC20 AccountId `0x01ddc42fa71a13cc1ac4fad55e5adf116d9f6a299c18b467b3b90a8b722f946e`, and MarketEscrow AccountId `0x0182fbdf03d5b496c634e0eab2c603bea4297d738e5e1bb6083d98a4ccba2e3c`. The machine-readable source of truth is `deployments/active/base-sepolia.json`.

Its SVMG World was initialized at exactly `1 SVMG = 0.00001 ETH`. Official PositionManager position `#27258` supplied zero ETH and the maximum representable portion of the complete one-billion-SVMG fixed supply: `999,999,999.999999999999999958 SVMG`. The remaining `42` token wei are unavoidable liquidity-unit rounding dust. The range `[110040, 115080]` lies entirely below initial tick `115135`, proving the position was token1-only when minted.

The sell-order UI validates the v1.2 version, exact immutable EVM market bindings and escrow AccountId before any write. Full current evidence is in `deployments/base-sepolia/swaputer-events-latest.json`; earlier deployment files remain historical evidence only.
