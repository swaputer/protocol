# Swaputer v1.1 Stage 7C audit candidate 2

This directory is the reproducible handoff for the second external-audit candidate. Swaputer couples a
buy-only MiniVM execution path to exact-input native ETH → TOKEN swaps in Uniswap v4. A successful VM buy
burns `executedBytes × byteGasPrice` from gross TOKEN output and emits exactly one Kernel `VMLog`; TOKEN →
ETH sells bypass the VM.

Stage 7B internal adversarial hardening is complete. This candidate remains an **unaudited release
candidate**. The project has deferred, not completed, Stage 7C. There is no independent auditor or report.
The internal tests, Slither triage, development-agent and AI checks are audit inputs, not an independent
audit, and this report is not authorization for public deployment or real-value use.

The immutable local tag is `swaputer-v1.1-stage7c-rc2`. Never move or replace it. Candidate rc1 is retained
but superseded because its post-tag fail-closed verifier found the inherited `.gitattributes` file was not
classified in the source allowlist. Any source, dependency, compiler, artifact, finding remediation or
test-evidence change requires a new commit, full `./script/accept-stage7b.sh`, auditor review and an `rc3`
or higher tag. Creation-code changes also require
recomputing Factory pins and deployment-manifest artifact commitments.

Start with [AUDITOR-BRIEF.md](AUDITOR-BRIEF.md), [SCOPE.md](SCOPE.md), [KNOWN-FINDINGS.md](KNOWN-FINDINGS.md)
and [REPRODUCE.md](REPRODUCE.md). Verify the snapshot before review:

```sh
./script/verify-audit-snapshot.sh swaputer-v1.1-stage7c-rc2
```

Stage 7D-U1 may use this identity only as a historical unaudited baseline for local or explicitly authorized
zero-value testnet rehearsal. Public mainnet and real funds remain prohibited until Stage 7C independent
review/remediation, a real security contact/bounty decision and chain-specific operational/economic gates.
