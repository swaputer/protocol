# Stage 7M — unaudited capped-mainnet release policy

Status: **approved as the current release strategy; implementation incomplete;
mainnet deployment is not yet authorized**.

## Decision

The project has decided not to commission an independent external audit for the
current Swaputer release line. Stage 7C remains incomplete and is no longer a
planned prerequisite for Stage 7M. The historical v1.1 audit snapshot is kept
only as reproducible review material; it is not an audit report and does not
cover the current v1.2 implementation.

This decision changes the intended release target from an audited production
release to an **unaudited, capped, experimental mainnet release**. It does not
assert that external review is unnecessary, that internal testing is an audit,
or that the system is secure or production-ready.

## Non-negotiable public claims

Every official release artifact, transaction-bearing interface and release
announcement for Stage 7M must state `unaudited experimental`. It must not use
`audited`, `secure`, `production-ready`, or language that implies loss is
impossible. Mainnet is permissionless: project limits on official liquidity and
interfaces cannot prevent third parties from interacting with the contracts or
supplying funds.

Swaputer Worlds have no pause or upgrade path. An incident response can stop
official recommendations and interfaces and can publish a replacement World;
it cannot freeze the deployed World or guarantee withdrawal of third-party
liquidity.

## v1.2 rc3 launch-scope decision

The project froze one clean, reproducible v1.2 candidate commit and annotated
immutable tag before mainnet authorization. That candidate records the scope
that was accepted at freeze time. Remote publication and the owner's signed
mainnet authorization are separate later actions; neither is implied by the
local candidate freeze.

The Stage 7M v1.2 rc3 candidate freezes the following first-release scope:

- CreationCodeStore, WorldFactory, WorldDeployer, Hook, Kernel, MiniVM, Gas
  Token, ReferenceRegistry and the canonical Swaputer Router;
- direct signed SVM execution through the official Universal Router;
- TinySol, the OpenMint SRC20 package, Studio and Minter;
- the receipt codec, release verifier, production indexer, explorer and
  monitoring required to build and observe those components.

On 2026-09-10, the project owner approved the SRC20 market, MarketFactory and
sETH bridge for the first mainnet launch. The owner explicitly accepted using
their already-frozen source and assurance evidence without expanding or
re-freezing the rc3 candidate and without repeating candidate acceptance. One
complete Base Sepolia release-gate run is required after this decision and must
exercise both Market settlement and the sETH deposit/redemption solvency path.
This is an explicit scope-governance exception and does not authorize mainnet
deployment or replace the still-required mainnet parameters and owner
authorization. Auction and AuctionFactory remain retired from current source,
tooling, active manifests and official interfaces. The immutable rc3 candidate
and historical Base Sepolia records retain Auction evidence only as history.

The machine-readable scope and source/artifact commitments live under
`release/v1.2/`. The local candidate tag is
`swaputer-v1.2-stage7m-rc3`. A local tag is not evidence of remote publication,
tag protection, a release signature or permission to deploy mainnet.

## rc3 completed gate evidence

The local candidate freeze and the two requested internal-assurance gates were
completed on 2026-09-06 and bind the same clean candidate commit
`bb08340ebb4f4a1bfbcd46617e1cd0f5c4951abf`:

- the annotated immutable tag `swaputer-v1.2-stage7m-rc3` freezes 744 source
  files, recursive dependencies, toolchain inputs, launch scope and
  deterministic contract artifacts;
- `security-results/stage7m-s7b002.json` records all three salt-recovery
  scenarios. S7B-002 remains **Accepted/Open**, including failed gas, release
  delay, invalidated drafts and non-official immutable Worlds as residual
  availability risks;
- `security-results/stage7m-multiseed.json` records three required seeds,
  135,168 fuzz executions and 1,081,344 invariant action calls with zero
  failures or unexpected reverts;
- `security-results/stage7m-base-mainnet-fork.json` binds a finalized Base
  Mainnet block and verifies upstream runtime code, contract bindings, direct
  official Universal Router `V4_SWAP` SVM DEPLOY/CALL behavior, economic
  accounting and the required adversarial rollback cases. The rehearsal is
  read-only and broadcasts no mainnet transaction.

