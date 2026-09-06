# Stage 7B — internal adversarial hardening

## Outcome

Stage 7B adds adversarial/stateful/economic/static-analysis release evidence without changing frozen v1.1
semantics, Hook, Kernel, MiniVM, VMAction, ISA, receipt or reference packages. It is internal hardening,
not an independent audit and not authority to deploy publicly.

The unmodified pre-work `./script/accept-stage7a2.sh` baseline passed: 122 Foundry, 31 receipt,
45 indexer mock plus two Anvil E2E, 62 TinySol, 7 manifest and four zero-vulnerability npm audits.

## Added evidence

- `SwapVMStage7BSecurity.t.sol`: salt/collision rollback, multi-world isolation, forced/accidental
  balances, malicious ETH recipient reentry/revert, replay/mutation/chain binding and permissionless relay.
- `SwapVMStage7BEconomic.t.sol`: real-v4 sandwich/order vector, exact maximum-exposure boundary,
  one-unit-short atomic revert, adversarial LP add/remove and low-actual/high-maximum exposure.
- `SwapVMStage7BRouterInvariant.t.sol`: multi-actor NOP/signed DEPLOY/signed CALL buys, explicit VM
  revert/OutOfByteGas, eleven invalid-envelope/binding mutations, sells, approval changes, slippage failures,
  direct callbacks, forced ETH and accidental TOKEN. Each default invariant executes 64×32 = 2,048 calls;
  deep profile is 256×64 = 16,384 calls per property with fixed seed `0x7b2026`.
- `SwapVMStage7BFactoryInvariant.t.sol`: handler-driven copied salt, malformed K/H/permission predictions
  and repeated second-World creation. Two properties execute 4,096 default calls total and prove that
  failures cannot mutate an existing seal while any successful second World is complete and bidirectionally
  bound.
- `security-regressions.json`: threat-class index binding ten minimal cases to the existing production
  Solidity differential corpus (CALL/STATICCALL/CREATE, rollback, record order, static and byte meter).
- Manifest parser now rejects duplicate semantic members before object construction, including escaped
  Unicode aliases; observation verification now includes block number/tx, tree/artifact/compiler,
  reference programs and exact creation-code payload hashes.
- Slither 0.11.4 is exact-pinned; all 124 detector results have an explicit triage. Contract runtime and
  initcode are exact-drift and threshold gated.

## Acceptance entrypoints

```sh
./script/accept-stage7b.sh
./script/accept-stage7b.sh --deep
```

The first command calls—not replaces—`accept-stage7a2.sh`. The deep mode adds 4,096-run fuzzing,
16,384-call-per-property funded-Router stateful sequences, economic tests and the full Stage 6D3 Solidity differential.
CI runs the normal gate for push/PR and exposes the deep fixed-seed job through workflow dispatch.

## Findings and release decision

- Critical: 0; High: 0.
- Medium fixed: S7B-001 duplicate JSON field ambiguity.
- Medium accepted/open: S7B-002 public salt ordering/griefing, availability only; recovery requires new
  salt/K/H and invalidating the old draft, without an owner or allowlist.
- Low fixed: S7B-003 default fuzz seed caused nondeterministic gas snapshot statistics.
- Kernel runtime remains 21,918 bytes, 2,658 bytes below EIP-170.

Stage 7B is complete: the final recorded gate below passed. Stage 7C independent audit is the next
stage. Stage 7D bounty/limited deployment and chain-specific economic/operations gates still block public
deployment.

## Final recorded gate

`./script/accept-stage7b.sh` exited zero. Foundry passed 194/194; receipt codec 31/31; TinySol 63/63;
deployment manifest 9/9; indexer mock 45/45 plus two Anvil E2E; four npm audits reported zero
vulnerabilities. The default full suite executed 7,680 fuzz cases and 24,576 stateful calls. Dedicated 7B
deep checks added 12,288 fixed-seed fuzz executions, 32,768 funded-Router stateful calls and all seven
Stage 6D3 Solidity differential tests. Machine totals are in `security-results/stage7b-execution.json`.

## Operational note

During local analyzer bootstrap, the first direct Slither invocation used its Foundry adapter default,
which internally ran `forge clean` before rebuilding artifacts. No source, frozen artifact or user file was
removed; subsequent and committed `run-slither.sh` explicitly uses `--skip-clean`, and final build/gates
reconstruct all generated output. This is recorded because repository instructions prohibit clean commands.
