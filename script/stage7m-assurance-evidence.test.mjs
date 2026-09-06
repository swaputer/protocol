import assert from "node:assert/strict";
import test from "node:test";

import {
  BASE_MAINNET,
  MULTISEED,
  sealEvidence,
  validateBaseMainnetForkEvidence,
  validateMultiSeedEvidence
} from "./stage7m-assurance-evidence.mjs";

const hex32 = (byte) => `0x${byte.repeat(64)}`;

function multiSeedDraft() {
  return {
    schemaVersion: MULTISEED.schemaVersion,
    generatedAt: "2026-09-06T00:00:00Z",
    status: "passed",
    source: { commit: "a".repeat(40), treeState: "clean" },
    toolchain: { forgeVersion: "1.5.1-stable", forgeCommit: "b".repeat(40) },
    campaign: {
      profile: "security",
      releaseSeed: MULTISEED.seeds[0],
      supplementalSeedDerivation: "keccak256(swaputer-v1.2-internal-assurance/seed/{0,1})",
      seedCount: MULTISEED.seeds.length,
      seeds: [...MULTISEED.seeds],
      fuzz: {
        runsPerProperty: MULTISEED.fuzzRuns,
        propertyCount: MULTISEED.fuzzProperties,
        contractPattern: MULTISEED.fuzzContractPattern,
        testPattern: MULTISEED.fuzzTestPattern
      },
      invariants: {
        runsPerInvariant: MULTISEED.invariantRuns,
        depth: MULTISEED.invariantDepth,
        invariantCount: MULTISEED.invariants,
        callsPerInvariant: MULTISEED.callsPerInvariant,
        failOnRevert: true,
        seedPolicy: "all-required-seeds",
        contracts: MULTISEED.invariantContracts.map((contract) => ({ ...contract })),
        contractPattern: MULTISEED.invariantContractPattern,
        testPattern: MULTISEED.invariantTestPattern
      }
    },
    results: MULTISEED.seeds.map((seed) => ({
      seed,
      status: "passed",
      fuzz: { passed: MULTISEED.fuzzProperties, runsPerProperty: MULTISEED.fuzzRuns, durationSeconds: 1, outputSha256: hex32("1") },
      invariants: { passed: MULTISEED.invariants, runsPerInvariant: MULTISEED.invariantRuns, depth: MULTISEED.invariantDepth, callsPerInvariant: MULTISEED.callsPerInvariant, unexpectedReverts: 0, durationSeconds: 2, outputSha256: hex32("2") }
    })),
    totals: {
      fuzzExecutions: MULTISEED.seeds.length * MULTISEED.fuzzProperties * MULTISEED.fuzzRuns,
      invariantActionCalls: MULTISEED.seeds.length * MULTISEED.invariants * MULTISEED.callsPerInvariant,
      failures: 0
    }
  };
}

function forkDraft() {
  return {
    schemaVersion: BASE_MAINNET.schemaVersion,
    generatedAt: "2026-09-06T00:00:00Z",
    status: "verified",
    source: { commit: "a".repeat(40), treeState: "clean" },
    toolchain: { forgeVersion: "1.5.1-stable", forgeCommit: "b".repeat(40) },
    fork: {
      network: "Base Mainnet",
      chainId: BASE_MAINNET.chainId,
      blockTag: "finalized",
      blockNumber: 50_000_000,
      blockHash: hex32("3"),
      providerSource: "official-public-fallback",
      rpcCredentialsPersisted: false,
      upstreamTransactionsBroadcast: false,
      externalPrivateKeyLoaded: false,
      walletTxtUsed: false,
      deterministicTestKeyUsed: true
    },
    upstream: {
      poolManager: { ...BASE_MAINNET.poolManager },
      positionManager: { ...BASE_MAINNET.positionManager },
      permit2: { ...BASE_MAINNET.permit2 },
      universalRouter: { ...BASE_MAINNET.universalRouter },
      bindings: {
        universalRouterPoolManager: true,
        universalRouterPositionManager: true,
        positionManagerPoolManager: true,
        positionManagerPermit2: true
      }
    },
    rehearsal: {
      testPath: BASE_MAINNET.testPath,
      testCount: BASE_MAINNET.testCount,
      testOutputSha256: hex32("4"),
      durationSeconds: 3,
      freshCore: true,
      liquidityProvider: "fork-local-test-router",
      officialPositionManagerLiquidityUsed: false,
      officialPositionManagerBindingsVerified: true,
      directOfficialUniversalRouter: true,
      v4Command: "0x10",
      v4Actions: "0x060c0f",
      deployExecuted: true,
      callExecuted: true,
      stateVerified: true,
      economicsVerified: true,
      adversarialCases: [...BASE_MAINNET.adversarialCases],
      noBroadcast: true,
      deterministicTestSigningOnly: true,
      mainnetReleaseConfigCreated: false
    }
  };
}

