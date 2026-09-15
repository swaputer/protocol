# Ethereum Mainnet Parameter Checklist

Status: parameter collection only. This document does not authorize deployment or transaction broadcasting.

## 1. Locked launch scope

- Target network: **Ethereum Mainnet only** (`chainId: 1`).
- There is no Base mainnet deployment in this launch.
- Launch surfaces: protocol core, indexer/API, Explore, Studio, Ecosystem, and the open `SwaputerWorldFactory` flow.
- Bridge, Market, and Auction are not launch components.
- The default protocol fee is **300 bps (3%)**. The controller may set it from 0 to the contract maximum of **1,000 bps (10%)**.
- The TinySol release candidate is language `1.1`, compiler/package `0.4.0`. Freeze the exact source commit, compiler fingerprint, ISA/spec hashes, and reference-program code hashes before deployment.
- Indexer and user-facing transaction status may use the previously chosen **1-block confirmation** policy. One confirmation is not Ethereum finality; irreversible operational decisions must use the RPC `finalized` block tag.

## 2. Values that require an explicit owner decision

Do not infer any value in this section and do not request or store a private key in this document.

### 2.1 Authority and custody addresses

| Parameter | Meaning | Required decision |
| --- | --- | --- |
| Deployment sender | Pays gas and determines CREATE addresses/nonces | Public address and approved signing method |
| `initialProtocolFeeAdmin` | Claims accrued protocol fees and can transfer fee administration | Address; a Safe multisig is recommended |
| `feeController` | Changes protocol fee within 0–10%; immutable for each World | Address; use a carefully controlled multisig |
| `initialHolder` | Receives the initial SVMG supply | Address |
| LP position recipient | Owns the Uniswap v4 liquidity position NFT | Address and custody policy |
| Manifest approver | Signs off the final deployment manifest, if separate | Address or named release owner |

The deployment sender may be an EOA, hardware wallet, or managed signer. Record only its public address. Never commit a mnemonic, raw private key, RPC key, Etherscan key, or `wallet.txt` content.

### 2.2 Gas token identity and allocation

The current contract defaults are:

- Name: `Swaputer`
- Symbol: `sPuter`
- Decimals: `18`

Confirm these values before address mining. Any metadata change changes creation bytecode and predicted addresses.

Required decisions:

- Total `initialSupply`: `10,000 sPuter` / `10000000000000000000000` base units.
- Initial holder and allocation policy.
- The public distribution/allocation document to commit to.
- `distributionCommitment`: the exact `bytes32` hash and the canonical bytes/file it hashes.

### 2.3 Execution economics

- `byteGasPrice`: sPuter base units charged per executed byte. This is immutable for a World.
- Client default action/gas limit. The protocol hard maximum is currently `1,000,000`; changing that is a protocol change, not deployment configuration.
- `vmInputWei`: ETH value sent with the Uniswap/Swaputer execution path by compatible clients.
- Default `minNetTokenOut` and/or slippage policy used by clients.
- Maximum transaction value or other release-time safety limits, if desired.

These values need an economic rationale and at least three example calculations: small call, typical deployment, and maximum-size action.

### 2.4 Initial Uniswap v4 pool and liquidity

The current rehearsal candidates are `poolFee: 3000` (0.30%) and `tickSpacing: 60`; confirm rather than assume them.

Required decisions:

- Pool fee and compatible tick spacing.
- Initial price: **0.0004 ETH per 1 sPuter**.
- Initial liquidity: **0 ETH + 10,000 sPuter**, allocated single-sided across the approved six positions.
- Tick range (`tickLower`, `tickUpper`) or an explicit full-range policy.
- Maximum slippage and transaction deadline used while initializing liquidity.
- LP position recipient and whether that position is retained, locked, or governed.

`initialSqrtPriceX96` must be derived from the approved human-readable price with token ordering and decimals documented. Do not type this value by hand.

### 2.5 Production operations

