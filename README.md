# Swaputer Protocol

Private canonical repository for Swaputer's on-chain protocol: Solidity
contracts, Foundry tests, protocol specifications, reference artifacts, security
evidence, deployment manifests, and release scripts.

There is no mainnet release configuration in this repository. The active public
test deployment remains Base Sepolia, and its canonical manifest is
`deployments/active/base-sepolia.json`.

Developer tooling is pinned as the private `swaputer/tooling` submodule exposed
at `tooling/`. Clone recursively before running the complete test suite:

```sh
git clone --recurse-submodules https://github.com/swaputer/protocol.git
cd protocol
forge test
```

Historical candidate and audit evidence under `release/` and `audit/` was
created in the former monorepo and is retained as historical evidence; it must
not be presented as a newly signed five-repository release gate.

This repository was split from private monorepo commit
`c9c8bb269e9dfd112d2dad78726a9db516940462` on September 6, 2026. The source
monorepo remains the historical evidence archive. Licensed under the MIT License.