test("accepts complete multi-seed evidence", () => {
  const evidence = sealEvidence("multiseed", multiSeedDraft());
  assert.equal(validateMultiSeedEvidence(evidence).status, "passed");
});

test("multi-seed evidence rejects missing, repeated, weakened and reverting campaigns", () => {
  const missing = multiSeedDraft();
  missing.results.pop();
  assert.throws(() => sealEvidence("multiseed", missing), /one result per required seed/);

  const repeated = multiSeedDraft();
  repeated.campaign.seeds[1] = repeated.campaign.seeds[0];
  assert.throws(() => sealEvidence("multiseed", repeated), /ordered values|unique/);

  const weak = multiSeedDraft();
  weak.campaign.fuzz.runsPerProperty = MULTISEED.fuzzRuns - 1;
  assert.throws(() => sealEvidence("multiseed", weak), /runsPerProperty/);

  const missingRouterCoverage = multiSeedDraft();
  missingRouterCoverage.campaign.invariants.contracts.splice(4, 1);
  assert.throws(() => sealEvidence("multiseed", missingRouterCoverage), /enumerate every required invariant contract/);

  const factoryOnlyOnce = multiSeedDraft();
  factoryOnlyOnce.campaign.invariants.seedPolicy = "factory-release-seed-only";
  assert.throws(() => sealEvidence("multiseed", factoryOnlyOnce), /seedPolicy/);

  const reverting = multiSeedDraft();
  reverting.results[0].invariants.unexpectedReverts = 1;
  assert.throws(() => sealEvidence("multiseed", reverting), /unexpectedReverts/);
});

test("multi-seed evidence integrity rejects mutation after sealing", () => {
  const evidence = sealEvidence("multiseed", multiSeedDraft());
  evidence.results[0].fuzz.durationSeconds += 1;
  assert.throws(() => validateMultiSeedEvidence(evidence), /reportHash/);
});

test("accepts a non-broadcast Base Mainnet fork rehearsal", () => {
  const evidence = sealEvidence("fork", forkDraft());
  assert.equal(validateBaseMainnetForkEvidence(evidence).status, "verified");
});

test("fork evidence rejects wrong network, router, bindings and broadcast claims", () => {
  const wrongChain = forkDraft();
  wrongChain.fork.chainId = 84_532;
  assert.throws(() => sealEvidence("fork", wrongChain), /chainId/);

  const wrongRouter = forkDraft();
  wrongRouter.upstream.universalRouter.address = "0x1111111111111111111111111111111111111111";
  assert.throws(() => sealEvidence("fork", wrongRouter), /universalRouter.address/);

  const missingBinding = forkDraft();
  missingBinding.upstream.bindings.positionManagerPermit2 = false;
  assert.throws(() => sealEvidence("fork", missingBinding), /positionManagerPermit2/);

  const broadcast = forkDraft();
  broadcast.fork.upstreamTransactionsBroadcast = true;
  assert.throws(() => sealEvidence("fork", broadcast), /upstreamTransactionsBroadcast/);

  const walletKey = forkDraft();
  walletKey.fork.walletTxtUsed = true;
  assert.throws(() => sealEvidence("fork", walletKey), /walletTxtUsed/);

  const hiddenTestKey = forkDraft();
  hiddenTestKey.fork.deterministicTestKeyUsed = false;
  assert.throws(() => sealEvidence("fork", hiddenTestKey), /deterministicTestKeyUsed/);
});

test("fork evidence requires explicit test-router liquidity disclosure and all adversarial cases", () => {
  const disguisedLiquidity = forkDraft();
  disguisedLiquidity.rehearsal.liquidityProvider = "official-position-manager";
  assert.throws(() => sealEvidence("fork", disguisedLiquidity), /liquidityProvider/);

  const incomplete = forkDraft();
  incomplete.rehearsal.adversarialCases.pop();
  assert.throws(() => sealEvidence("fork", incomplete), /adversarialCases/);
});
