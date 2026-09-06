#!/usr/bin/env node

import { createHash } from "node:crypto";
import { execFileSync, spawnSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { canonicalJson, parseStrictJson } from "../tooling/deployment-manifest/dist/src/canonical.js";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const SCHEMA = "swaputer-stage7m-s7b002/1";
const COMMAND = "forge test --match-path test/Stage7MSaltRecovery.t.sol --json";
const EXPECTED_CASES = Object.freeze([
  "test_bootstrapSaltCollisionRollsBackAndRecoversWithRecomputedAddresses()",
  "test_exactCopyFrontRunCannotRedirectSupplyOrMutateConfig()",
  "test_tokenSaltCollisionRollsBackAndRecoversWithRecomputedAddresses()"
]);
const SOURCE_FILES = Object.freeze([
  "src/SwapVMWorldFactory.sol",
  "test/Stage7MSaltRecovery.t.sol",
  "script/accept-s7b002.sh",
  "script/s7b002-evidence.mjs",
  "script/s7b002-evidence.test.mjs",
  "docs/security/STAGE7B-FINDINGS.md",
  "docs/security/DEPLOYMENT-FAILURE-RUNBOOK.md"
]);

function fail(message) {
  throw new Error(message);
}

function sha256(value) {
  return `0x${createHash("sha256").update(value).digest("hex")}`;
}

function object(value, location) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) fail(`${location} must be an object`);
  return value;
}

function exact(value, keys, location) {
  const actual = Object.keys(object(value, location)).sort();
  const expected = [...keys].sort();
  if (actual.length !== expected.length || actual.some((key, index) => key !== expected[index])) {
    fail(`${location} has unexpected or missing fields`);
  }
}

function equal(actual, expected, location) {
  if (actual !== expected) fail(`${location} must equal ${JSON.stringify(expected)}`);
}

function boolean(value, location) {
  if (typeof value !== "boolean") fail(`${location} must be boolean`);
}

function positiveInteger(value, location) {
  if (!Number.isSafeInteger(value) || value < 0) fail(`${location} must be a non-negative safe integer`);
}

function hash(value, location) {
  if (typeof value !== "string" || !/^0x[0-9a-f]{64}$/.test(value)) fail(`${location} must be a SHA-256 hash`);
}

export function computeEvidenceHash(report) {
  const { integrity: _integrity, ...payload } = report;
  return sha256(canonicalJson(payload));
}

export function sealEvidence(payload) {
  const report = structuredClone(payload);
  report.integrity = { algorithm: "sha256", reportHash: computeEvidenceHash(report) };
  return report;
}

