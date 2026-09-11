# Experimental sETH Atomic Bridge

Status: **deployed and atomically exercised on Base Sepolia; unaudited experimental only**.

The zero-value testnet deployment is recorded in
`deployments/base-sepolia/seth-bridge-stage7d-u2.json`. The deployment flow
minted `0.00001 sETH` against `0.00001 ETH` and immediately redeemed the full
amount on-chain. The final state was solvent with zero supply, liability,
backing and surplus.

The bridge locks native ETH in an immutable EVM `SwapVMSETHVault` and represents
the exact liability as `sETH` inside one sealed SwapVM v1.2 World. One native ETH
wei corresponds to one sETH wei. Neither side has an owner, proxy, pause,
upgrade, sweep, arbitrary mint, arbitrary burn, or arbitrary withdrawal path.

## Immutable bindings

- The Vault is permanently bound to one Router, World, Kernel, sETH AccountId
  and exact sETH package code hash.
- Construction additionally queries `sETH.vault()` and requires it to equal the
  new Vault address, and requires initial sETH supply to be zero.
- `sETH.bridgeMint` and `sETH.bridgeBurn` require
  `tx.executor == trustedVault`.
- The Router requires the signed nonzero `authorizedExecutor` to equal its EVM
  caller, so a user or another contract cannot bypass the Vault.
- The Vault validates the complete selector, account and amount payload before
  spending VM input.

## Deposit

1. The payer signs `bridgeMint(recipientAccountId, amount)` with the Vault as
   authorized executor.
2. The payer calls `deposit` with exactly `amount + vmEthAmount` native ETH.
3. The Vault adds only `amount` to `lockedEth` and sends only `vmEthAmount` to
   the Router.
4. On successful MiniVM mint, unused Router budget is refunded to the payer.
5. The Vault requires `sETH totalSupply == lockedEth` and enough native backing
   before committing.

## Redeem

1. The sETH owner signs `bridgeBurn(amount)` with the Vault as authorized
   executor and an explicit EVM payout recipient.
2. The owner calls `redeem` with exactly the separate `vmEthAmount` budget.
3. The MiniVM burns from signed `tx.actor`; only after that succeeds does the
   Vault pay `amount` native ETH to the recipient.
4. A failed burn, Router settlement, refund or ETH payout reverts the nonce,
   sETH state, Vault liability and ETH movement together.

## Accounting

- `lockedEth` is the sole redeemable ETH liability.
- `sETH.totalSupply()` must equal `lockedEth` after every mutation.
- `address(vault).balance` must cover `lockedEth`.
- Forced ETH is reported as `backingSurplus`; it does not increase sETH supply
  or anyone's redemption entitlement and there is no sweep function.
- Principal and VM budget are distinct. The Router can spend only the supplied
  budget, and returns its unused portion to the signer through the Vault.

## Artifacts and tests

- TinySol source and seven reproducible artifacts:
  `tooling/tinysol/programs/seth/`.
- sETH package/code hash:
  `0x0ba319925e010cc61d6af3c0ef5dc9edb3bcfa1f6588e4ded86e744dbd3fc162`.
- EVM Vault: `src/SwapVMSETHVault.sol`.
- Real PoolManager/Router integration tests: `test/SwapVMSETHVault.t.sol`.

The focused tests cover atomic deposit and redemption, constructor binding,
direct-mint bypass rejection, payload redirection, insufficient owner balance,
failed ETH payout rollback, forced-ETH isolation, and the real TinySol internal
`move` helper used by ordinary sETH transfers.

## Frontend

The standalone `swaputer/ecosystem` frontend exposes Bridge as an application
inside its desktop/mobile shell. Its `config/base-sepolia.json` file pins the
complete current release. These optional build variables act only as integrity
assertions and must match that manifest:

```text
VITE_SWAPVM_SETH_VAULT_ADDRESS=0x...
VITE_SWAPVM_SETH_ID=0x...
VITE_SWAPVM_SETH_CODE_HASH=0x...
```

The application displays wallet sETH balance, locked ETH, total supply, forced
surplus, and solvency, and constructs the exact signed deposit/redeem
envelopes. It does not combine bindings from different releases.
