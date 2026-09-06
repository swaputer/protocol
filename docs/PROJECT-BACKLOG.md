# Project Backlog

## TinySol / SVM differential conformance suite

**Status:** complete.

Extend the differential test harness so that the TinySol compile-time model and the onchain SVM executor are checked against the same generated programs and inputs. The suite must cover arithmetic, control flow, internal calls, ABI encoding and decoding, and storage reads and writes.

Acceptance requires exact agreement on successful return values, emitted Events, storage deltas, revert class, and execution outcome for every corpus case. The corpus must be deterministic, checked into version control, and runnable in CI.

Implemented with the checked-in `Conformance.tiny.sol` fixture. Its generated package and deterministic corpus cover arithmetic, loop/branch control flow, internal function return propagation, ABI handling for `account`/`address`/`bytes32`/`bool`/`uint256`, Event encoding, scalar and mapping storage writes, and rollback. The TypeScript simulator snapshot and the production `SwapVMMiniVM.sol` Foundry harness compare exact outputs, encoded records, storage journals, deployment data, execution success and the explicit-revert class. `npm run test` now also checks compiler fixtures before simulator fixture drift, so the corpus cannot silently detach from the current compiler.

## Stage 7M unaudited capped-mainnet readiness

**Status:** approved strategy; rc3 candidate and requested internal-assurance
gates complete; mainnet authorization incomplete.

The project will not commission an independent external audit for the current
release line. This decision does not mark Stage 7C complete and does not turn
internal testing into an audit. The intended release status is permanently
`unaudited experimental`.

The immutable `swaputer-v1.2-stage7m-rc3` candidate freeze, S7B-002
Accepted/Open disposition, three-seed internal assurance and finalized-block
Base Mainnet fork rehearsal now have clean-commit-bound machine evidence under
`release/v1.2/` and `security-results/`. This completes the three currently
assigned readiness items (7 percentage points in the project checklist) but
does not authorize mainnet.

Before mainnet authorization, complete the named dedicated owner EOA record,
Base Mainnet economic parameter and cap approval, package publication and
mainnet configuration, and explicit capped-deployment authorization defined in
`docs/STAGE7M-UNAUDITED-MAINNET.md`. The previously accepted single-owner and
minimal-operations risk model remains unchanged. The accumulated Base Sepolia
ten-minute history is accepted without an additional final soak or forced
release-gate run.
