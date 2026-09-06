# Stage 7 — release hardening and production preparation

Stage 6 remains the frozen v1.1 local Release Candidate. Stage 7 adds the
release surface around it without changing Hook, Kernel, MiniVM, ISA, receipt,
VMAction, reference-package, or sell-bypass semantics.

Post Stage 7D-U2, the unaudited v1.2 line added read-only MiniVM transaction
context for Router, authorized executor and recipient, an executor-bound MiniVM
SRC20 escrow, an immutable EVM market, protocol fees and direct official
Universal Router execution. These changes do not make Stage 7C complete.

On 2026-09-06 the project decided not to commission an independent external
audit for the current release line. The new target is Stage 7M: an explicitly
unaudited, capped, experimental mainnet release. This removes the external-audit
gate only; it does not authorize mainnet or waive the remaining security,
economic, custody, soak or release-evidence requirements. The Stage 7M policy
separately records the project's accepted operational omissions.

## Stage 7A status

- **7A1 / 7A1-R — complete:** release gap review, threat model, audit scope,
  immutable manifest model, one-Manager-per-Factory choice, and Router ABI.
- **7A1-P — complete:** executable proof that direct Kernel/Hook CREATE2 is a
  real address cycle and that a per-world nonce-1 CREATE deployer breaks it.
- **7A2 — implementation complete, unaudited:** production-shaped immutable
  `SwapVMWorldFactory`, `SwapVMWorldDeployer`, `SwapVMRouter`, creation-code
  stores, onchain one-write WorldConfig/sealing, local deployment script, and
  strict RPC-free deployment-manifest tooling are implemented and tested.

Stage 7A2 does not make the system audited or publicly deployable. The new
contracts join the release-candidate audit surface.

## Stage 7A2 invariants

1. Factory binds one existing PoolManager address and exact EXTCODEHASH; it
   never deploys or replaces the Manager.
2. Kernel and Hook creation code is release-pinned by exact payload hash.
3. Factory CREATE2-deploys a one-shot WorldDeployer; its first CREATE child is
   Kernel and its CREATE2 child is the permission-bit-mined Hook.
4. Token, deployer, Kernel, Hook, pool initialization, config write and sealing
   occur in one transaction and roll back together.
5. Initial liquidity is a separate publisher transaction; absence of liquidity
   makes trading fail naturally.
6. Canonical Router exposes exact-input NOP buy, signed VM buy, sell, and the
   authenticated PoolManager callback only. It accepts no arbitrary PoolKey or
   hookData and has no owner, pause, proxy, sweep, governance or upgrade path.
7. Offchain manifest hash/signature never replaces independent onchain
   reconstruction. `configHash` and `manifestHash` are intentionally distinct.

## Remaining stages

- **7B — complete (internal, unaudited):** adversarial/stateful fuzzing,
  economic/MEV boundaries, salt recovery drill, manifest trust-boundary hardening,
  pinned Slither triage and code-size gates. See `docs/STAGE7B.md`.
- **7C — not pursued / incomplete:** immutable candidate
  `swaputer-v1.1-stage7c-rc2` remains available, but no independent auditor or
  report exists. The project decided not to commission an external audit for
  this release line; internal and AI checks are not an audit. S7B-002 remains an
  open Medium. Any future audit must restart Stage 7C against a fresh candidate.
- **7D-U1 — local preparation complete, still unaudited:** release policy, zero-value
  local/testnet preflight, Bug Bounty draft, incident response, repeatable Anvil
  deployment and indexer recovery. Four parameterized isolated-Anvil releases,
  branch replacement, manifest verification and backup/restore passed. This does
  not authorize public testnet, mainnet or real funds and must always expose
  `unaudited experimental`. See `docs/STAGE7D-U1.md`.
- **7D-U2 — Base Sepolia zero-value release deployed, still unaudited:** the
  exact official PoolManager-bound World, five successful VM buys, sell and two
  atomic rollback paths were exercised; an unsigned manifest and real-log
  indexer evidence were reconstructed. The release is experimental and uses no
  real-value asset. See `docs/STAGE7D-U2.md`.
- **7M — approved strategy, implementation incomplete:** the release target is
  an `unaudited experimental` capped-mainnet deployment. Mainnet remains blocked
  until the fresh v1.2 candidate, internal assurance, known-risk disposition,
  documented single-owner custody, economic approval, Base Mainnet upstream binding,
  recorded operational risk acceptance and explicit deployment authorization
  gates in `docs/STAGE7M-UNAUDITED-MAINNET.md` pass. Existing Base Sepolia
  ten-minute history is accepted without an additional final-candidate soak.

The unified current gate is `./script/accept-stage7d-u1.sh`, which first runs
the complete `./script/accept-stage7b.sh` gate. Stage 7B changed no
file under `docs/spec/` and no reference package.