export function validateEvidence(report, { requireFormal = false } = {}) {
  exact(report, [
    "schemaVersion", "generatedAt", "status", "finding", "strategy", "source", "execution", "proofs",
    "limitations", "riskAcceptance", "integrity"
  ], "$");
  equal(report.schemaVersion, SCHEMA, "$.schemaVersion");
  equal(report.status, "passed", "$.status");
  if (typeof report.generatedAt !== "string" || Number.isNaN(Date.parse(report.generatedAt))) {
    fail("$.generatedAt must be an ISO timestamp");
  }

  exact(report.finding, ["id", "severity", "class", "disposition"], "$.finding");
  equal(report.finding.id, "S7B-002", "$.finding.id");
  equal(report.finding.severity, "Medium", "$.finding.severity");
  equal(report.finding.class, "availability", "$.finding.class");
  equal(report.finding.disposition, "accepted-open", "$.finding.disposition");
  equal(report.strategy, "salt-recovery", "$.strategy");

  exact(report.source, ["commit", "treeState", "formalCandidateEligible", "files"], "$.source");
  if (typeof report.source.commit !== "string" || !/^[0-9a-f]{40}$/.test(report.source.commit)) {
    fail("$.source.commit must be a full Git commit");
  }
  if (!["clean", "dirty"].includes(report.source.treeState)) fail("$.source.treeState is invalid");
  boolean(report.source.formalCandidateEligible, "$.source.formalCandidateEligible");
  equal(report.source.formalCandidateEligible, report.source.treeState === "clean", "$.source.formalCandidateEligible");
  if (!Array.isArray(report.source.files) || report.source.files.length !== SOURCE_FILES.length) {
    fail("$.source.files must contain the exact evidence scope");
  }
  report.source.files.forEach((entry, index) => {
    exact(entry, ["path", "sha256"], `$.source.files[${index}]`);
    equal(entry.path, SOURCE_FILES[index], `$.source.files[${index}].path`);
    hash(entry.sha256, `$.source.files[${index}].sha256`);
  });

  exact(report.execution, [
    "command", "runner", "chainId", "isolation", "broadcastTransactions", "transactionReceipts",
    "externalRpcUsed", "durationMs", "outputSha256", "tests"
  ], "$.execution");
  equal(report.execution.command, COMMAND, "$.execution.command");
  equal(report.execution.runner, "forge-test", "$.execution.runner");
  equal(report.execution.chainId, 31337, "$.execution.chainId");
  equal(report.execution.isolation, "in-process-foundry-evm", "$.execution.isolation");
  equal(report.execution.broadcastTransactions, false, "$.execution.broadcastTransactions");
  equal(report.execution.transactionReceipts, false, "$.execution.transactionReceipts");
  equal(report.execution.externalRpcUsed, false, "$.execution.externalRpcUsed");
  positiveInteger(report.execution.durationMs, "$.execution.durationMs");
  if (report.execution.durationMs > 900_000) {
    fail("$.execution.durationMs exceeds the 900-second simulation gate");
  }
  hash(report.execution.outputSha256, "$.execution.outputSha256");
  exact(report.execution.tests, ["total", "passed", "failed", "skipped", "cases"], "$.execution.tests");
  equal(report.execution.tests.total, 3, "$.execution.tests.total");
  equal(report.execution.tests.passed, 3, "$.execution.tests.passed");
  equal(report.execution.tests.failed, 0, "$.execution.tests.failed");
  equal(report.execution.tests.skipped, 0, "$.execution.tests.skipped");
  if (!Array.isArray(report.execution.tests.cases) || canonicalJson(report.execution.tests.cases) !== canonicalJson(EXPECTED_CASES)) {
    fail("$.execution.tests.cases must contain the exact three recovery cases");
  }

  exact(report.proofs, ["exactCopy", "bootstrapCollision", "tokenCollision", "common"], "$.proofs");
  exact(report.proofs.exactCopy, [
    "distinctCallers", "byteIdenticalParams", "copiedCallCreatesSealedWorld", "publisherRetryRevert",
    "declaredHolderReceivesFullSupply", "grieferReceivesSupply", "existingWorldUnchanged"
  ], "$.proofs.exactCopy");
  for (const key of ["distinctCallers", "byteIdenticalParams", "copiedCallCreatesSealedWorld", "declaredHolderReceivesFullSupply", "existingWorldUnchanged"]) {
    equal(report.proofs.exactCopy[key], true, `$.proofs.exactCopy.${key}`);
  }
  equal(report.proofs.exactCopy.publisherRetryRevert, "empty-create2-collision", "$.proofs.exactCopy.publisherRetryRevert");
  equal(report.proofs.exactCopy.grieferReceivesSupply, false, "$.proofs.exactCopy.grieferReceivesSupply");

  exact(report.proofs.bootstrapCollision, [
    "errorSelector", "failedCandidateAtomic", "collidingWorldComplete", "reusedTokenSalt", "changedBootstrapSalt",
    "deployerKernelHookWorldRecomputed", "recoveredWorldSealed", "oldDraftHashReused"
  ], "$.proofs.bootstrapCollision");
  equal(report.proofs.bootstrapCollision.errorSelector, "0x69a0b302", "$.proofs.bootstrapCollision.errorSelector");
  for (const key of ["failedCandidateAtomic", "collidingWorldComplete", "reusedTokenSalt", "changedBootstrapSalt", "deployerKernelHookWorldRecomputed", "recoveredWorldSealed"]) {
    equal(report.proofs.bootstrapCollision[key], true, `$.proofs.bootstrapCollision.${key}`);
  }
  equal(report.proofs.bootstrapCollision.oldDraftHashReused, false, "$.proofs.bootstrapCollision.oldDraftHashReused");

  exact(report.proofs.tokenCollision, [
    "publisherRetryRevert", "failedCandidateAtomic", "collidingWorldComplete", "changedTokenSalt",
    "reusedBootstrapSalt", "tokenHookWorldRecomputed", "declaredHolderReceivesFullSupply", "grieferReceivesSupply",
    "recoveredWorldSealed", "oldDraftHashReused"
  ], "$.proofs.tokenCollision");
  equal(report.proofs.tokenCollision.publisherRetryRevert, "empty-create2-collision", "$.proofs.tokenCollision.publisherRetryRevert");
  for (const key of ["failedCandidateAtomic", "collidingWorldComplete", "changedTokenSalt", "reusedBootstrapSalt", "tokenHookWorldRecomputed", "declaredHolderReceivesFullSupply", "recoveredWorldSealed"]) {
    equal(report.proofs.tokenCollision[key], true, `$.proofs.tokenCollision.${key}`);
  }
  equal(report.proofs.tokenCollision.grieferReceivesSupply, false, "$.proofs.tokenCollision.grieferReceivesSupply");
  equal(report.proofs.tokenCollision.oldDraftHashReused, false, "$.proofs.tokenCollision.oldDraftHashReused");

  exact(report.proofs.common, [
    "worldConfigHashRecomputed", "addressPredictionsRecomputed", "hookPermissionBitsVerified",
    "runtimeCodeHashesVerified", "bidirectionalBindingsVerified", "poolInitializationVerified",
    "worldSealedEventRecorded"
  ], "$.proofs.common");
  for (const [key, value] of Object.entries(report.proofs.common)) equal(value, true, `$.proofs.common.${key}`);

  exact(report.limitations, [
    "topLevelTransactionReceiptsObserved", "mempoolOrderingObserved", "operatorRecoveryTargetSeconds",
    "operatorRecoveryTargetMeasured", "description"
  ], "$.limitations");
  equal(report.limitations.topLevelTransactionReceiptsObserved, false, "$.limitations.topLevelTransactionReceiptsObserved");
  equal(report.limitations.mempoolOrderingObserved, false, "$.limitations.mempoolOrderingObserved");
  equal(report.limitations.operatorRecoveryTargetSeconds, 900, "$.limitations.operatorRecoveryTargetSeconds");
  equal(report.limitations.operatorRecoveryTargetMeasured, false, "$.limitations.operatorRecoveryTargetMeasured");
  if (typeof report.limitations.description !== "string" || report.limitations.description.length < 80) {
    fail("$.limitations.description must explain the simulation boundary");
  }

  exact(report.riskAcceptance, [
    "projectAccepted", "acceptedStrategy", "ownerAllowlistAdded", "protectedSubmissionRequired",
    "externalAuditClaimed", "residualRisk", "findingClosed", "mainnetAuthorized"
  ], "$.riskAcceptance");
  equal(report.riskAcceptance.projectAccepted, true, "$.riskAcceptance.projectAccepted");
  equal(report.riskAcceptance.acceptedStrategy, "salt-recovery", "$.riskAcceptance.acceptedStrategy");
  equal(report.riskAcceptance.ownerAllowlistAdded, false, "$.riskAcceptance.ownerAllowlistAdded");
  equal(report.riskAcceptance.protectedSubmissionRequired, false, "$.riskAcceptance.protectedSubmissionRequired");
  equal(report.riskAcceptance.externalAuditClaimed, false, "$.riskAcceptance.externalAuditClaimed");
  equal(report.riskAcceptance.findingClosed, false, "$.riskAcceptance.findingClosed");
  equal(report.riskAcceptance.mainnetAuthorized, false, "$.riskAcceptance.mainnetAuthorized");
  if (!Array.isArray(report.riskAcceptance.residualRisk) || report.riskAcceptance.residualRisk.length !== 4
      || report.riskAcceptance.residualRisk.some((entry) => typeof entry !== "string" || entry.length < 12)) {
    fail("$.riskAcceptance.residualRisk must preserve all four accepted consequences");
  }

  exact(report.integrity, ["algorithm", "reportHash"], "$.integrity");
  equal(report.integrity.algorithm, "sha256", "$.integrity.algorithm");
  hash(report.integrity.reportHash, "$.integrity.reportHash");
  equal(report.integrity.reportHash, computeEvidenceHash(report), "$.integrity.reportHash");
  if (requireFormal && !report.source.formalCandidateEligible) fail("formal verification requires clean-tree evidence");
  return report;
}

