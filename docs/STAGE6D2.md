# Stage 6D2: TinySol v1 language and deterministic compiler

Stage 6D2 adds a real experimental TinySol compiler without changing any frozen protocol file, production Kernel/MiniVM code, reference package or receipt encoding. High-level source lowers to auditable `.svasm`, then the Stage 6D1 assembler remains the only byte encoder and consensus structural validator.

## Implementation and API

`tooling/tinysol/src/lexer.ts`, `parser.ts`, `semantic.ts`, `compiler-artifacts.ts` and `codegen.ts` implement the pipeline. `compiler-types.ts` exports immutable token, AST, typed, ABI, descriptor, layout, source-map, manifest and result types. The public stages are `lexTinySol`, `parseTinySol`, `resolveTinySol`, `typeCheckTinySol`, `lowerTinySol`, `compileTinySol`, `checkTinySol` and `formatDiagnostics`.

Successful compilation returns ABI selectors/canonical JSON/hash, a Stage 6C event descriptor/hash, storage layout/hash, assembly, code/package bytes/hash, source map, deterministic build manifest and compiler identity. Failed semantic analysis never calls the assembler and returns no package. The compiler is explicitly `experimental-unaudited`, with optimization profile `none`.

## Fixtures and examples

Nine committed sources cover `Counter`, `Mapping`, `EventDemo`, `MiniToken`, `MiniNFT`, `Context`, `NestedCaller`, `Factory` and `ControlFlow`. `scripts/generate-compiler-fixtures.ts` explicitly compiles them into `fixtures/compiler/*.json`; `--check` compares every committed byte and sidecar without regeneration. MiniToken/MiniNFT are language demonstrations, not canonical SRC packages.

`test/SwapVMStage6D2.t.sol` loads those exact packages into an unmodified `SwapVMMiniVM` harness and executes constructor/runtime paths, storage, mappings, wraparound, signed operations, short-circuit logic, branches/loops, return/revert, contexts, virtual events, CALL/STATICCALL/CREATE, shared metering, rollback, static runtime enforcement and dispatcher failures.

The separate local-Anvil test deploys EventDemo, MiniToken and MiniNFT through the real production Kernel. Stage 6B scans six real `VMLog` receipts, Stage 6C registers the generated descriptors as `declared_unverified`, decodes three application events, confirms both Transfer-shaped events remain unverified, then replaces the branch and proves derived events follow the canonical reorg while orphan history is retained.

## Determinism and scope

The source fingerprint generator hashes a sorted explicit compiler source set, package manifest and generated ISA binding; the lockfile SHA-256 is recorded separately. Builds normalize line endings and logical filenames never enter package or manifest identity. CLI compilation preflights all seven outputs, writes temporary files and only then renames them; parse/type failures leave no deployable artifact.

Stage 6D2 does not include a complete local interpreter, concrete dynamic byte estimator, signing UX, IDE, public RPC access or deployment. Those simulation and estimation responsibilities remain Stage 6D3. No protocol conflict was found: every needed construct lowered to the already frozen ISA and package format.

## Acceptance results

The completed local acceptance run produced:

- TinySol build/typecheck, compiler identity, nine-example compilation, compiler fixture drift, D1 ISA/reference/corpus drift and 47 TypeScript tests: passed;
- Foundry Stage 6D2 execution harness: 10 passed; complete Foundry baseline: 91 passed, 0 failed;
- receipt codec: 31 passed; indexer/ABI/reorg suite: 45 passed; migration check: 1 passed;
- original reference Anvil E2E and compiler-event Anvil E2E: 1 passed each, including canonical reorg replacement;
- `forge fmt --check`, `forge build --sizes` and `forge snapshot --check`: passed;
- v1.1 specification/ISA and historical v1.0 specification/ISA manifests: verified;
- all three npm audits: zero vulnerabilities.

Production runtime sizes did not change: `SwaputerKernel` 21,918 bytes, `SwaputerHook` 5,842 bytes, `SwaputerToken` 1,350 bytes and `SwaputerProgramRegistry` 1,606 bytes. The test-only Stage 6D2 MiniVM harness is 16,456 bytes; `Stage6BKernelDriver` remains 2,311 bytes.

Stage 6D2 harness gas snapshots are 6,600,245 for CALL/STATICCALL/CREATE and shared metering, 6,409,496 for child rollback/static defense, 4,710,383 for control-flow/signed/bool behavior, 3,813,849 for require rollback, 2,666,534 for context and ABI address validation, 2,460,862 for constructor/dispatcher/wraparound, 1,614,531 for mapping layout, 1,363,862 for dispatcher rejection, 1,226,660 for event layout and 109,889 for source-map metadata. These are Solidity test-harness costs, not compiler output fee estimates.