These records complete the candidate-freeze, S7B-002-disposition and
multi-seed/fork-rehearsal work items. They do not authorize mainnet. Economic
parameter approval, the named dedicated owner EOA,
publication/configuration work and explicit human deployment authorization
remain separate gates. The project accepts the accumulated Base Sepolia
ten-minute history and does not require an additional final-candidate or
final-configuration observation window.

## Accepted operational omissions

The project accepts the following Stage 7M operating model:

- no dedicated security-reporting channel and no funded bug bounty;
- one RPC provider, with no provider failover;
- no off-host or geographically separate database backup;
- no formal on-call owner, rotation or response SLA.

These are deliberate omissions, not completed security controls. An RPC outage
can stop official reads, indexing and transaction submission while the contracts
continue to run. Loss of the indexer host or its local backups can require a full
chain replay and can destroy local operational evidence. Alerts can remain
unattended, and vulnerability reports may be delayed, public, or never reach the
project. The mainnet release record must preserve these facts and must not imply
redundancy, guaranteed recovery or a managed security-response service.

## Required gates

Skipping Stage 7C and accepting the operational omissions above does not waive
the following gates:

1. **Reproducible candidate:** clean tree, exact recursive dependency and
   toolchain inventories, deterministic artifacts, complete source/code-hash
   inventory, a content-addressed candidate record and an annotated tag. The
   owner-signed mainnet authorization remains a separate part of gate 7.
2. **Internal assurance:** all Foundry, invariant, fuzz, differential, indexer,
   frontend and release-policy tests pass against the candidate. Multiple
   recorded fuzz seeds and mainnet-fork adversarial cases must supplement the
   deterministic release seed.
3. **Known-risk disposition:** S7B-002 uses the documented salt-recovery
   procedure. Rehearsal evidence must show exact-copy and conflicting-salt
   outcomes, atomic rollback, replacement-address recomputation and successful
   recovery. The isolated test is bounded to 15 minutes, but this is not an
   operator response SLA or a public-mempool timing claim. The project
   explicitly accepts failed gas, delay and permanent non-official Worlds as
   residual availability risks; protected submission is not assumed.
4. **Single-owner authority and custody:** `feeController`, `feeAdmin` and the
   official LP NFT are assigned to the same explicitly approved owner EOA. The
   project accepts that this model has no multisig quorum or timelock: compromise
   permits immediate fee changes up to the onchain cap, fee claims and LP
   management, while key loss can permanently disable those operations. The
   release record must name this model and its owner address. The owner must use
   a dedicated mainnet key with an offline recovery copy; no production role may
   use `wallet.txt` or another developer/test key.
5. **Economic approval:** initial price, liquidity range and cap, LP fee,
   protocol fee, byte-gas price, byte limit, per-transaction exposure and
   application limits are measured on a Base Mainnet fork and approved in a
   machine-readable release record.
6. **Upstream binding:** Base Mainnet PoolManager, PositionManager, Permit2 and
   Universal Router addresses and runtime code hashes are independently
   verified, then exercised through a fresh-fork release rehearsal.
7. **Staged launch:** deployment begins with explicitly capped project-owned
   value, verifies every receipt and code hash before public recommendation,
   and requires an explicit human authorization record before limits or
   application scope are expanded.

The existing ten-minute Base Sepolia loops and their finalized indexing
evidence remain useful operational monitoring, but the project explicitly does
not require a new soak window, a forced final cycle or an additional full
release-gate run after filling the final configuration. This accepted omission
does not convert historical testnet activity into a mainnet guarantee.

## Current enforcement

Existing testnet release schemas, deployment scripts and chain guards continue
to reject public mainnet. No Base Mainnet configuration or release artifact may
be added merely because the audit requirement was removed. Those guards may be
changed only as part of a dedicated Stage 7M implementation after every other
gate above has objective evidence.

Historical Stage 7C audit materials remain available if the project later
reconsiders the decision. Resuming an audit would require a fresh candidate and
does not retroactively change the `unaudited` status of any Stage 7M deployment.
