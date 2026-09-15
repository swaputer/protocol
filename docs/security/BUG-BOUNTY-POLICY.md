# Bug Bounty Policy — draft, not live

This document is an operational draft. No funded bounty pool, payment commitment or live program
exists. Rewards remain explicit placeholders: `CRITICAL_REWARD_TBD`, `HIGH_REWARD_TBD`,
`MEDIUM_REWARD_TBD`, and `LOW_REWARD_TBD`.

The Stage 7M decision does not plan to activate this policy or fund a bounty. It is retained only
as an inactive contingency template and is not a mainnet release prerequisite.

## Baseline and scope

Reports must identify whether they apply to immutable baseline
`swaputer-v1.1-stage7c-rc2` / `afa54c2e02e7e91430b14b6884faff5e3f5867d9` or a later explicitly
named experimental build. In scope:

- `SwaputerHook`, `SwaputerKernel`, integrated `SwapVMMiniVM`, `SwaputerToken`;
- `SwaputerAppRouter`, `SwaputerWorldFactory`, `SwaputerWorldDeployer`, creation-code stores and registry;
- immutable SRC-20/SRC-721/SRC-1155/CPAMM reference packages;
- receipt codec, indexer/reorg logic, ABI/codeHash binding, TinySol compiler/assembler/simulator,
  fee estimator and deployment-manifest/preflight tooling.

Operational documentation mistakes are in scope when they can cause unsafe deployment or conceal
the unaudited status. Social engineering, denial of third-party infrastructure, UI cosmetics and
issues requiring stolen credentials are out of scope unless separately authorized.

## Testing rules

- Use local Anvil or a specifically designated zero-value testnet World only.
- Do not test public mainnet, real users, third-party LPs, third-party tokens or custodial systems.
- Do not retain data, degrade shared services, publish an exploit, or move assets beyond the
  minimum harmless proof.
- A testnet TOKEN has no promised economic value.

## Report and PoC requirements

Include affected commit/tag, component, assumptions, exact steps, minimal deterministic PoC,
expected versus observed behavior, impact, suggested severity and remediation idea. A valid PoC
must avoid private keys and public-RPC secrets and must be reproducible from clean locked
dependencies. Reports without an exploit path may be treated as hardening suggestions.

## Duplicates and coordinated disclosure

Substantially identical root causes are one finding; the earliest complete reproducible private
report is primary. Later reports may receive credit but no promised reward. Maintain embargo until
the project confirms a fix/replacement World and agrees on disclosure timing. Default coordination
targets are acknowledgement within `ACK_SLA_TBD` and status updates within `UPDATE_SLA_TBD`.

## Safe-harbor draft

Good-faith research that follows this policy, uses only authorized zero-value environments, avoids
privacy harm and promptly reports findings is intended to receive project safe-harbor support.
This draft is not legal advice and cannot bind third parties or network operators.