- Primary and fallback Ethereum Mainnet HTTP RPC providers. Store URLs/keys only in deployment secrets, never in the public manifest.
- Optional WebSocket provider for live UX; it must not be required for correctness.
- Deployment gas policy: `maxFeePerGas`, `maxPriorityFeePerGas`, per-transaction ceiling, and total ETH budget.
- Indexer policy: `confirmations: 1` for availability, reorg depth, finalized checkpoint policy, backfill batch size, and reconciliation interval.
- Etherscan API key and contract verification owner.
- Production domains and URLs for Explore, Studio, Ecosystem, documentation, and indexer API.
- Database DSN, backup retention, restore owner, monitoring destinations, and incident contacts.
- Release window, approvers, pause/abort criteria, and rollback/containment procedure.

## 3. Ethereum Mainnet upstream bindings

The no-broadcast fork rehearsal verified the following bindings at finalized Ethereum block `25,966,137`. Treat them as candidates only and re-read their runtime bytecode hashes at a fresh `finalized` block immediately before deployment.

| Contract | Address | Expected runtime code hash |
| --- | --- | --- |
| Uniswap v4 PoolManager | `0x000000000004444c5dc75cb358380d2e3de08a90` | `0x785f1014552b7ce7d5fb7d0c970ca60edee94fd00425d7ca21609acac7ce1293` |
| Uniswap v4 PositionManager | `0xbd216513d74c8cf14cf4747e6aaa6420ff64ee9e` | `0x77e36c08b19959a30dde46dec9abe6208e371ff2f56884a56fe1e1a53615528b` |
| Permit2 | `0x000000000022d473030f116ddee9f6b43ac78ba3` | `0xc67d1657868aa5146eaf24fb879fb1fdec3d2d493b3683a61c9c2f4fb2851131` |
| Universal Router v2.2 | `0x0542093271a31f6fc1dadb232bd59eeb27de780f` | `0x1b37035dac8ecda2e578a0047748e495aa397ee4bc7640468a5b60c1c55d824c` |

If any address or code hash differs, stop. Update the rehearsal from authoritative upstream deployment records, review the change, and rerun the fork gate before broadcasting.

## 4. Values generated from the confirmed inputs

The deployment tooling must derive and record these values; the user should not invent them manually:

- Deployment sender nonce at the pinned finalized/preflight block.
- CREATE/CREATE2 salts: token, bootstrap, hook, and any factory-specific salt.
- Predicted addresses for `SwaputerCreationCodeStore`, `SwaputerWorldFactory`, `SwaputerAppRouter`, `SwaputerProgramRegistry`, `SwaputerWorldDeployer`, `SwaputerToken`, `SwaputerKernel`, `SwaputerHook`, and related core contracts.
- Address occupancy checks for every predicted address.
- Creation bytecode hashes, runtime bytecode hashes, constructor-argument encodings, and hook permission bits.
- `initialSqrtPriceX96` from the approved price, decimals, and token ordering.
- Pool key and `poolId`.
- World ID, config hash, deployment plan hash, and manifest hash.
- After broadcast only: deployment block/hash, transaction hashes, LP position token ID, and indexer `startBlock`.

All predictions must be regenerated after any source, compiler, constructor argument, salt, upstream binding, deployer, or deployer-nonce change.

## 5. Release identity and public manifest

Freeze and publish:

- Exact protocol commit SHA and immutable release tag.
- Exact TinySol/tooling commit SHA, language version, compiler/package version, compiler fingerprint, ISA revision/hash, and specification hash.
- Exact selected reference programs and their code hashes. The release owner must decide which programs are canonical at launch; do not silently expand the set.
- Solidity compiler version, optimizer/via-IR settings, source tree hash, dependency lock hashes, and build-tool versions.
- Audit reports, known risks, severity disposition, and explicit mainnet authorization/sign-off.
- A new `deployments/active/ethereum-mainnet.json` manifest containing network, upstream bindings, core addresses, selected programs, runtime hashes, economic parameters, indexer settings, integrity hashes, and deployment transaction references.

The current release metadata is still marked experimental/unaudited and `mainnetAuthorized: false`. Do not edit historical candidate records in place and do not flip authorization merely to satisfy a script. Create a new Ethereum Mainnet candidate only after the audit/risk owner has explicitly approved it.

## 6. Consumer configuration after deployment

Update all consumers from the signed Ethereum Mainnet manifest rather than copying addresses by hand:

- Indexer: chain ID, HTTP RPC, deployment/start block, Store/Router/Factory/World addresses, confirmations, reorg depth, and API/database configuration.
- Explore: network label, chain ID, RPC/indexer API, contract links, and production URL.
- Studio: supported chain ID, wallet-network guard, compiler release/fingerprint, action limits, protocol addresses, and Explore URL.
- Ecosystem/Factory: supported chain ID, wallet-network guard, protocol addresses, action defaults, and Explore/Studio/docs URLs.
- Documentation and examples: package versions, mainnet addresses, compiler/language versions, transaction flow, verification links, and risk disclosures.
- CI/release tooling: integrity checks must reject mismatched chain IDs, code hashes, compiler fingerprints, or manifest hashes.

## 7. Parameter worksheet

Fill this worksheet with public values only:

```yaml
network:
  name: Ethereum Mainnet
  chainId: 1

release:
  protocolCommit: ""
  protocolTag: ""
  toolingCommit: ""
  tinySolLanguage: "1.1"
  compilerVersion: "0.4.0"
  selectedReferencePrograms: []
  auditApprovalReference: ""
  mainnetApprovers: []

authority:
  deploymentSender: ""
  initialProtocolFeeAdmin: ""
  feeController: ""
  initialHolder: ""
  lpPositionRecipient: ""
  manifestApprover: ""

gasToken:
  name: Swaputer
  symbol: sPuter
  decimals: 18
  initialSupplyHuman: "10000"
  initialSupplyBaseUnits: "10000000000000000000000"
  distributionDocument: ""
  distributionCommitment: ""

execution:
  protocolFeeBps: 300
  byteGasPriceBaseUnits: ""
  defaultActionLimit: ""
  vmInputWei: ""
  minNetTokenOut: ""
  clientSlippageBps: ""

pool:
  fee: 3000
  tickSpacing: 60
  initialPriceEthPerSPuter: "0.0004"
  initialSqrtPriceX96: DERIVE
  liquidityEth: "0"
  liquiditySPuter: "10000"
  tickLower: ""
  tickUpper: ""
  deadlineSeconds: ""
  maxSlippageBps: ""

indexer:
  confirmations: 1
  reorgDepth: 64
  backfillBatch: 1000
  reconcileIntervalSeconds: 20
  finalizedCheckpointPolicy: ""

operations:
  primaryRpcSecretName: ""
  fallbackRpcSecretName: ""
  etherscanKeySecretName: ""
  maxFeePerGasGwei: ""
  maxPriorityFeePerGasGwei: ""
  totalDeploymentBudgetEth: ""
  releaseWindowUtc: ""
  incidentOwner: ""

domains:
  explorer: ""
  studio: ""
  ecosystem: ""
  docs: ""
  indexerApi: ""
```

## 8. Required gates before broadcast

1. Every owner-decision field above is explicitly approved; no secret is present in git, logs, chat, or the manifest.
2. Release commit and compiler/toolchain are frozen and reproducibly built.
3. Audit/risk disposition is complete and a mainnet owner authorizes the exact candidate.
4. Upstream addresses and runtime code hashes are refreshed at a current finalized block.
5. The final Ethereum fork rehearsal runs once with the exact approved parameters and exact release commit.
6. Address predictions, deployer nonce, address occupancy, balances, allowances, hook flags, token ordering, price math, and gas budget pass preflight.
7. The deployment plan and its hash are reviewed by a second person; the signer verifies chain ID `1` and each transaction payload.
8. The user gives separate explicit authorization to broadcast. Preparing this checklist is not that authorization.
9. After broadcast, runtime hashes, roles, fee, immutable settings, pool state, liquidity ownership, events, and Etherscan source verification are checked before clients are enabled.
10. The manifest is generated from observed receipts, signed/published, and then consumed by the indexer and frontends. One-confirmation UX may start only with reorg-safe reconciliation; operational finality waits for `finalized`.

## 9. Explicit non-requirements

- No Base mainnet parameter set, rehearsal, or deployment.
- No Docker image requirement for production services.
- No Bridge, Market, or Auction deployment.
- No private-key collection in the repository or task chat.
- No repeated broad test loops: run the final exact-parameter fork gate once, then the targeted post-deployment verification once.