export function parseEvidenceText(text, options) {
  return validateEvidence(parseStrictJson(text), options);
}

function sourceState() {
  const commit = execFileSync("git", ["rev-parse", "HEAD"], { cwd: ROOT, encoding: "utf8" }).trim();
  const porcelain = execFileSync("git", ["status", "--porcelain", "--untracked-files=normal"], {
    cwd: ROOT,
    encoding: "utf8"
  }).trim();
  return {
    commit,
    treeState: porcelain === "" ? "clean" : "dirty",
    formalCandidateEligible: porcelain === "",
    files: SOURCE_FILES.map((file) => ({ path: file, sha256: sha256(readFileSync(path.join(ROOT, file))) }))
  };
}

function parseForgeResult(stdout) {
  const result = JSON.parse(stdout);
  const cases = [];
  let passed = 0;
  let failed = 0;
  let skipped = 0;
  for (const suite of Object.values(result)) {
    for (const [name, test] of Object.entries(suite.test_results ?? {})) {
      cases.push(name);
      if (test.status === "Success") passed += 1;
      else if (test.status === "Skipped") skipped += 1;
      else failed += 1;
    }
  }
  cases.sort();
  if (canonicalJson(cases) !== canonicalJson(EXPECTED_CASES) || passed !== 3 || failed !== 0 || skipped !== 0) {
    fail("Foundry output does not prove the exact three S7B-002 cases");
  }
  return { total: cases.length, passed, failed, skipped, cases };
}

