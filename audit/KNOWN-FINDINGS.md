# Known findings at rc2

These findings are disclosed to the independent auditor and must not be hidden by severity summaries.

## S7B-001 — duplicate JSON member ambiguity

- Severity: Medium
- Status: fixed before rc1
- Resolution: strict dependency-free JSON parsing rejects duplicate decoded keys, malformed/trailing input and
  returns no partial manifest.
- Auditor action: validate parser/canonicalization and its Unicode/number boundary regressions.

## S7B-002 — public salt ordering/griefing

- Severity: Medium
- Status: open; availability/operational risk
- Impact: a copied or conflicting public `createWorld` can make the publisher retry with new salt/K/H and
  invalidate the old manifest draft. Tests show no redirection of declared initial supply, mutation of an
  existing seal or partial deployment after revert.
- Current treatment: no owner, allowlist, pause or governance control is introduced. A no-admin recovery
  runbook and private/protected submission option are expected operational mitigations.
- Auditor action: independently assess attack assumptions, rollback proof and whether this Medium can be
  accepted for a later release. It is not silently waived by this package.

## S7B-003 — nondeterministic gas snapshot seed

- Severity: Low
- Status: fixed before rc1
- Resolution: default and deep security fuzz use public fixed seed `0x7b2026`; consecutive snapshot/check passed.
- Auditor action: retain the release seed and supplement it with independent random seeds.

## S7C0-001 — inherited root file omitted from audit allowlist

- Severity: Informational (release-process integrity)
- Status: fixed in rc2; rc1 is retained but superseded and must not be sent as the audit snapshot
- Resolution: `.gitattributes`, inherited from the initial commit, is now an explicit root source file and
  is committed to `audit/source-files.sha256`. The tag verifier caught the omission after rc1 creation.
- Auditor action: begin from rc2 or higher and confirm the tag verifier passes before review.

Critical: 0 open. High: 0 open. Medium: S7B-002 remains open. Stage 7D is forbidden until external review
closes Critical/High and each Medium is fixed or expressly accepted in writing by auditor and project.
