# SwapVM v1.1 — Stage 6 execution plan

## Goal

Stage 6 turns the existing single Ethereum `VMLog` into a trustworthy developer surface. The onchain receipt builder and nested virtual-log ordering already exist; the remaining work is a strict offchain codec, a reorg-safe reference indexer, a verified ABI registry, and the TinySol compiler/simulator toolchain.

The work is intentionally ordered so no compiler or UI depends on an unverified event pipeline.

Implementation status: Stages 6A, 6B, 6C, 6D1–6D3 and the Stage 6E total acceptance are complete. Stage 6 is a local release candidate; frontend work and public deployment are not part of this gate.

## 6A — Strict `VMReceiptV1` codec

Build a dependency-light TypeScript package that accepts raw bytes/hex and returns only fully validated receipts. It must reject before exposing partial output when any of these conditions holds:

- unsupported version or nonzero v1 flags;
- zero or more than 64 records;
- payload larger than 65,536 bytes;
- topic count above four or data above 4,096 bytes;
- truncated integers, emitter, topics, lengths or data;
- record-length mismatch, count mismatch, integer overflow or trailing bytes;
- missing, duplicated or non-final Kernel `WorldExecution` summary;
- malformed Kernel deployment/execution record widths.

Acceptance gate:

- canonical encode/decode round trips;
- golden fixtures produced by real Foundry executions for NOP, nested SRC transfer, deployment and CPAMM swap;
- adversarial byte-mutation and truncation tests across every byte boundary;
- a differential harness proving the TypeScript decoder agrees with the Solidity receipt layout;
- no provider, database or ABI-decoding dependency in the codec core.

## 6B — Reorg-safe reference indexer

Build an RPC ingestion service around the strict codec. It scans only configured Kernel addresses and the exact outer `VMLog(bytes32,uint64,bytes)` signature, then stores canonical chain data and expanded virtual records.

Minimum persisted model:

- chain and configured Kernel identity;
- block number/hash/parent hash;
- transaction hash/index and Ethereum log index;
- world ID, execution height and raw receipt payload;
- emitter, topics, data and canonical `vmLogIndex`;
- immutable program deployment/code-hash mapping;
- verified ABI binding and decoded fields;
- confirmation/finality state and ingestion cursor.

The record identity is the frozen hash of `(chainId, kernelAddress, blockHash, transactionHash, logIndex, vmLogIndex)`. A database transaction commits a block atomically. Parent-hash disagreement rolls back derived rows to the common ancestor and replays the canonical branch. Raw payloads are retained so decoder or ABI presentation upgrades can rebuild derived views without rescanning Ethereum.

Acceptance gate:

- duplicate delivery is idempotent;
- crash/restart resumes without gaps or double records;
- synthetic one-block and multi-block reorg suites converge on the canonical branch;
- malformed receipts quarantine the source log and never create partial derived state;
- execution-height gaps, duplicate heights and conflicting deployments are surfaced as integrity failures;
- a local Anvil end-to-end test deploys a World, executes NOP/SRC/AMM activity, indexes it, reorgs it and verifies rollback/replay.

## 6C — Verified ABI registry and event decoding

Decoding trust is keyed by `(worldId, emitter, immutable codeHash)`, never by a claimed event topic alone. Canonical SRC-20/SRC-721/SRC-1155 and CPAMM ABIs are accepted only when their exact package hashes match the frozen registry artifacts. User-published ABIs remain explicitly unverified until bound to reviewed code.

Acceptance gate:

- canonical package events decode into typed views;
- a malicious `Transfer`-shaped record from any other code hash is never labeled as verified SRC activity;
- unknown emitters and unknown selectors remain queryable as lossless raw records;
- ABI replacement cannot rewrite canonical raw chain history.

## 6D — TinySol v1 toolchain

Stage 6D is gated in three releases:

1. 6D1: frozen-ISA model, assembler/disassembler, consensus validator, package codec, ABI utilities and Solidity differential corpus — complete;
2. 6D2: TinySol lexer/parser, frozen type system and deterministic compiler — complete;
3. 6D3: complete local interpreter, differential execution and concrete byte-fee estimator — complete.

Implement a deterministic TypeScript toolchain driven directly by `docs/spec/SwapVM-ISA-v1.json`:

- lexer/parser and a deliberately small frozen type system;
- ABI/event selector generation;
- deterministic MiniVM code generation and `ProgramPackageV1` assembly;
- validator and disassembler;
- local interpreter with the same stack, memory, call, journal and exceptional-halt rules;
- exact executed-byte estimator for concrete calls and conservative maximum-exposure reporting for signing.

Acceptance gate:

- compiler output is reproducible and version/hash stamped;
- all canonical reference programs can be represented by golden source or equivalent assembly fixtures;
- disassemble/reassemble is byte-identical;
- simulator state, output, virtual records, reverts and byte counts match Foundry across golden, fuzzed and nested-call cases;
- the signer-facing report always shows limit, price, maximum TOKEN exposure, estimated burn, gross output and estimated net output.

## 6E — Stage gate

Stage 6 is complete only when codec, indexer and TinySol tests run in CI alongside Foundry, all frozen hashes are checked automatically, and the end-to-end suite proves one successful buy maps to exactly one Ethereum `VMLog` and the expected ordered virtual records.

Complete. `script/accept-stage6.sh` is the shared local/CI gate. Its isolated Anvil test uses the real v4 buy path, compares the simulator and fee estimate to the production transaction, exercises sell and atomic failures, then indexes and reorganizes the same actual receipts. See `docs/STAGE6E.md`.

Stage 7 remains the public-release gate: independent audit, expanded stateful fuzzing, bug bounty and only then a small-cap experimental deployment. Stage 6 completion alone does not authorize public funds.

## Immediate implementation order

1. Scaffold the TypeScript workspace and implement the pure receipt codec.
2. Export real onchain golden receipt fixtures from the current Foundry suite.
3. Add malformed-payload differential tests and freeze the codec API.
4. Implement the SQLite-backed chain cursor, block journal and reorg tests.
5. Add verified ABI decoding for the four canonical reference packages.
6. Complete the 6D1 ISA/assembly/package foundation and freeze its API.
7. Implement the 6D2 TinySol parser, type checker and compiler against that API — complete.
8. Implement the 6D3 differential simulator and concrete byte estimator — complete.
9. Run Stage 6E as the combined Stage 6 release-candidate acceptance gate before any frontend work — complete.

## Production release handoff

Stage 7 is the production release gate and contains:

1. 7A1: design, release-surface gap and threat model freeze — complete；
2. 7A2: production `SwaputerAppRouter` 与 `WorldFactory`、部署 Manifest、sealing 与原子启动 — implementation complete / unaudited；
3. 7B: internal hardening、adversarial fuzz、MEV/economic hardening；
4. 7C: independent external audit；
5. 7D: bug bounty and staged cap-limited rollout.

See [docs/STAGE7-PLAN.md](STAGE7-PLAN.md).