function run(output, allowDirty) {
  const source = sourceState();
  if (source.treeState !== "clean" && !allowDirty) fail("formal S7B-002 evidence requires a clean Git worktree");
  const started = Date.now();
  const result = spawnSync("forge", ["test", "--match-path", "test/Stage7MSaltRecovery.t.sol", "--json"], {
    cwd: ROOT,
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024
  });
  if (result.status !== 0) {
    process.stderr.write(result.stderr ?? "");
    fail(`Foundry S7B-002 test failed with exit code ${result.status ?? "unknown"}`);
  }
  const tests = parseForgeResult(result.stdout);
  const report = sealEvidence({
    schemaVersion: SCHEMA,
    generatedAt: new Date().toISOString(),
    status: "passed",
    finding: { id: "S7B-002", severity: "Medium", class: "availability", disposition: "accepted-open" },
    strategy: "salt-recovery",
    source,
    execution: {
      command: COMMAND,
      runner: "forge-test",
      chainId: 31337,
      isolation: "in-process-foundry-evm",
      broadcastTransactions: false,
      transactionReceipts: false,
      externalRpcUsed: false,
      durationMs: Date.now() - started,
      outputSha256: sha256(result.stdout),
      tests
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
      description: "This evidence records isolated in-process Foundry EVM calls and committed event/state assertions; it does not claim public-mempool ordering, broadcast transactions, transaction receipts, or a measured operator response time."
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
  });
  validateEvidence(report);
  writeFileSync(path.resolve(ROOT, output), `${JSON.stringify(report, null, 2)}\n`, { mode: 0o644 });
  process.stdout.write(`${canonicalJson({ status: "passed", evidence: output, reportHash: report.integrity.reportHash, formalCandidateEligible: report.source.formalCandidateEligible })}\n`);
}

function verify(file, current, formal) {
  const report = parseEvidenceText(readFileSync(path.resolve(ROOT, file), "utf8"), { requireFormal: formal });
  if (current) {
    const currentCommit = execFileSync("git", ["rev-parse", "HEAD"], { cwd: ROOT, encoding: "utf8" }).trim();
    equal(report.source.commit, currentCommit, "$.source.commit");
    for (const entry of report.source.files) {
      equal(entry.sha256, sha256(readFileSync(path.join(ROOT, entry.path))), `current ${entry.path}`);
    }
  }
  process.stdout.write(`${canonicalJson({ status: "verified", reportHash: report.integrity.reportHash, formalCandidateEligible: report.source.formalCandidateEligible })}\n`);
}

function option(arguments_, name) {
  const index = arguments_.indexOf(name);
  if (index === -1) return null;
  if (index + 1 >= arguments_.length) fail(`${name} requires a value`);
  return arguments_[index + 1];
}

function main() {
  const arguments_ = process.argv.slice(2);
  const command = arguments_[0];
  if (command === "run") {
    run(option(arguments_, "--output") ?? "security-results/stage7m-s7b002.json", arguments_.includes("--allow-dirty"));
    return;
  }
  if (command === "verify" && arguments_[1]) {
    verify(arguments_[1], arguments_.includes("--current"), arguments_.includes("--formal"));
    return;
  }
  fail("usage: s7b002-evidence.mjs run [--output FILE] [--allow-dirty] | verify FILE [--current] [--formal]");
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    main();
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 1;
  }
}
