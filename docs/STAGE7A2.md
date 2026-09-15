# Stage 7A2 — production release-surface implementation

## Outcome

Stage 7A2 promotes the executable 7A1-P design into production-source release
candidate components. It does not claim audit completion and performs no public
deployment. Frozen v1.1 consensus contracts and artifacts are unchanged.

## Solidity surface

- `SwaputerCreationCodeStore`: inert, write-once bytecode container. Runtime is a
  leading STOP followed by exact release creation code.
- `SwaputerWorldDeployer`: immutable Factory-only, one-shot per-world deployer.
  It hash-checks code read from both stores, CREATEs Kernel as nonce-1 child,
  CREATE2-deploys Hook, and verifies every bidirectional immutable binding.
- `SwaputerWorldFactory`: binds one existing PoolManager and EXTCODEHASH, deploys
  one canonical Router and immutable ReferenceRegistry, creates each Token/P/K/H
  graph, initializes the unique ETH/TOKEN PoolKey, writes WorldConfig once and
  seals it. It has no mutation, custody, admin or upgrade entry.
- `SwaputerAppRouter`: the four-entry frozen 7A1-P interface. It resolves only sealed
  Factory PoolKeys, uses a transient callback commitment, performs real v4
  unlock/swap/settlement, refunds only this call's unused ETH budget, transfers
  sell input only for actual debt, and leaves every transient delta at zero.

The Factory does **not** deploy PoolManager and does **not** provide initial
liquidity. A separate explicit bootstrap transaction is required before a world
is called tradable.

## Deterministic deployment

For Factory `F`, bootstrap salt `sP`, and immutable release artifact stores:

```text
P = CREATE2(F, sP, WorldDeployerInitCodeHash)
K = CREATE(P, nonce = 1)
H = CREATE2(P, minedHookSalt,
            HookCreationCode || manager || K || token || price || fee || tick)
```

`script/Stage7A2Deploy.s.sol` implements this operator sequence. Hook salt is
mined against P—not Factory and not Foundry's helper deployer. All narrow
environment values are range-checked. The script intentionally stops before
liquidity provision or manifest publication.

The Factory pins exact release artifact payload hashes:

- Kernel creation code: `0x0a9486d5dfa79bbe0eac0ee8748b013836d5a903924db1b62c313eee81ce1c33`
- Hook creation code: `0xddcc7914b6e3a101b00ccce399fc7a2d0ccb4e2bc037b8baf1142560badc29b2`

Build/tests recompute both constants from Solidity creation code, so compiler or
source drift fails before a release can create a World.

## Router behavior

- `buyNOPExactInput`: payable exact-input ETH→TOKEN, empty hookData only.
- `buyVMExactInput`: forwards one unchanged `SwaputerKernel.VMEnvelope` as
  `abi.encode(envelope)`; CALL/DEPLOY only; signed NOP is rejected.
- `sellExactInput`: TOKEN→ETH exact-input with empty hookData and therefore no
  VM execution or burn.
- `unlockCallback`: PoolManager-only and valid only while the matching transient
  callback commitment is active.

The user never supplies `byteGasPrice`; Hook and Kernel immutable price plus the
sealed Factory config are authoritative. The frozen Kernel still binds signed
`exactEthAmountIn`, price limit, recipient, Router, executor, nonce and deadline.

## Deployment manifest tooling

`tooling/deployment-manifest` is an independent Node 22/TypeScript package with
exact dependency versions and lockfile. Its public API includes:

- `finalizeManifest`, `validateManifest`, `unsignedPayload`
- `computeWorldId`, `computeWorldConfigHash`, `computeManifestHash`
- `attachEip191Signature`, `signEip191`, `verifyEip191Signature`
- `verifyObservation`, `canonicalJson`

The CLI supports `finalize`, `canonicalize`, and `verify`. It never opens RPC and
does not accept a signing key. Schema v1 is strict, rejects unknown/environment
fields, recomputes PoolKey worldId and both hashes, validates every address/code
identity, and optionally checks a caller-supplied independent chain observation.
EIP-191 publisher signatures are provenance only.

Solidity and TypeScript share a full WorldConfig golden encoding vector:
`0x2e83890640ddf1743e749e9f0aa79c8ebb6705b8c9ba74dabeee961665bd4fa3`.

## Security tests

`test/SwapVMStage7A2.t.sol` uses a real v4 PoolManager and covers deterministic
deployment, exact artifact hashes, permission bits, config sealing/hash,
cross-language vector, only-Factory/one-shot controls, prediction rollback,
signed DEPLOY/CALL, NOP buy burn, sell bypass, forced historical ETH isolation,
minimum-output atomic rollback, invalid executor/world/callback and all transient
deltas returning to zero. 7A1-P tests remain as independent conformance proof.

Run all release checks with:

```sh
npm ci --prefix tooling/deployment-manifest
./script/accept-stage7a2.sh
```

## Remaining blockers

- Stage 7B adversarial fuzz/economic and MEV hardening is not complete.
- Stage 7C independent external audit and remediation are not complete.
- Stage 7D bounty, limited deployment and incident/operations gates are not
  complete.
- No network, PoolManager deployment, liquidity policy, economic parameters,
  publisher identity, source commit/tree commitment or real manifest has been
  selected by this local implementation stage.
- Permissionless world creation has a public-salt ordering/griefing liveness
  risk. A copied transaction can only create the intended configuration, while
  a conflicting use forces the publisher to choose and mine a new bootstrap
  salt. Stage 7B must test operational recovery/private submission strategies;
  no owner or allowlist is added to mask this risk.

## Recorded acceptance

`./script/accept-stage7a2.sh` completed successfully against the pinned local
toolchain with:

- receipt codec: 31 tests and all v1.1/ISA/v1.0 freeze-manifest checks;
- indexer/ABI/reorg: 45 mock tests plus both real Anvil E2Es;
- TinySol/compiler/simulator: 62 tests and all drift/fixture/reference/corpus
  checks;
- Foundry: 122 tests, 0 failed, including 512-run Stage 7A2 Router fuzz and
  all existing stateful invariants;
- Stage 7A1-P: 10/10; Stage 7A2: 14/14;
- deployment manifest: build, typecheck and 7/7 tests;
- gas snapshot check, formatting, sized build and `git diff --check`;
- four npm audits: 0 vulnerabilities each.

Relevant production runtime/initcode sizes are:

| Contract | Runtime | Initcode |
| --- | ---: | ---: |
| `SwaputerKernel` | 21,918 B | 22,228 B |
| `SwaputerHook` | 5,842 B | 7,078 B |
| `SwaputerToken` | 1,350 B | 1,554 B |
| `SwaputerProgramRegistry` | 1,606 B | 1,632 B |
| `SwaputerAppRouter` | 6,686 B | 7,032 B |
| `SwaputerWorldDeployer` | 2,548 B | 2,812 B |
| `SwaputerWorldFactory` | 12,362 B | 22,031 B |

The Stage 6E concrete reconciliation remained exact: 278 executed bytes,
`278000000000000` estimated/actual burn, one matching Kernel VMLog, and exact
gross/net TOKEN equality. No frozen specification, ISA, manifest or reference
package mismatch was found.
