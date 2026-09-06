#!/usr/bin/env node

import { createHash } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

const HEX32 = /^0x[0-9a-f]{64}$/;
const ADDRESS = /^0x[0-9a-f]{40}$/;
const COMMIT = /^[0-9a-f]{40}$/;
const SEED = /^0x[0-9a-f]{1,64}$/;

export const MULTISEED = Object.freeze({
  schemaVersion: "swaputer-multiseed-security/1",
  seeds: Object.freeze([
    "0x7b2026",
    "0x98955c53cc5e0520c37e8dca375bfe7fb029aab60034d35a92c2224bc8c45e69",
    "0xdd1939302dff644f8ea811456724a65f06b6a7d31b1cfb1c7f0635772d33c7ad"
  ]),
  fuzzRuns: 4_096,
  fuzzProperties: 11,
  fuzzContractPattern: "^SwapVM(Stage1|Stage2|Stage4|Stage5|Stage7BSecurity)Test$",
  fuzzTestPattern: "^testFuzz_",
  invariantRuns: 256,
  invariantDepth: 64,
  invariants: 22,
  callsPerInvariant: 16_384,
  invariantContractPattern: "^SwapVM(Stage1|Stage2|Stage4|Stage5|Stage7BRouter|Stage7BFactory|SETHVault|SRC20Market|Authorization|Resource)InvariantTest$",
  invariantContracts: Object.freeze([
    Object.freeze({ name: "SwapVMStage1InvariantTest", properties: 2 }),
    Object.freeze({ name: "SwapVMStage2InvariantTest", properties: 2 }),
    Object.freeze({ name: "SwapVMStage4InvariantTest", properties: 2 }),
    Object.freeze({ name: "SwapVMStage5InvariantTest", properties: 2 }),
    Object.freeze({ name: "SwapVMStage7BRouterInvariantTest", properties: 2 }),
    Object.freeze({ name: "SwapVMStage7BFactoryInvariantTest", properties: 2 }),
    Object.freeze({ name: "SwapVMSETHVaultInvariantTest", properties: 3 }),
    Object.freeze({ name: "SwapVMSRC20MarketInvariantTest", properties: 3 }),
    Object.freeze({ name: "SwapVMAuthorizationInvariantTest", properties: 2 }),
    Object.freeze({ name: "SwapVMResourceInvariantTest", properties: 2 })
  ]),
  invariantTestPattern: "^invariant_"
});

export const BASE_MAINNET = Object.freeze({
  schemaVersion: "swaputer-base-mainnet-fork-rehearsal/1",
  chainId: 8_453,
  testPath: "test/fork/SwapVMBaseMainnetFork.t.sol",
  testCount: 3,
  poolManager: Object.freeze({
    address: "0x498581ff718922c3f8e6a244956af099b2652b2b",
    codeHash: "0x83b2af6e9f3158defc2811cbcb0db71ecf8b2ba2abea39c39e370ac5c6f43eb6"
  }),
  positionManager: Object.freeze({
    address: "0x7c5f5a4bbd8fd63184577525326123b519429bdc",
    codeHash: "0x243f9e091ddf11c7c04e28059fdbbf1bab82b72d414fafb8e096c097aaeb622a"
  }),
  permit2: Object.freeze({
    address: "0x000000000022d473030f116ddee9f6b43ac78ba3",
    codeHash: "0xa67739abc3ede9dbdc0491636c67d6a14ac07fab9030c3f509b1eb7b11dff8ed"
  }),
  universalRouter: Object.freeze({
    address: "0xfdf682f51fe81aa4898f0ae2163d8a55c127fbc7",
    codeHash: "0x4436f45787722467059726381c27a999d0725a7a8b6ae2c4217223987275e3ef",
    version: "2.1.1"
  }),
  adversarialCases: Object.freeze([
    "mutated-envelope",
    "replay",
    "wrong-router-binding",
    "out-of-byte-gas"
  ])
});

function fail(message) {
  throw new Error(message);
}

function object(value, path) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) fail(`${path} must be an object`);
  return value;
}

function exactKeys(value, expected, path) {
  const actual = Object.keys(object(value, path)).sort();
  const wanted = [...expected].sort();
  if (actual.length !== wanted.length || actual.some((key, index) => key !== wanted[index])) {
    fail(`${path} has unexpected or missing fields`);
  }
}

