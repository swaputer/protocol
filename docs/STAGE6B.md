# Stage 6B: reorg-safe reference indexer

Stage 6B adds a runnable TypeScript reference indexer around the Stage 6A strict codec. It ingests only the exact outer `VMLog(bytes32,uint64,bytes)` from explicitly configured Kernel addresses, stores raw and expanded receipt data in SQLite, resumes from a transactional cursor, and converges after bounded chain reorganizations. It does not decode application ABIs or assign trusted SRC/AMM labels.

## Architecture and trust boundaries

`tooling/indexer/` contains four boundaries:

1. `rpc.ts` is an injectable JSON-RPC transport. The production implementation uses native `fetch`; tests use an in-memory fake provider.
2. `outer-log.ts` validates the configured address, exact event topic, three-topic layout, canonical uint64 height word, and the complete ABI encoding of one dynamic `bytes` value.
3. Stage 6A `decodeVMReceipt` remains the only receipt decoder. Stage 6B neither copies nor weakens it.
4. `indexer.ts` applies protocol integrity rules and commits one complete block per SQLite transaction.

Ethereum RPC is untrusted input. The configured `chainId`, genesis hash, Kernel address, optional World filter and parent-hash chain are verified before records become canonical. `removed` is retained as raw provider input but never used as the authority for reorg detection. Application topics are unverified claims and remain `kernel_record_kind = 'application'` regardless of whether they resemble `Transfer` or `Swap`.

All potentially large chain quantities are parsed as `bigint` and persisted as canonical decimal `TEXT`. This includes chain ID, block number, timestamp, transaction/log indexes and execution height. SQLite's integer representation is used only for bounded local row IDs, counts, booleans and `vmLogIndex`.

## SQLite schema and migration

Migration `001_initial.sql` is explicit, versioned and repeatable. It creates:

- `chains`: chain ID and immutable genesis identity;
- `kernels`: Kernel/World filter and persisted scan policy, excluding the RPC URL;
- `blocks`: canonical and orphan block hashes, parents, timestamps and finality;
- `vm_executions`: complete Ethereum identity, outer fields, raw log data and raw receipt payload;
- `vm_records`: authoritative `vmLogIndex`, emitter, four lossless topic columns, raw data and only the three codec-level record kinds;
- `program_deployments`: Kernel-verified contract ID, creator and code hash;
- `ingestion_cursor`: next block and last canonical hash per Kernel;
- `ingestion_errors`: stable error code/category, raw log, occurrence timestamps and retryability;
- `schema_migrations`: applied migration versions.

The authoritative record identity is represented by the execution uniqueness tuple `(chainId, kernelAddress, blockHash, transactionHash, ethereumLogIndex)` plus `vmLogIndex`. No new consensus hash encoding is invented. Partial unique indexes enforce one canonical block per height, one canonical execution per `(Kernel, World, executionHeight)`, and one canonical deployment per `(Kernel, World, contractId)`.

## Cursor and transaction model

`eth_getLogs` is requested in configurable chunks. Logs are sorted by `(blockNumber, transactionIndex, logIndex)` before ingestion. Each block header, its valid executions, every expanded record, deployments, quarantine entries and the cursor advance are committed in one synchronous SQLite transaction. A thrown error rolls back the entire block and leaves `nextBlock` unchanged. Restarting opens the same migration version and resumes from that cursor; repeated ranges and repeated logs hit authoritative uniqueness constraints and remain idempotent.

Temporary RPC failures use bounded exponential backoff. Provider range-limit errors halve the requested range until it succeeds or reaches one block. Exhausted transport failures use category `RPC`, while malformed log/receipt and protocol failures use `OUTER_LOG`, `RECEIPT` or `INTEGRITY`.

## Reorg algorithm

Before each chunk, the indexer compares its canonical tip to `eth_getBlockByNumber`. A stored height with a different hash, a missing remote tip, or a new block whose parent differs from the stored canonical parent starts reconciliation:

