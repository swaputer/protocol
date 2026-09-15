# Stage 6A: strict `VMReceiptV1` codec

Stage 6A implements an independent, reusable TypeScript codec for the frozen v1 receipt format and binds it to receipts emitted by deterministic Foundry executions. It does not add an indexer, RPC client, database, TinySol compiler, application ABI registry or deployment workflow.

## Layout and public API

The package lives in `tooling/receipt-codec/`:

- `src/codec.ts`, `src/types.ts`, `src/hex.ts` and `src/errors.ts` are the dependency-free runtime;
- `src/constants.ts` is generated from the Solidity protocol constants and checked against their source;
- `scripts/` contains constant, fixture and freeze-manifest consistency checks;
- `fixtures/raw/` contains the independently flattened Foundry output;
- `fixtures/` contains normalized, reviewable golden receipts;
- `test/` contains canonical, boundary, adversarial, consistency and cross-language tests.

The public API is:

```ts
decodeVMReceipt(input: Uint8Array | `0x${string}`): VMReceiptV1
encodeVMReceipt(receipt: VMReceiptV1Input | VMReceiptV1): Uint8Array
encodeVMReceiptHex(receipt: VMReceiptV1Input | VMReceiptV1): `0x${string}`
```

The package also exports its readonly receipt/record types, hex helpers, protocol constants, `ReceiptErrorCode`, `VMReceiptError` and `isVMReceiptError`. Decoding is atomic: no receipt or partial record array is returned until the entire input and the mandatory final summary have passed validation. Unknown application records retain their exact emitter, topics and data without receiving a trust label.

## Strictness and error model

All integer fields use network byte order. The decoder validates the v1 version and flags, payload/record/topic/data limits, every available byte range, checked length arithmetic, the record length equation, exact record consumption, exact record count and absence of trailing bytes. It then requires exactly one final `WorldExecution` record, validates both known Kernel record widths and the canonical 32-byte encoding of `executedBytes`, and rejects Kernel selectors under any non-Kernel emitter.

Failures throw `VMReceiptError`. Callers and tests compare the stable `code` field from `ReceiptErrorCode`; the optional `offset` and immutable `details` provide diagnostics without making error text part of the API contract.

## Constants and source binding

`scripts/generate-constants.mjs` extracts `KERNEL_EMITTER_ID`, the Kernel signature strings, the receipt version and receipt limits from `SwaputerKernel.sol` and `SwapVMMiniVM.sol`, derives both topic hashes with Keccak-256, and generates `src/constants.ts`. Build and typecheck run the generator in check mode, while `test/constants.test.ts` independently compares the exported values to the Solidity sources. Fixed v1 layout widths and flags are documented by the frozen section 23 format and tested against real Solidity output.

## Reproducible golden fixtures

`test/utils/ReceiptFixture.sol` locates the one real `VMLog` emitted by the Kernel, parses its payload independently in Solidity, serializes every field, and either compares the result byte-for-byte with the committed raw fixture or writes it when `SWAPVM_WRITE_RECEIPT_FIXTURES=1` is set. It uses existing deterministic local PoolManager/Kernel fixtures and requires no RPC or random chain state.

The six scenarios are:

1. `unsigned-nop`: unsigned NOP buy and final execution summary;
2. `authenticated-call`: v1.1 actor-bound authenticated CALL;
3. `deploy`: deployment record followed by the execution summary;
4. `src20-transfer`: nested SRC-20 `Transfer` record and summary;
5. `src721-transfer`: SRC-721 event record and summary;
6. `cpamm-swap`: nested token records, CPAMM `Swap` record and final summary.

The exact regeneration command is documented in `tooling/receipt-codec/fixtures/README.md`. `scripts/materialize-fixtures.mjs --check` prevents normalized fixtures from drifting from their raw Foundry source, and TypeScript tests compare every decoded record field and canonical order before enforcing `encode(decode(payload)) === payload`.

## Adversarial coverage

Explicit tests cover every truncation point in every golden receipt; unsupported versions and flags; record-count values 0, 1, 64, 65 and 65,535; record and data lengths changed by one; topic counts 0, 4, 5 and 255; maximum and excessive record data; exactly 65,536-byte and excessive payloads; trailing bytes; missing and extra records; missing, duplicate and non-final summaries; malformed Kernel widths; forged selectors and emitters; non-canonical `uint32` words; malformed hex; and a malicious application `Transfer` claim that must remain raw and unverified.

## Verification

Run the complete local checks with:

```sh
cd tooling/receipt-codec
npm ci
npm run build
npm run typecheck
npm test
npm run check:manifests

cd ../..
forge fmt --check
forge build --sizes
forge test -vvv
forge snapshot --check
```

CI performs the same checks. The manifest command verifies SHA-256 and Keccak-256 for the frozen v1.1 specification and ISA and repeats the historical v1.0 specification/ISA verification without modifying any frozen file.

The Stage 6A acceptance run on 2026-08-28 produced:

- TypeScript: 31 tests in 5 suites, all passing;
- Foundry: 76 tests in 8 suites, all passing, including 512-run fuzz tests and invariants configured for 64 runs × 32 calls;
- gas snapshot: `forge snapshot --check` passing after adding the fixture-test baselines;
- production runtime sizes: `SwaputerToken` 1,350 bytes, `SwaputerHook` 5,842 bytes, `SwaputerKernel` 21,918 bytes and `SwaputerProgramRegistry` 1,606 bytes;
- test-only `ReceiptFixture` runtime size: 5,801 bytes;
- fixture scenario gas: unsigned NOP 326,107; authenticated CALL 563,035; DEPLOY 857,948; SRC-20 transfer 6,277,060; SRC-721 transfer 6,663,600; CPAMM swap 30,453,823.

Fixture scenario gas includes execution of each full Foundry scenario plus Solidity-side fixture expansion and byte-for-byte comparison. It is test instrumentation data, not an estimate of a TypeScript decoder's cost or an on-chain production codec.

## Deferred work and residual risk

Stages 6B-6D remain deliberately unimplemented: there is no chain scanner/reorg-aware persistence, SQLite schema/query layer, application ABI/code-hash registry, TinySol compiler or operator deployment package. The codec recognizes only the two Kernel record selectors frozen for receipt v1; adding Kernel records requires an explicitly versioned protocol decision rather than silently treating a reserved-emitter record as application data. The TypeScript package is private and has not received an independent security audit.

No discrepancy was found between the frozen section 23 encoding and the current on-chain receipt builder during Stage 6A implementation.