function equal(value, expected, path) {
  if (value !== expected) fail(`${path} must equal ${JSON.stringify(expected)}`);
}

function integer(value, minimum, path) {
  if (!Number.isSafeInteger(value) || value < minimum) fail(`${path} must be an integer >= ${minimum}`);
}

function matches(value, expression, path) {
  if (typeof value !== "string" || !expression.test(value)) fail(`${path} has an invalid format`);
}

function timestamp(value, path) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(value) || Number.isNaN(Date.parse(value))) {
    fail(`${path} must be a UTC timestamp`);
  }
}

function arrayEqual(actual, expected, path) {
  if (!Array.isArray(actual) || actual.length !== expected.length || actual.some((value, index) => value !== expected[index])) {
    fail(`${path} does not match the required ordered values`);
  }
}

function canonicalJson(value) {
  if (value === null || typeof value === "string" || typeof value === "boolean") return JSON.stringify(value);
  if (typeof value === "number") {
    if (!Number.isFinite(value)) fail("evidence contains a non-finite number");
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (typeof value !== "object") fail("evidence contains an unsupported value");
  return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(",")}}`;
}

export function evidenceHash(value) {
  const { integrity: _integrity, ...payload } = object(value, "evidence");
  return `0x${createHash("sha256").update(canonicalJson(payload)).digest("hex")}`;
}

function validateCommon(value, schemaVersion, passingStatus) {
  equal(value.schemaVersion, schemaVersion, "$.schemaVersion");
  equal(value.status, passingStatus, "$.status");
  timestamp(value.generatedAt, "$.generatedAt");
  exactKeys(value.source, ["commit", "treeState"], "$.source");
  matches(value.source.commit, COMMIT, "$.source.commit");
  equal(value.source.treeState, "clean", "$.source.treeState");
  exactKeys(value.toolchain, ["forgeCommit", "forgeVersion"], "$.toolchain");
  matches(value.toolchain.forgeCommit, COMMIT, "$.toolchain.forgeCommit");
  if (typeof value.toolchain.forgeVersion !== "string" || value.toolchain.forgeVersion.length === 0) {
    fail("$.toolchain.forgeVersion must be non-empty");
  }
}

function validateIntegrity(value) {
  exactKeys(value.integrity, ["algorithm", "reportHash"], "$.integrity");
  equal(value.integrity.algorithm, "sha256", "$.integrity.algorithm");
  matches(value.integrity.reportHash, HEX32, "$.integrity.reportHash");
  equal(value.integrity.reportHash, evidenceHash(value), "$.integrity.reportHash");
}

export function validateMultiSeedEvidence(value) {
  const evidence = object(value, "$");
  exactKeys(evidence, ["campaign", "generatedAt", "integrity", "results", "schemaVersion", "source", "status", "toolchain", "totals"], "$");
  validateCommon(evidence, MULTISEED.schemaVersion, "passed");

  exactKeys(evidence.campaign, ["fuzz", "invariants", "profile", "releaseSeed", "seedCount", "seeds", "supplementalSeedDerivation"], "$.campaign");
  equal(evidence.campaign.profile, "security", "$.campaign.profile");
  equal(evidence.campaign.releaseSeed, MULTISEED.seeds[0], "$.campaign.releaseSeed");
  equal(evidence.campaign.seedCount, MULTISEED.seeds.length, "$.campaign.seedCount");
  equal(evidence.campaign.supplementalSeedDerivation, "keccak256(swaputer-v1.2-internal-assurance/seed/{0,1})", "$.campaign.supplementalSeedDerivation");
  arrayEqual(evidence.campaign.seeds, MULTISEED.seeds, "$.campaign.seeds");
  if (new Set(evidence.campaign.seeds).size !== MULTISEED.seeds.length || evidence.campaign.seeds.some((seed) => !SEED.test(seed))) {
    fail("$.campaign.seeds must contain unique canonical hex seeds");
  }

  exactKeys(evidence.campaign.fuzz, ["contractPattern", "propertyCount", "runsPerProperty", "testPattern"], "$.campaign.fuzz");
  equal(evidence.campaign.fuzz.contractPattern, MULTISEED.fuzzContractPattern, "$.campaign.fuzz.contractPattern");
  equal(evidence.campaign.fuzz.testPattern, MULTISEED.fuzzTestPattern, "$.campaign.fuzz.testPattern");
  equal(evidence.campaign.fuzz.runsPerProperty, MULTISEED.fuzzRuns, "$.campaign.fuzz.runsPerProperty");
  equal(evidence.campaign.fuzz.propertyCount, MULTISEED.fuzzProperties, "$.campaign.fuzz.propertyCount");

  exactKeys(evidence.campaign.invariants, ["callsPerInvariant", "contractPattern", "contracts", "depth", "failOnRevert", "invariantCount", "runsPerInvariant", "seedPolicy", "testPattern"], "$.campaign.invariants");
  equal(evidence.campaign.invariants.contractPattern, MULTISEED.invariantContractPattern, "$.campaign.invariants.contractPattern");
  equal(evidence.campaign.invariants.testPattern, MULTISEED.invariantTestPattern, "$.campaign.invariants.testPattern");
  equal(evidence.campaign.invariants.runsPerInvariant, MULTISEED.invariantRuns, "$.campaign.invariants.runsPerInvariant");
  equal(evidence.campaign.invariants.depth, MULTISEED.invariantDepth, "$.campaign.invariants.depth");
  equal(evidence.campaign.invariants.invariantCount, MULTISEED.invariants, "$.campaign.invariants.invariantCount");
  equal(evidence.campaign.invariants.callsPerInvariant, MULTISEED.callsPerInvariant, "$.campaign.invariants.callsPerInvariant");
  equal(evidence.campaign.invariants.failOnRevert, true, "$.campaign.invariants.failOnRevert");
  equal(evidence.campaign.invariants.seedPolicy, "all-required-seeds", "$.campaign.invariants.seedPolicy");
  if (!Array.isArray(evidence.campaign.invariants.contracts) || evidence.campaign.invariants.contracts.length !== MULTISEED.invariantContracts.length) {
    fail("$.campaign.invariants.contracts must enumerate every required invariant contract");
  }
  evidence.campaign.invariants.contracts.forEach((contract, index) => {
    const path = `$.campaign.invariants.contracts[${index}]`;
    exactKeys(contract, ["name", "properties"], path);
    equal(contract.name, MULTISEED.invariantContracts[index].name, `${path}.name`);
    equal(contract.properties, MULTISEED.invariantContracts[index].properties, `${path}.properties`);
  });

  if (!Array.isArray(evidence.results) || evidence.results.length !== MULTISEED.seeds.length) fail("$.results must contain one result per required seed");
  evidence.results.forEach((result, index) => {
    const path = `$.results[${index}]`;
    exactKeys(result, ["fuzz", "invariants", "seed", "status"], path);
    equal(result.seed, MULTISEED.seeds[index], `${path}.seed`);
    equal(result.status, "passed", `${path}.status`);
    exactKeys(result.fuzz, ["durationSeconds", "outputSha256", "passed", "runsPerProperty"], `${path}.fuzz`);
    equal(result.fuzz.passed, MULTISEED.fuzzProperties, `${path}.fuzz.passed`);
    equal(result.fuzz.runsPerProperty, MULTISEED.fuzzRuns, `${path}.fuzz.runsPerProperty`);
    integer(result.fuzz.durationSeconds, 0, `${path}.fuzz.durationSeconds`);
    matches(result.fuzz.outputSha256, HEX32, `${path}.fuzz.outputSha256`);
    exactKeys(result.invariants, ["callsPerInvariant", "depth", "durationSeconds", "outputSha256", "passed", "runsPerInvariant", "unexpectedReverts"], `${path}.invariants`);
    equal(result.invariants.passed, MULTISEED.invariants, `${path}.invariants.passed`);
    equal(result.invariants.runsPerInvariant, MULTISEED.invariantRuns, `${path}.invariants.runsPerInvariant`);
    equal(result.invariants.depth, MULTISEED.invariantDepth, `${path}.invariants.depth`);
    equal(result.invariants.callsPerInvariant, MULTISEED.callsPerInvariant, `${path}.invariants.callsPerInvariant`);
    equal(result.invariants.unexpectedReverts, 0, `${path}.invariants.unexpectedReverts`);
    integer(result.invariants.durationSeconds, 0, `${path}.invariants.durationSeconds`);
    matches(result.invariants.outputSha256, HEX32, `${path}.invariants.outputSha256`);
  });

  exactKeys(evidence.totals, ["failures", "fuzzExecutions", "invariantActionCalls"], "$.totals");
  equal(evidence.totals.fuzzExecutions, MULTISEED.seeds.length * MULTISEED.fuzzProperties * MULTISEED.fuzzRuns, "$.totals.fuzzExecutions");
  equal(evidence.totals.invariantActionCalls, MULTISEED.seeds.length * MULTISEED.invariants * MULTISEED.callsPerInvariant, "$.totals.invariantActionCalls");
  equal(evidence.totals.failures, 0, "$.totals.failures");
  validateIntegrity(evidence);
  return evidence;
}

function validateCodeIdentity(value, expected, path, includeVersion = false) {
  exactKeys(value, includeVersion ? ["address", "codeHash", "version"] : ["address", "codeHash"], path);
  matches(value.address, ADDRESS, `${path}.address`);
  matches(value.codeHash, HEX32, `${path}.codeHash`);
  equal(value.address, expected.address, `${path}.address`);
  equal(value.codeHash, expected.codeHash, `${path}.codeHash`);
  if (includeVersion) equal(value.version, expected.version, `${path}.version`);
}

export function validateBaseMainnetForkEvidence(value) {
  const evidence = object(value, "$");
  exactKeys(evidence, ["fork", "generatedAt", "integrity", "rehearsal", "schemaVersion", "source", "status", "toolchain", "upstream"], "$");
  validateCommon(evidence, BASE_MAINNET.schemaVersion, "verified");

  exactKeys(evidence.fork, ["blockHash", "blockNumber", "blockTag", "chainId", "deterministicTestKeyUsed", "externalPrivateKeyLoaded", "network", "providerSource", "rpcCredentialsPersisted", "upstreamTransactionsBroadcast", "walletTxtUsed"], "$.fork");
  equal(evidence.fork.network, "Base Mainnet", "$.fork.network");
  equal(evidence.fork.chainId, BASE_MAINNET.chainId, "$.fork.chainId");
  equal(evidence.fork.blockTag, "finalized", "$.fork.blockTag");
  integer(evidence.fork.blockNumber, 1, "$.fork.blockNumber");
  matches(evidence.fork.blockHash, HEX32, "$.fork.blockHash");
  if (!["environment", "official-public-fallback"].includes(evidence.fork.providerSource)) fail("$.fork.providerSource is not permitted");
  equal(evidence.fork.rpcCredentialsPersisted, false, "$.fork.rpcCredentialsPersisted");
  equal(evidence.fork.upstreamTransactionsBroadcast, false, "$.fork.upstreamTransactionsBroadcast");
  equal(evidence.fork.externalPrivateKeyLoaded, false, "$.fork.externalPrivateKeyLoaded");
  equal(evidence.fork.walletTxtUsed, false, "$.fork.walletTxtUsed");
  equal(evidence.fork.deterministicTestKeyUsed, true, "$.fork.deterministicTestKeyUsed");

  exactKeys(evidence.upstream, ["bindings", "permit2", "poolManager", "positionManager", "universalRouter"], "$.upstream");
  validateCodeIdentity(evidence.upstream.poolManager, BASE_MAINNET.poolManager, "$.upstream.poolManager");
  validateCodeIdentity(evidence.upstream.positionManager, BASE_MAINNET.positionManager, "$.upstream.positionManager");
  validateCodeIdentity(evidence.upstream.permit2, BASE_MAINNET.permit2, "$.upstream.permit2");
  validateCodeIdentity(evidence.upstream.universalRouter, BASE_MAINNET.universalRouter, "$.upstream.universalRouter", true);
  exactKeys(evidence.upstream.bindings, ["positionManagerPermit2", "positionManagerPoolManager", "universalRouterPoolManager", "universalRouterPositionManager"], "$.upstream.bindings");
  for (const [name, passed] of Object.entries(evidence.upstream.bindings)) equal(passed, true, `$.upstream.bindings.${name}`);

  exactKeys(evidence.rehearsal, ["adversarialCases", "callExecuted", "deployExecuted", "deterministicTestSigningOnly", "directOfficialUniversalRouter", "durationSeconds", "economicsVerified", "freshCore", "liquidityProvider", "mainnetReleaseConfigCreated", "noBroadcast", "officialPositionManagerBindingsVerified", "officialPositionManagerLiquidityUsed", "stateVerified", "testCount", "testOutputSha256", "testPath", "v4Actions", "v4Command"], "$.rehearsal");
  equal(evidence.rehearsal.testPath, BASE_MAINNET.testPath, "$.rehearsal.testPath");
  equal(evidence.rehearsal.testCount, BASE_MAINNET.testCount, "$.rehearsal.testCount");
  matches(evidence.rehearsal.testOutputSha256, HEX32, "$.rehearsal.testOutputSha256");
  integer(evidence.rehearsal.durationSeconds, 0, "$.rehearsal.durationSeconds");
  equal(evidence.rehearsal.freshCore, true, "$.rehearsal.freshCore");
  equal(evidence.rehearsal.liquidityProvider, "fork-local-test-router", "$.rehearsal.liquidityProvider");
  equal(evidence.rehearsal.officialPositionManagerLiquidityUsed, false, "$.rehearsal.officialPositionManagerLiquidityUsed");
  equal(evidence.rehearsal.officialPositionManagerBindingsVerified, true, "$.rehearsal.officialPositionManagerBindingsVerified");
  equal(evidence.rehearsal.directOfficialUniversalRouter, true, "$.rehearsal.directOfficialUniversalRouter");
  equal(evidence.rehearsal.v4Command, "0x10", "$.rehearsal.v4Command");
  equal(evidence.rehearsal.v4Actions, "0x060c0f", "$.rehearsal.v4Actions");
  for (const name of ["deployExecuted", "callExecuted", "stateVerified", "economicsVerified", "noBroadcast", "deterministicTestSigningOnly"]) {
    equal(evidence.rehearsal[name], true, `$.rehearsal.${name}`);
  }
  equal(evidence.rehearsal.mainnetReleaseConfigCreated, false, "$.rehearsal.mainnetReleaseConfigCreated");
  arrayEqual(evidence.rehearsal.adversarialCases, BASE_MAINNET.adversarialCases, "$.rehearsal.adversarialCases");
  validateIntegrity(evidence);
  return evidence;
}

export function sealEvidence(kind, value) {
  const draft = structuredClone(object(value, "$"));
  delete draft.integrity;
  draft.integrity = { algorithm: "sha256", reportHash: evidenceHash(draft) };
  if (kind === "multiseed") return validateMultiSeedEvidence(draft);
  if (kind === "fork") return validateBaseMainnetForkEvidence(draft);
  fail(`unknown evidence kind ${kind}`);
}

async function cli() {
  const [operation, inputPath, outputPath] = process.argv.slice(2);
  if (!operation || !inputPath) fail("usage: stage7m-assurance-evidence.mjs <seal-multiseed|seal-fork|validate-multiseed|validate-fork> <input> [output]");
  const input = JSON.parse(await readFile(inputPath, "utf8"));
  if (operation === "seal-multiseed" || operation === "seal-fork") {
    if (!outputPath) fail("seal operations require an output path");
    const kind = operation === "seal-multiseed" ? "multiseed" : "fork";
    const sealed = sealEvidence(kind, input);
    await writeFile(outputPath, `${JSON.stringify(sealed, null, 2)}\n`, { mode: 0o600 });
    process.stdout.write(`${JSON.stringify({ status: sealed.status, schemaVersion: sealed.schemaVersion, reportHash: sealed.integrity.reportHash })}\n`);
    return;
  }
  const validated = operation === "validate-multiseed"
    ? validateMultiSeedEvidence(input)
    : operation === "validate-fork"
      ? validateBaseMainnetForkEvidence(input)
      : fail(`unknown operation ${operation}`);
  process.stdout.write(`${JSON.stringify({ status: validated.status, schemaVersion: validated.schemaVersion, reportHash: validated.integrity.reportHash })}\n`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  cli().catch((error) => {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  });
}