1. compare local and remote hashes while walking backward;
2. stop at the common ancestor, or at the configured `startBlock - 1` boundary when indexing began mid-chain;
3. abort with fatal `REORG_DEPTH_EXCEEDED` if the walk exceeds `maxReorgDepth`;
4. in one transaction mark old blocks, executions, records and deployments non-canonical/non-finalized;
5. retain all old raw rows and record `REORG_DETECTED`;
6. rewind every affected chain cursor to the ancestor plus one;
7. replay the replacement branch normally.

Canonical deployment queries therefore cannot see orphan mappings. Replacement executions may reuse the old branch's execution heights because continuity considers canonical rows only.

## Quarantine and protocol integrity

An individual `VMLog` is quarantined atomically when outer ABI or Stage 6A decoding fails. It produces no execution, record or deployment rows. Integrity validation additionally enforces:

- nonzero execution height;
- any first observed height when starting mid-chain, then exact `+1` continuity;
- no duplicate canonical height;
- exactly the final summary required by the Stage 6A codec;
- deployment records and mappings derived only from the same receipt;
- no repeated contract deployment and no conflicting canonical code hash.

Errors have a stable `IndexerErrorCode`, category, retryability/fatality and JSON-safe details. Repeated observations update `lastSeen` and occurrence count instead of duplicating quarantine rows. RPC URLs and credentials are not stored or echoed by the CLI.

## CLI and query surface

The installed binary exposes:

```text
swaputer-indexer init --db <path>
swaputer-indexer sync --rpc <url> --chain-id <id> --kernel <address> \
  --start-block <number> --confirmations <number> --db <path>
swaputer-indexer status --db <path>
swaputer-indexer executions|records|deployments --db <path>
```

`status` reports the canonical/finalized tips, next block, canonical execution/record/deployment counts, quarantine/error count and last sync time. The public TypeScript API additionally exports `SwapVMIndexer`, `RpcTransport`, `HttpJsonRpcTransport`, strict outer-log parsing, migration/database helpers and lossless raw query functions.

## Tests and local Anvil E2E

The network-free suite contains 29 tests covering migration replay, outer ABI malformations, first/empty/multi-block scans, explicit target bounds and resume-to-head behavior, ordering, duplicates, restart, transaction rollback, bounded retry, range shrinking, precision above `2^53`, quarantine atomicity, height gaps/duplicates, deployment conflicts, Kernel/World filtering, raw Transfer-shaped records, finality, one/multi-block reorgs and maximum-depth failure.

The Anvil test generates an ephemeral private key only in process memory, funds that temporary account locally, deploys the production `SwaputerKernel` bound to a test-only driver, and produces 13 real Kernel executions. They include NOP, DEPLOY, authenticated CALL, SRC-20 deployment/transfer and a complete CPAMM deployment/liquidity/swap path. It indexes the real Ethereum logs, verifies five deployments and scenario record order, reverts to an Anvil snapshot, produces a replacement branch at heights 1–13, and proves the old 13 executions and five deployments are orphaned. The process, temporary SQLite files and chain-specific broadcast artifacts are removed automatically.

The driver replaces only the outer Hook/Pool settlement in this indexer-focused test. Receipt creation, signature validation, MiniVM execution, program deployments and virtual records all run through the unmodified production Kernel. Existing Stage 1–5 Foundry tests remain the authority for real Uniswap v4 settlement.

## Performance boundaries and Stage 6C interface

The reference implementation favors deterministic integrity over high write concurrency. SQLite uses WAL, foreign keys, full synchronous durability and short block transactions. RPC chunk size is configurable and receipt size remains bounded by the frozen 65,536-byte limit. The synchronous SQLite driver is appropriate for one writer and local analytical reads; high-write multi-chain production operation would require explicit capacity testing and possibly a different storage service without changing the ingestion semantics.

Stage 6C can consume canonical `vm_records`, join deployment `code_hash`, and bind an ABI only by `(worldId, emitter, immutable codeHash)`. It must treat current raw tables as immutable chain history, create separate derived views, and never relabel application records based on topic shape alone.

No conflict was found between the frozen v1.1 specification, Stage 6A codec and real Kernel output during Stage 6B.
