# Stage 6C: verified ABI registry and application-event decoding

Stage 6C adds a rebuildable application-event layer to the Stage 6B raw index. It does not alter `VMReceiptV1`, reference packages, the Kernel receipt builder or any Ethereum event. Raw `vm_executions`, `vm_records` and `program_deployments` remain authoritative.

## Trust and identity

An event binding is resolved only through `(chainId, kernelAddress, worldId, emitter, immutable codeHash)`. The decoder first finds the emitter's deployment on the exact block ancestry of the execution, including constructor records that precede their `MiniContractDeployed` record in the same receipt. It then selects an enabled registry entry for the exact code hash.

Trust levels are:

- `verified_reference`: generated only from the repository's SRC-20, SRC-721, SRC-1155 and CPAMM artifacts;
- `declared_unverified`: user-supplied descriptor bound to an exact code hash;
- `unknown`: no enabled registry candidate.

A built-in verified entry takes precedence over user declarations for the same hash. Multiple candidates at the selected trust level are `ambiguous` and are not decoded. A Transfer-shaped record under another code hash never inherits SRC trust.

## Reference artifact verification

`registry/reference-event-layouts.json` contains the field layout confirmed from `script/generate_reference_programs.py` and the Stage 4/5 virtual-record assertions. `scripts/generate-reference-registry.mjs` reads the four existing artifacts and fails unless:

- Keccak-256 of the full package equals `codeHash`;
- Keccak-256 of exact UTF-8 `abiCanonical` equals `abiHash`;
- every event signature hashes to its committed topic;
- every function signature hashes to its committed selector;
- the XOR interface ID matches;
- required identity fields exist and code hashes/identities do not conflict;
- descriptor signatures, types and indexed/data positions agree with the artifact ABI.

The generated TypeScript registry is checked during build and typecheck. The tooling descriptor hash is separately named `descriptorHash`; it is never presented as the artifact `abiHash`.

## `SwapVMEventABI` v1

The offchain descriptor supports only static 32-byte event words: `uint256`, `int256`, `bool`, `bytes32`, `account` and `address`. Indexed positions start at topic 1 because topic 0 is the selector; data positions start at zero and both position sets must be contiguous. Signatures use `bytes32` for the tooling `account` type.

Decoding uses `bigint` internally. Stored/CLI integers are decimal strings. Booleans accept only zero or one, addresses require twelve zero high bytes, and bytes32/account/address values are normalized lowercase hex. Accounts are classified as `zero`, `EOA`, `contract`, `Kernel` or `unknown-tag`; an unknown tag is preserved rather than rejected.

Descriptor objects are strictly validated, canonically serialized with sorted object keys, and hashed with Keccak-256. Unsupported fields, unexpected keys, inconsistent signatures, duplicate topics, gaps and excessive indexed fields are rejected at registration.

## Database and rebuild

Migration `002_abi_registry.sql` adds `abi_registry`, `program_abi_bindings`, `decoded_events`, `decoded_event_fields` and `event_decode_errors`. It does not edit migration 001. All derived rows reference the raw execution/record or deployment that produced them; canonical/finalized queries join Stage 6B authority instead of copying those decisions.

`rebuildDecodedEvents` rebuilds bindings and selected records in one transaction. It can filter by chain, Kernel, World, block range, registry or code hash, is idempotent, and processes canonical plus orphan history. Adding, disabling or replacing a declaration followed by rebuild changes only derived rows. Indexer sync performs the same rebuild after raw block commits, so a user ABI failure cannot roll back or advance the ingestion cursor incorrectly.

Known-event width, boolean or address failures create a `failed` derived event and stable `event_decode_errors` entry without partial fields. Unknown programs/selectors are normal queryable statuses. Other records in the same receipt continue decoding.

## CLI

```text
swaputer-indexer registry list --db <path>
swaputer-indexer registry verify --db <path>
swaputer-indexer registry add --db <path> --descriptor <file>
swaputer-indexer registry disable --db <path> --registry-id <id>
swaputer-indexer decode rebuild --db <path> [scope filters]
swaputer-indexer events --db <path> [identity/event/account/token/finality filters]
```

## Scope boundary

Stage 6C does not derive authoritative balances or ownership, compile TinySol, simulate the VM, access wallets, scan public RPC endpoints or deploy contracts. Event-derived views remain secondary to VM state returned by `staticCall`.

## Verification

The completed Stage 6C verification run produced:

- indexer build, typecheck and generated-registry drift check: passed;
- indexer unit, database, CLI, reorg and decoder suites: 45 passed, 0 failed;
- deterministic Anvil/real-Kernel end-to-end suite: 1 passed, including 13 verified application events on the original branch and their preservation as orphan history after reorg;
- Stage 6A receipt-codec suite: 31 passed, 0 failed;
- Foundry suites: 76 passed, 0 failed, including fuzz and invariant runs;
- `forge fmt --check`, `forge build --sizes` and `forge snapshot --check`: passed;
- v1.1 spec/ISA and v1.0 historical spec/ISA manifest checks: passed;
- npm production dependency audits for both TypeScript workspaces: 0 vulnerabilities.

Runtime sizes remain unchanged because Stage 6C is offchain-only: `SwapVMKernel` 21,918 bytes, `SwapVMHook` 5,842 bytes, `SwapVMGasToken` 1,350 bytes, `SwapVMReferenceRegistry` 1,606 bytes and `SwapVMStage6BDriver` 2,311 bytes.
