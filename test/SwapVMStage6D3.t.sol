// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {SwapVMMiniVM} from "../src/SwapVMMiniVM.sol";

contract SwapVMStage6D3Harness is SwapVMMiniVM {
    bytes32 internal constant WORLD =
        bytes32(uint256(0x1111111111111111111111111111111111111111111111111111111111111111));

    function install(bytes calldata packageBytes, bytes32 target) external {
        bytes32 codeHash = _registerPackage(WORLD, packageBytes);
        _instantiatePackage(WORLD, target, codeHash);
    }

    function setStorage(bytes32 target, bytes32 slot, bytes32 value) external {
        _programStorage[WORLD][target][slot] = value;
    }

    function deploy(bytes calldata packageBytes, bytes calldata input, bytes32 actor, uint32 limit)
        external
        returns (bytes32 target, RunResult memory result)
    {
        bytes32 codeHash = _registerPackage(WORLD, packageBytes);
        uint64 nonce = creatorNonce[WORLD][actor];
        target = _deriveContractId(WORLD, actor, nonce, codeHash);
        _instantiatePackage(WORLD, target, codeHash);
        creatorNonce[WORLD][actor] = nonce + 1;
        result = _runProgram(WORLD, target, input, limit, false, _context(actor), true);
        _commitWrites(WORLD, result.targets, result.slots, result.values);
        _commitDeployments(WORLD, result.deployments);
    }

    function execute(bytes32 target, bytes calldata input, bytes32 actor, uint32 limit, bool staticMode)
        external
        returns (RunResult memory result)
    {
        result = _runProgram(WORLD, target, input, limit, staticMode, _context(actor), false);
        _commitWrites(WORLD, result.targets, result.slots, result.values);
        _commitDeployments(WORLD, result.deployments);
    }

    function runRaw(bytes calldata code, uint32 limit, bool staticMode)
        external
        view
        returns (RunResult memory result)
    {
        bytes32[] memory empty = new bytes32[](0);
        Deployment[] memory noDeployments = new Deployment[](0);
        FrameSeed memory seed = FrameSeed({
            used: 0,
            depth: 1,
            ancestorMemory: 0,
            targets: empty,
            slots: empty,
            values: empty,
            deployments: noDeployments,
            records: bytes(""),
            recordCount: 0
        });
        bytes memory jumpdest = _packJumpdest(_validateCode(code));
        FrameInput memory frame = FrameInput({
            code: code,
            jumpdest: jumpdest,
            input: bytes(""),
            byteLimit: limit,
            staticMode: staticMode,
            context: _context(bytes32(uint256(uint160(address(0xA11CE))))),
            entry: 0,
            seed: seed
        });
        return _runCode(frame);
    }

    function storageAt(bytes32 target, bytes32 slot) external view returns (bytes32) {
        return _programStorage[WORLD][target][slot];
    }

    function _context(bytes32 actor) private pure returns (VMContext memory) {
        return VMContext({
            worldId: WORLD,
            addressId: bytes32(0),
            caller: actor,
            txActor: actor,
            txRouter: address(0),
            txExecutor: address(0),
            txRecipient: address(0),
            executionHeight: 77,
            ethAmountIn: 123,
            grossTokenOut: 1_000_000,
            tickAfter: -17,
            liquidityAfter: 789,
            byteGasPrice: 11,
            chainBlockNumber: 999,
            chainTimestamp: 1_234
        });
    }
}

