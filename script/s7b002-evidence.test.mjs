import assert from "node:assert/strict";
import test from "node:test";

import { parseEvidenceText, sealEvidence, validateEvidence } from "./s7b002-evidence.mjs";

const hashes = [
  "src/SwapVMWorldFactory.sol",
  "test/Stage7MSaltRecovery.t.sol",
  "script/accept-s7b002.sh",
  "script/s7b002-evidence.mjs",
  "script/s7b002-evidence.test.mjs",
  "docs/security/STAGE7B-FINDINGS.md",
  "docs/security/DEPLOYMENT-FAILURE-RUNBOOK.md"
].map((path, index) => ({ path, sha256: `0x${String(index + 1).padStart(64, "0")}` }));

function validPayload() {
  return {
    schemaVersion: "swaputer-stage7m-s7b002/1",
    generatedAt: "2026-09-06T00:00:00.000Z",
    status: "passed",
    finding: { id: "S7B-002", severity: "Medium", class: "availability", disposition: "accepted-open" },
    strategy: "salt-recovery",
    source: {
      commit: "1".repeat(40),
      treeState: "clean",
      formalCandidateEligible: true,
      files: structuredClone(hashes)
    },
    execution: {
      command: "forge test --match-path test/Stage7MSaltRecovery.t.sol --json",
      runner: "forge-test",
      chainId: 31337,
      isolation: "in-process-foundry-evm",
      broadcastTransactions: false,
      transactionReceipts: false,
      externalRpcUsed: false,
      durationMs: 1000,
      outputSha256: `0x${"a".repeat(64)}`,
      tests: {
        total: 3,
        passed: 3,
        failed: 0,
        skipped: 0,
        cases: [
          "test_bootstrapSaltCollisionRollsBackAndRecoversWithRecomputedAddresses()",
          "test_exactCopyFrontRunCannotRedirectSupplyOrMutateConfig()",
          "test_tokenSaltCollisionRollsBackAndRecoversWithRecomputedAddresses()"
        ]
      }
    },
    proofs: {
      exactCopy: {
        distinctCallers: true,
        byteIdenticalParams: true,
        copiedCallCreatesSealedWorld: true,
        publisherRetryRevert: "empty-create2-collision",
        declaredHolderReceivesFullSupply: true,
        grieferReceivesSupply: false,
        existingWorldUnchanged: true
      },
      bootstrapCollision: {
        errorSelector: "0x69a0b302",
        failedCandidateAtomic: true,
        collidingWorldComplete: true,
        reusedTokenSalt: true,
        changedBootstrapSalt: true,
        deployerKernelHookWorldRecomputed: true,
        recoveredWorldSealed: true,
        oldDraftHashReused: false
      },
      tokenCollision: {
        publisherRetryRevert: "empty-create2-collision",
        failedCandidateAtomic: true,
        collidingWorldComplete: true,
        changedTokenSalt: true,
        reusedBootstrapSalt: true,
        tokenHookWorldRecomputed: true,
        declaredHolderReceivesFullSupply: true,
        grieferReceivesSupply: false,
        recoveredWorldSealed: true,
        oldDraftHashReused: false
      },
      common: {
        worldConfigHashRecomputed: true,
        addressPredictionsRecomputed: true,
        hookPermissionBitsVerified: true,
        runtimeCodeHashesVerified: true,
        bidirectionalBindingsVerified: true,
        poolInitializationVerified: true,
        worldSealedEventRecorded: true
      }
    },
    limitations: {
      topLevelTransactionReceiptsObserved: false,
      mempoolOrderingObserved: false,
      operatorRecoveryTargetSeconds: 900,
      operatorRecoveryTargetMeasured: false,
      description: "This is an isolated Foundry EVM simulation and deliberately makes no claim about public mempool ordering, broadcast transactions, receipts, or measured operator response time."
    },
    riskAcceptance: {
      projectAccepted: true,
      acceptedStrategy: "salt-recovery",
      ownerAllowlistAdded: false,
      protectedSubmissionRequired: false,
      externalAuditClaimed: false,
      residualRisk: [
        "publisher transaction gas can be lost",
        "official publication can be delayed",
        "the old release draft must be invalidated",
        "an unendorsed immutable World can remain deployed"
      ],
      findingClosed: false,
      mainnetAuthorized: false
    }
  };
}

function valid() {
  return sealEvidence(validPayload());
}

function reseal(report) {
  const copy = structuredClone(report);
  delete copy.integrity;
  return sealEvidence(copy);
}

test("strict S7B-002 validator accepts the exact isolated-simulation proof", () => {
  assert.equal(validateEvidence(valid(), { requireFormal: true }).status, "passed");
});

test("validator rejects weakened scenario, receipt and mainnet claims", () => {
  const selector = valid();
  selector.proofs.bootstrapCollision.errorSelector = "0x00000000";
  assert.throws(() => validateEvidence(reseal(selector)), /errorSelector/);

  const receipt = valid();
  receipt.execution.transactionReceipts = true;
  assert.throws(() => validateEvidence(reseal(receipt)), /transactionReceipts/);

  const mainnet = valid();
  mainnet.riskAcceptance.mainnetAuthorized = true;
  assert.throws(() => validateEvidence(reseal(mainnet)), /mainnetAuthorized/);
});

test("validator rejects incomplete tests, excessive duration, invalid output hashes and unknown fields", () => {
  const missing = valid();
  missing.execution.tests.cases.pop();
  missing.execution.tests.total = 2;
  missing.execution.tests.passed = 2;
  assert.throws(() => validateEvidence(reseal(missing)), /total|cases/);

  const slow = valid();
  slow.execution.durationMs = 900_001;
  assert.throws(() => validateEvidence(reseal(slow)), /durationMs/);

  const output = valid();
  output.execution.outputSha256 = "0x00";
  assert.throws(() => validateEvidence(reseal(output)), /outputSha256/);

  const unknown = valid();
  unknown.proofs.exactCopy.unverifiedClaim = true;
  assert.throws(() => validateEvidence(reseal(unknown)), /unexpected or missing fields/);
});

test("validator rejects dirty formal evidence, duplicate JSON members and tampering", () => {
  const dirty = valid();
  dirty.source.treeState = "dirty";
  dirty.source.formalCandidateEligible = false;
  const sealedDirty = reseal(dirty);
  assert.equal(validateEvidence(sealedDirty).source.formalCandidateEligible, false);
  assert.throws(() => validateEvidence(sealedDirty, { requireFormal: true }), /clean-tree/);

  const duplicate = JSON.stringify(valid()).replace('"status":"passed"', '"status":"passed","status":"failed"');
  assert.throws(() => parseEvidenceText(duplicate), /duplicate object member/);

  const tampered = valid();
  tampered.proofs.common.poolInitializationVerified = false;
  assert.throws(() => validateEvidence(tampered), /poolInitializationVerified|reportHash/);
});
