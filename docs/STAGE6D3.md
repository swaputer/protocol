# Stage 6D3: deterministic MiniVM simulator and byte-fee estimator

Stage 6D3 completes the local execution half of the TinySol toolchain. It adds a dependency-light TypeScript interpreter that executes frozen ISA v1 packages without RPC access and is checked against the unmodified production `SwapVMMiniVM.sol`. It does not change the frozen specification, ISA, manifests, reference packages, production Kernel/MiniVM or TinySol v1 language.

## Public API

`tooling/tinysol/src/simulator.ts`, `simulator-types.ts` and `estimator.ts` export:

- `simulateMiniVM(input)` for root `CALL` and `DEPLOY` against an explicit immutable world snapshot;
- `simulateMiniVMCode(input)` as a low-level conformance entrypoint for malformed code and individual-opcode tests;
- `estimateMiniVMFee(input)` for concrete-path byte and TOKEN estimates;
- `emptyMiniVMWorldState()`, `MINIVM_LIMITS`, `MiniVMErrorCode` and readonly input/result/state/diff types.

World snapshots contain content-addressed package bytes, contract-to-code-hash bindings, namespaced storage and creator nonces. Context is explicit: world, actor/caller, execution height, ETH input, gross TOKEN output, tick, liquidity, byte price, block number and timestamp. The result contains success or a stable fault, output/revert data, attempted executed bytes, ordered storage journal and normalized diff, deployments, virtual records, their exact encoded bytes, root target and either the committed state or the byte-identical original state.

The interpreter implements all 132 accepted opcodes and production rules: fixed immediates, 256-bit signed/unsigned arithmetic, stack and memory ceilings, calldata/return data, validated jumps, storage journal, `ECRECOVER`, context, `LOG0..LOG4`, `CALL`, `STATICCALL`, `CREATE`, depth 32, shared byte meter, static inheritance, pending deployments and root-wide rollback. Contract IDs use exactly `0x01 || first31(keccak256("SwapVM.CREATE.v1", worldId, creator, nonce, codeHash))`. Failed execution exposes no committed storage, deployment or record.

## Exact fee estimate

For a successful deterministic simulation the estimator returns `mode: "exact"` and:

```text
estimatedActualBurn      = estimatedExecutedBytes * byteGasPrice
maximumTokenExposure     = byteGasLimit * byteGasPrice
estimatedNetTokenOutput  = grossTokenOutput - estimatedActualBurn
coverage                 = grossTokenOutput >= maximumTokenExposure + minNetTokenOut
```

`signable` is true only when simulation succeeds, the maximum-exposure precondition holds and the exact net output preserves the requested minimum. An execution revert returns no burn or net estimate, uses `mode: "unavailable"`, and is never signable. Missing or invalid input/state is rejected with a stable structured tooling error and produces no fee report. The CLI commands are `tinysol simulate --input request.json` and `tinysol estimate --input request.json`; output is recursively key-sorted stable JSON and a non-signable estimate exits nonzero.

With the committed MiniToken fixture, actor balance 1,000, transfer amount 7, byte price 11, byte limit 1,000 and gross output 1,000,000, the exact transfer path executes 373 bytes. Actual burn is 4,103 TOKEN units, maximum exposure is 11,000 and estimated net output is 995,897.

## Differential method

`scripts/generate-simulator-fixtures.ts` deterministically creates 34 full simulator scenarios, 64 fixed-seed raw-bytecode cases and a compact Solidity projection. They cover all nine Stage 6D2 compiler fixtures, the dedicated `Conformance.tiny.sol` source fixture, all four canonical reference packages, constructors, runtime dispatch, complete compiler context, loops, mappings, events, nested `CALL`, `STATICCALL`, internal `CREATE`, shared metering, child failure, static-descendant writes and byte-limit failure. The Conformance cases additionally bind arithmetic, loop/branch control flow, internal-return propagation, `account`/`address`/`bytes32`/`bool`/`uint256` ABI decoding, Event encoding, storage writes and explicit-revert rollback to the same generated package. `test/SwapVMStage6D3.t.sol` loads the compact projection and compares production Solidity output, executed bytes, ordered storage writes, deployments, encoded virtual records and rollback/error selectors; the 64 fixed-seed programs are also executed by the unmodified production MiniVM and compared byte-for-byte. Separate low-level tests cover malformed code and call-depth 33. A larger fixed-seed TypeScript property corpus adds 128 deterministic arithmetic programs, while unit boundaries cover `ECRECOVER`, memory, record data, receipt payload and OutOfByteGas.

The corpus is generated only by the explicit `simulator:fixtures:generate` command. Normal build/test uses `simulator:fixtures:check` and fails on drift. Production Solidity is the authority; neither production contract was modified for the simulator.

## Scope and remaining gate

Stage 6D3 does not add an optimizer, broader TinySol syntax, RPC state acquisition, transaction signing, wallet integration, indexer changes or frontend. `@noble/curves` is pinned only for deterministic secp256k1 recovery matching `ECRECOVER`; all state execution is local. The simulator remains experimental and unaudited.

Stage 6D is complete after this report. The next step is Stage 6E total acceptance, not frontend development. Stage 6E must re-run the codec, reorg indexer, ABI registry, compiler/simulator, Foundry, Anvil, manifest, snapshot and audit gates as one release candidate.