contract SwapVMStage6D3Test is Test {
    using stdJson for string;

    bytes32 internal constant ACTOR = bytes32(uint256(uint160(address(0xA11CE))));
    bytes32 internal constant TARGET =
        bytes32((uint256(1) << 248) | uint256(0x22222222222222222222222222222222222222222222222222222222222222));
    bytes32 internal constant TARGET2 =
        bytes32((uint256(1) << 248) | uint256(0x33333333333333333333333333333333333333333333333333333333333333));
    string internal corpus;

    function setUp() public {
        corpus = vm.readFile("tooling/tinysol/fixtures/simulator-solidity-differential.json");
    }

    function test_stage6D3_allCompilerAndReferenceConstructorsDifferential() public {
        _assertDeploy("Context", bytes(""), 0);
        _assertDeploy("ControlFlow", bytes(""), 1);
        _assertDeploy("Counter", abi.encode(uint256(5)), 2);
        _assertDeploy("EventDemo", bytes(""), 3);
        _assertDeploy("Factory", bytes(""), 4);
        _assertDeploy("Mapping", bytes(""), 5);
        _assertDeploy("MiniNFT", abi.encode(uint256(1)), 6);
        _assertDeploy("MiniToken", abi.encode(uint256(1_000), ACTOR), 7);
        _assertDeploy("NestedCaller", bytes(""), 8);
        _assertDeploy("SRC20-v1", abi.encode(bytes32("Token"), bytes32("TOK"), uint256(18), uint256(1_000), ACTOR), 9);
        _assertDeploy(
            "SRC721-v1", abi.encode(bytes32("NFT"), bytes32("NFT"), uint256(1), ACTOR, bytes32(uint256(0x1234))), 10
        );
        _assertDeploy("SRC1155-v1", abi.encode(bytes32(uint256(0x5678)), uint256(1), uint256(500), ACTOR), 11);
        _assertDeploy("CPAMM-v1", bytes(""), 12);
    }

    function test_stage6D3_runtimeStorageLoopMappingAndEventDifferential() public {
        SwapVMStage6D3Harness harness = new SwapVMStage6D3Harness();
        harness.install(_package("Counter"), TARGET);
        harness.setStorage(TARGET, bytes32(0), bytes32(uint256(5)));
        SwapVMMiniVM.RunResult memory result = harness.execute(
            TARGET,
            abi.encodePacked(bytes4(keccak256("increment(uint256)")), abi.encode(uint256(3))),
            ACTOR,
            1_000_000,
            false
        );
        _assertResult(result, 13);
        assertEq(harness.storageAt(TARGET, bytes32(0)), bytes32(uint256(8)));

        harness = new SwapVMStage6D3Harness();
        harness.install(_package("ControlFlow"), TARGET);
        result = harness.execute(
            TARGET,
            abi.encodePacked(bytes4(keccak256("arithmetic(uint256)")), abi.encode(uint256(1))),
            ACTOR,
            1_000_000,
            false
        );
        _assertResult(result, 14);

        harness = new SwapVMStage6D3Harness();
        harness.install(_package("EventDemo"), TARGET);
        result = harness.execute(
            TARGET,
            abi.encodePacked(bytes4(keccak256("set(uint256,bool)")), abi.encode(uint256(55), true)),
            ACTOR,
            1_000_000,
            false
        );
        _assertResult(result, 16);

        harness = new SwapVMStage6D3Harness();
        harness.install(_package("Mapping"), TARGET);
        result = harness.execute(
            TARGET,
            abi.encodePacked(bytes4(keccak256("set(bytes32,uint256)")), abi.encode(ACTOR, uint256(42))),
            ACTOR,
            1_000_000,
            false
        );
        _assertResult(result, 17);
    }

    function test_stage6D3_callStaticCallCreateSharedMeterAndOrderDifferential() public {
        SwapVMStage6D3Harness harness = new SwapVMStage6D3Harness();
        harness.install(_package("NestedCaller"), TARGET);
        harness.install(_package("Counter"), TARGET2);
        harness.setStorage(TARGET2, bytes32(0), bytes32(uint256(2)));
        SwapVMMiniVM.RunResult memory result = harness.execute(
            TARGET,
            abi.encodePacked(bytes4(keccak256("increment(bytes32,uint256)")), abi.encode(TARGET2, uint256(4))),
            ACTOR,
            1_000_000,
            false
        );
        _assertResult(result, 18);

        harness = new SwapVMStage6D3Harness();
        harness.install(_package("NestedCaller"), TARGET);
        harness.install(_package("Counter"), TARGET2);
        harness.setStorage(TARGET2, bytes32(0), bytes32(uint256(7)));
        result = harness.execute(
            TARGET, abi.encodePacked(bytes4(keccak256("read(bytes32)")), abi.encode(TARGET2)), ACTOR, 1_000_000, false
        );
        _assertResult(result, 19);

        harness = new SwapVMStage6D3Harness();
        harness.install(_package("Factory"), TARGET);
        harness.install(_package("Counter"), TARGET2); // also registers the package used by CREATE
        result = harness.execute(
            TARGET,
            abi.encodePacked(
                bytes4(keccak256("spawn(bytes32,uint256)")), abi.encode(keccak256(_package("Counter")), uint256(91))
            ),
            ACTOR,
            1_000_000,
            false
        );
        _assertResult(result, 20);
        assertEq(result.deployments.length, 1);
        assertEq(result.recordCount, 2);
    }

    function test_stage6D3_failureByteLimitStaticAndMalformedDifferential() public {
        SwapVMStage6D3Harness harness = new SwapVMStage6D3Harness();
        harness.install(_package("ControlFlow"), TARGET);
        (bool success, bytes memory revertData) = address(harness)
            .call(
                abi.encodeCall(
                    SwapVMStage6D3Harness.execute,
                    (
                        TARGET,
                        abi.encodePacked(bytes4(keccak256("setOrFail(bool,uint256)")), abi.encode(false, uint256(9))),
                        ACTOR,
                        1_000_000,
                        false
                    )
                )
            );
        assertFalse(success);
        assertEq(_selector(revertData), SwapVMMiniVM.VMExplicitRevert.selector);
        assertEq(harness.storageAt(TARGET, bytes32(0)), bytes32(0));

        harness = new SwapVMStage6D3Harness();
        harness.install(_package("ControlFlow"), TARGET);
        (success, revertData) = address(harness)
            .call(
                abi.encodeCall(
                    SwapVMStage6D3Harness.execute,
                    (
                        TARGET,
                        abi.encodePacked(bytes4(keccak256("arithmetic(uint256)")), abi.encode(uint256(1))),
                        ACTOR,
                        40,
                        false
                    )
                )
            );
        assertFalse(success);
        assertEq(_selector(revertData), SwapVMMiniVM.OutOfByteGas.selector);
        assertEq(_firstWord(revertData), 41);

        harness = new SwapVMStage6D3Harness();
        harness.install(_package("EventDemo"), TARGET);
        (success, revertData) = address(harness)
            .call(
                abi.encodeCall(
                    SwapVMStage6D3Harness.execute,
                    (
                        TARGET,
                        abi.encodePacked(bytes4(keccak256("set(uint256,bool)")), abi.encode(uint256(1), true)),
                        ACTOR,
                        1_000_000,
                        true
                    )
                )
            );
        assertFalse(success);
        assertEq(_selector(revertData), SwapVMMiniVM.StaticViolation.selector);

        (success, revertData) =
            address(harness).staticcall(abi.encodeCall(SwapVMStage6D3Harness.runRaw, (hex"fe", 100, false)));
        assertFalse(success);
        assertEq(_selector(revertData), SwapVMMiniVM.UnknownOpcode.selector);
        (success, revertData) =
            address(harness).staticcall(abi.encodeCall(SwapVMStage6D3Harness.runRaw, (hex"61ff", 100, false)));
        assertFalse(success);
        assertEq(_selector(revertData), SwapVMMiniVM.TruncatedImmediate.selector);

        harness = new SwapVMStage6D3Harness();
        harness.install(_package("NestedCaller"), TARGET);
        harness.install(_package("ControlFlow"), TARGET2);
        (success, revertData) = address(harness)
            .call(
                abi.encodeCall(
                    SwapVMStage6D3Harness.execute,
                    (
                        TARGET,
                        abi.encodePacked(
                            bytes4(keccak256("setOrFail(bytes32,bool,uint256)")),
                            abi.encode(TARGET2, false, uint256(88))
                        ),
                        ACTOR,
                        1_000_000,
                        false
                    )
                )
            );
        assertFalse(success);
        assertEq(_selector(revertData), SwapVMMiniVM.VMExplicitRevert.selector);
        assertEq(harness.storageAt(TARGET2, bytes32(0)), bytes32(0));

        harness = new SwapVMStage6D3Harness();
        harness.install(_package("NestedCaller"), TARGET);
        harness.install(_package("Counter"), TARGET2);
        (success, revertData) = address(harness)
            .call(
                abi.encodeCall(
                    SwapVMStage6D3Harness.execute,
                    (
                        TARGET,
                        abi.encodePacked(
                            bytes4(keccak256("increment(bytes32,uint256)")), abi.encode(TARGET2, uint256(1))
                        ),
                        ACTOR,
                        1_000_000,
                        true
                    )
                )
            );
        assertFalse(success);
        assertEq(_selector(revertData), SwapVMMiniVM.StaticViolation.selector);
        assertEq(harness.storageAt(TARGET2, bytes32(0)), bytes32(0));
    }

    function test_stage6D3_repeatedSstoreCoalescesJournal() public {
        SwapVMStage6D3Harness harness = new SwapVMStage6D3Harness();
        SwapVMMiniVM.RunResult memory result = harness.runRaw(hex"60015f5560025f5500", 1_000_000, false);

        assertEq(result.executedBytes, 9);
        assertEq(result.targets.length, 1);
        assertEq(result.slots.length, 1);
        assertEq(result.values.length, 1);
        assertEq(result.targets[0], bytes32(0));
        assertEq(result.slots[0], bytes32(0));
        assertEq(result.values[0], bytes32(uint256(2)));
    }

    function test_stage6D3_callDepthBoundaryMatchesProduction() public {
        SwapVMStage6D3Harness harness = new SwapVMStage6D3Harness();
        bytes memory code = abi.encodePacked(hex"7f", TARGET, hex"5f5f5f5ff100");
        bytes memory packageBytes = abi.encodePacked(
            bytes4(0x53564d31),
            bytes2(uint16(1)),
            bytes2(uint16(0)),
            bytes2(uint16(0)),
            bytes2(uint16(code.length)),
            bytes32(0),
            code
        );
        harness.install(packageBytes, TARGET);
        (bool success, bytes memory revertData) = address(harness)
            .call(abi.encodeCall(SwapVMStage6D3Harness.execute, (TARGET, bytes(""), ACTOR, 1_000_000, false)));
        assertFalse(success);
        assertEq(_selector(revertData), SwapVMMiniVM.CallDepthExceeded.selector);
        assertEq(_firstWord(revertData), 33);
    }

    function test_stage6D3_completeCompilerContextDifferential() public {
        SwapVMStage6D3Harness harness = new SwapVMStage6D3Harness();
        harness.install(_package("Context"), TARGET);
        SwapVMMiniVM.RunResult memory result =
            harness.execute(TARGET, abi.encodePacked(bytes4(keccak256("actors()"))), ACTOR, 1_000_000, false);
        _assertResult(result, 25);
        result = harness.execute(TARGET, abi.encodePacked(bytes4(keccak256("worldValues()"))), ACTOR, 1_000_000, false);
        _assertResult(result, 26);
        result = harness.execute(TARGET, abi.encodePacked(bytes4(keccak256("chainValues()"))), ACTOR, 1_000_000, false);
        _assertResult(result, 27);
    }

    function test_stage6D3_tinySolConformanceCorpusDifferential() public {
        SwapVMStage6D3Harness harness = new SwapVMStage6D3Harness();
        (bytes32 target, SwapVMMiniVM.RunResult memory result) =
            harness.deploy(_package("Conformance"), abi.encode(uint256(5)), ACTOR, 1_000_000);
        assertEq(target, corpus.readBytes32(".cases[28].result.rootTarget"));
        _assertResult(result, 28);

        harness = new SwapVMStage6D3Harness();
        harness.install(_package("Conformance"), TARGET);
        result = harness.execute(
            TARGET,
            abi.encodePacked(bytes4(keccak256("arithmetic(uint256,uint256)")), abi.encode(uint256(9), uint256(4))),
            ACTOR,
            1_000_000,
            false
        );
        _assertResult(result, 29);

        harness = new SwapVMStage6D3Harness();
        harness.install(_package("Conformance"), TARGET);
        result = harness.execute(
            TARGET,
            abi.encodePacked(bytes4(keccak256("controlFlow(uint256,bool)")), abi.encode(uint256(4), true)),
            ACTOR,
            1_000_000,
            false
        );
        _assertResult(result, 30);
        assertEq(harness.storageAt(TARGET, bytes32(0)), bytes32(uint256(14)));

        harness = new SwapVMStage6D3Harness();
        harness.install(_package("Conformance"), TARGET);
        result = harness.execute(
            TARGET,
            abi.encodePacked(bytes4(keccak256("internalCall(uint256)")), abi.encode(uint256(12))),
            ACTOR,
            1_000_000,
            false
        );
        _assertResult(result, 31);

        harness = new SwapVMStage6D3Harness();
        harness.install(_package("Conformance"), TARGET);
        result = harness.execute(
            TARGET,
            abi.encodePacked(
                bytes4(keccak256("abiRoundTrip(bytes32,address,bytes32,bool,uint256)")),
                abi.encode(ACTOR, address(0xBEEF), bytes32("TinySol ABI conformance"), true, uint256(73))
            ),
            ACTOR,
            1_000_000,
            false
        );
        _assertResult(result, 32);

        (bool success, bytes memory revertData) = address(harness)
            .call(
                abi.encodeCall(
                    SwapVMStage6D3Harness.execute,
                    (
                        TARGET,
                        abi.encodePacked(
                            bytes4(keccak256("abiRoundTrip(bytes32,address,bytes32,bool,uint256)")),
                            abi.encode(ACTOR, address(0xBEEF), bytes32("TinySol ABI conformance"), false, uint256(73))
                        ),
                        ACTOR,
                        1_000_000,
                        false
                    )
                )
            );
        assertFalse(corpus.readBool(".cases[33].result.success"));
        assertEq(corpus.readString(".cases[33].result.errorCode"), "EXPLICIT_REVERT");
        assertFalse(success);
        assertEq(_selector(revertData), SwapVMMiniVM.VMExplicitRevert.selector);
    }

    function test_stage6D3_tinySolArithmeticMatrixDifferential() public {
        _assertConformanceSuccess(
            abi.encodePacked(bytes4(keccak256("arithmetic(uint256,uint256)")), abi.encode(uint256(1), uint256(0))), 34
        );
        _assertConformanceSuccess(
            abi.encodePacked(bytes4(keccak256("arithmetic(uint256,uint256)")), abi.encode(uint256(2), uint256(3))), 35
        );
        _assertConformanceSuccess(
            abi.encodePacked(
                bytes4(keccak256("arithmetic(uint256,uint256)")),
                abi.encode(uint256(1_000_000_000_000_000_000), uint256(2_000_000_000_000_000_000))
            ),
            36
        );
    }

    function test_stage6D3_tinySolControlFlowMatrixDifferential() public {
        _assertConformanceSuccess(
            abi.encodePacked(bytes4(keccak256("controlFlow(uint256,bool)")), abi.encode(uint256(0), false)), 37
        );
        _assertConformanceSuccess(
            abi.encodePacked(bytes4(keccak256("controlFlow(uint256,bool)")), abi.encode(uint256(0), true)), 38
        );
        _assertConformanceSuccess(
            abi.encodePacked(bytes4(keccak256("controlFlow(uint256,bool)")), abi.encode(uint256(17), false)), 39
        );
    }

    function test_stage6D3_tinySolInternalCallMatrixDifferential() public {
        _assertConformanceSuccess(
            abi.encodePacked(bytes4(keccak256("internalCall(uint256)")), abi.encode(uint256(0))), 40
        );
        _assertConformanceSuccess(
            abi.encodePacked(bytes4(keccak256("internalCall(uint256)")), abi.encode(uint256(1))), 41
        );
        _assertConformanceSuccess(
            abi.encodePacked(
                bytes4(keccak256("internalCall(uint256)")), abi.encode(uint256(1_000_000_000_000_000_000))
            ),
            42
        );
    }

    function test_stage6D3_tinySolAbiCanonicalizationMatrixDifferential() public {
        bytes memory zeroPayload = abi.encodePacked(
            bytes4(keccak256("abiRoundTrip(bytes32,address,bytes32,bool,uint256)")),
            abi.encode(TARGET2, address(0), bytes32(0), true, uint256(0))
        );
        _assertConformanceSuccess(zeroPayload, 43);
        _assertConformanceSuccess(
            abi.encodePacked(
                bytes4(keccak256("abiRoundTrip(bytes32,address,bytes32,bool,uint256)")),
                abi.encode(
                    bytes32(0xabababababababababababababababababababababababababababababababab),
                    address(type(uint160).max),
                    bytes32(type(uint256).max),
                    true,
                    (uint256(1) << 255) + 123
                )
            ),
            44
        );

        SwapVMStage6D3Harness harness = _conformanceHarness();
        _assertConformanceRevert(
            harness,
            abi.encodePacked(
                bytes4(keccak256("abiRoundTrip(bytes32,address,bytes32,bool,uint256)")),
                abi.encode(ACTOR, address(0xBEEF), bytes32("TinySol ABI conformance"), uint256(2), uint256(73))
            ),
            45
        );
        harness = _conformanceHarness();
        _assertConformanceRevert(
            harness,
            abi.encodePacked(
                bytes4(keccak256("abiRoundTrip(bytes32,address,bytes32,bool,uint256)")),
                abi.encode(ACTOR, uint256(1) << 160, bytes32("TinySol ABI conformance"), true, uint256(73))
            ),
            46
        );
        bytes memory shortPayload = new bytes(zeroPayload.length - 1);
        for (uint256 index; index < shortPayload.length; ++index) {
            shortPayload[index] = zeroPayload[index];
        }
        harness = _conformanceHarness();
        _assertConformanceRevert(harness, shortPayload, 47);
        harness = _conformanceHarness();
        _assertConformanceRevert(harness, bytes.concat(zeroPayload, bytes32(0)), 48);
        harness = _conformanceHarness();
        _assertConformanceRevert(harness, hex"deadbeef", 49);
    }

    function test_stage6D3_tinySolStorageSequenceDifferential() public {
        SwapVMStage6D3Harness harness = _conformanceHarness();
        SwapVMMiniVM.RunResult memory result = harness.execute(
            TARGET,
            abi.encodePacked(bytes4(keccak256("controlFlow(uint256,bool)")), abi.encode(uint256(4), true)),
            ACTOR,
            1_000_000,
            false
        );
        _assertResult(result, 50);
        result = harness.execute(
            TARGET,
            abi.encodePacked(bytes4(keccak256("internalCall(uint256)")), abi.encode(uint256(100))),
            ACTOR,
            1_000_000,
            false
        );
        _assertResult(result, 51);
        bytes memory abiWrite = abi.encodePacked(
            bytes4(keccak256("abiRoundTrip(bytes32,address,bytes32,bool,uint256)")),
            abi.encode(ACTOR, address(0xBEEF), bytes32("TinySol ABI conformance"), true, uint256(211))
        );
        result = harness.execute(TARGET, abiWrite, ACTOR, 1_000_000, false);
        _assertResult(result, 52);
        abiWrite = abi.encodePacked(
            bytes4(keccak256("abiRoundTrip(bytes32,address,bytes32,bool,uint256)")),
            abi.encode(ACTOR, address(0xBEEF), bytes32("TinySol ABI conformance"), true, uint256(377))
        );
        result = harness.execute(TARGET, abiWrite, ACTOR, 1_000_000, false);
        _assertResult(result, 53);
        _assertConformanceRevert(
            harness,
            abi.encodePacked(
                bytes4(keccak256("abiRoundTrip(bytes32,address,bytes32,bool,uint256)")),
                abi.encode(ACTOR, address(0xBEEF), bytes32("TinySol ABI conformance"), false, uint256(999))
            ),
            54
        );
        result = harness.execute(
            TARGET,
            abi.encodePacked(bytes4(keccak256("balanceOf(bytes32)")), abi.encode(ACTOR)),
            ACTOR,
            1_000_000,
            false
        );
        _assertResult(result, 55);
        result = harness.execute(TARGET, abi.encodePacked(bytes4(keccak256("getScalar()"))), ACTOR, 1_000_000, false);
        _assertResult(result, 56);
        assertEq(harness.storageAt(TARGET, bytes32(0)), bytes32(uint256(107)));
    }

    function test_stage6D3_fixedSeedRawDifferentialCorpus() public {
        SwapVMStage6D3Harness harness = new SwapVMStage6D3Harness();
        for (uint256 index; index < 64; ++index) {
            string memory base = string.concat(".rawCases[", vm.toString(index), "]");
            bytes memory code = corpus.readBytes(string.concat(base, ".code"));
            SwapVMMiniVM.RunResult memory result = harness.runRaw(code, 1_000_000, false);
            assertTrue(corpus.readBool(string.concat(base, ".result.success")));
            string memory caseId = vm.toString(index);
            assertEq(result.executedBytes, corpus.readUint(string.concat(base, ".result.executedBytes")), caseId);
            assertEq(result.output, corpus.readBytes(string.concat(base, ".result.output")), caseId);
            assertEq(result.targets.length, 0, caseId);
            assertEq(result.deployments.length, 0, caseId);
            assertEq(result.recordCount, 0, caseId);
        }
    }

    function _assertDeploy(string memory name, bytes memory input, uint256 index) private {
        SwapVMStage6D3Harness harness = new SwapVMStage6D3Harness();
        (bytes32 target, SwapVMMiniVM.RunResult memory result) = harness.deploy(_package(name), input, ACTOR, 1_000_000);
        string memory base = string.concat(".cases[", vm.toString(index), "].result");
        assertEq(target, corpus.readBytes32(string.concat(base, ".rootTarget")), name);
        _assertResult(result, index);
    }

    function _conformanceHarness() private returns (SwapVMStage6D3Harness harness) {
        harness = new SwapVMStage6D3Harness();
        harness.install(_package("Conformance"), TARGET);
    }

    function _assertConformanceSuccess(bytes memory input, uint256 index) private {
        SwapVMStage6D3Harness harness = _conformanceHarness();
        SwapVMMiniVM.RunResult memory result = harness.execute(TARGET, input, ACTOR, 1_000_000, false);
        _assertResult(result, index);
    }

    function _assertConformanceRevert(SwapVMStage6D3Harness harness, bytes memory input, uint256 index) private view {
        string memory base = string.concat(".cases[", vm.toString(index), "].result");
        assertFalse(corpus.readBool(string.concat(base, ".success")));
        assertEq(corpus.readString(string.concat(base, ".errorCode")), "EXPLICIT_REVERT");
        (bool success, bytes memory revertData) = address(harness)
            .staticcall(abi.encodeCall(SwapVMStage6D3Harness.execute, (TARGET, input, ACTOR, 1_000_000, false)));
        assertFalse(success);
        assertEq(_selector(revertData), SwapVMMiniVM.VMExplicitRevert.selector);
    }

    function _assertResult(SwapVMMiniVM.RunResult memory result, uint256 index) private view {
        string memory base = string.concat(".cases[", vm.toString(index), "].result");
        assertEq(result.executedBytes, corpus.readUint(string.concat(base, ".executedBytes")));
        assertEq(result.output, corpus.readBytes(string.concat(base, ".output")));
        assertEq(result.records, corpus.readBytes(string.concat(base, ".encodedRecords")));
        string memory solidityBase = string.concat(".cases[", vm.toString(index), "].solidity");
        assertEq(result.recordCount, corpus.readUint(string.concat(solidityBase, ".recordCount")));
        assertEq(result.slots.length, corpus.readUint(string.concat(solidityBase, ".storageJournalCount")));
        if (result.slots.length != 0) {
            assertEq(result.targets[0], corpus.readBytes32(string.concat(base, ".storageJournal[0].target")));
            assertEq(result.slots[0], corpus.readBytes32(string.concat(base, ".storageJournal[0].slot")));
            assertEq(result.values[0], corpus.readBytes32(string.concat(base, ".storageJournal[0].value")));
        }
        assertEq(result.deployments.length, corpus.readUint(string.concat(solidityBase, ".internalDeploymentCount")));
        if (result.deployments.length != 0) {
            uint256 expectedIndex = corpus.readBool(string.concat(base, ".deploymentDiff[0].root")) ? 1 : 0;
            assertEq(expectedIndex, 0, "internal deployment expected");
            assertEq(
                result.deployments[0].contractId,
                corpus.readBytes32(string.concat(base, ".deploymentDiff[0].contractId"))
            );
            assertEq(
                result.deployments[0].creator, corpus.readBytes32(string.concat(base, ".deploymentDiff[0].creator"))
            );
            assertEq(
                result.deployments[0].codeHash, corpus.readBytes32(string.concat(base, ".deploymentDiff[0].codeHash"))
            );
        }
    }

    function _package(string memory name) private view returns (bytes memory) {
        string memory prefix = bytes(name).length >= 3 && bytes(name)[0] == "S" && bytes(name)[1] == "R"
            && bytes(name)[2] == "C"
            ? "reference/"
            : keccak256(bytes(name)) == keccak256("CPAMM-v1") ? "reference/" : "tooling/tinysol/fixtures/compiler/";
        return vm.readFile(string.concat(prefix, name, ".json")).readBytes(".package");
    }

    function _selector(bytes memory data) private pure returns (bytes4 selector) {
        if (data.length < 4) return bytes4(0);
        assembly ("memory-safe") { selector := mload(add(data, 0x20)) }
    }

    function _firstWord(bytes memory data) private pure returns (uint256 value) {
        assembly ("memory-safe") { value := mload(add(data, 0x24)) }
    }
}
