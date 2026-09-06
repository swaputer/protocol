// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {SwapVMMiniVM} from "../src/SwapVMMiniVM.sol";

contract SwapVMStage6D2Harness is SwapVMMiniVM {
    bytes32 internal constant WORLD = keccak256("SwapVM Stage6D2 compiler world");
    uint64 internal serial;

    function registerPackage(bytes calldata packageBytes) external returns (bytes32) {
        return _registerPackage(WORLD, packageBytes);
    }

    function deploy(bytes calldata packageBytes, bytes calldata constructorInput, bytes32 actor)
        external
        returns (bytes32 target, bytes memory output, uint32 used, bytes memory records, uint16 recordCount)
    {
        bytes32 codeHash = _registerPackage(WORLD, packageBytes);
        target = bytes32((uint256(1) << 248) | (uint256(keccak256(abi.encodePacked(codeHash, ++serial))) >> 8));
        _instantiatePackage(WORLD, target, codeHash);
        RunResult memory result = _runProgram(WORLD, target, constructorInput, 1_000_000, false, _context(actor), true);
        _commitWrites(WORLD, result.targets, result.slots, result.values);
        _commitDeployments(WORLD, result.deployments);
        return (target, result.output, result.executedBytes, result.records, result.recordCount);
    }

    function execute(bytes32 target, bytes calldata input, bytes32 actor)
        external
        returns (bytes memory output, uint32 used, bytes memory records, uint16 recordCount)
    {
        RunResult memory result = _runProgram(WORLD, target, input, 1_000_000, false, _context(actor), false);
        _commitWrites(WORLD, result.targets, result.slots, result.values);
        _commitDeployments(WORLD, result.deployments);
        return (result.output, result.executedBytes, result.records, result.recordCount);
    }

    function executeStatic(bytes32 target, bytes calldata input, bytes32 actor)
        external
        view
        returns (bytes memory output, uint32 used, bytes memory records, uint16 recordCount)
    {
        RunResult memory result = _runProgram(WORLD, target, input, 1_000_000, true, _context(actor), false);
        return (result.output, result.executedBytes, result.records, result.recordCount);
    }

    function storageAt(bytes32 target, bytes32 slot) external view returns (bytes32) {
        return _programStorage[WORLD][target][slot];
    }

    function worldId() external pure returns (bytes32) {
        return WORLD;
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
            grossTokenOut: 456,
            tickAfter: -17,
            liquidityAfter: 789,
            byteGasPrice: 11,
            chainBlockNumber: 999,
            chainTimestamp: 1_234
        });
    }
}

contract SwapVMStage6D2Test is Test {
    using stdJson for string;

    SwapVMStage6D2Harness internal harness;
    bytes32 internal actor = bytes32(uint256(uint160(address(0xA11CE))));

    function setUp() public {
        harness = new SwapVMStage6D2Harness();
    }

    function test_stage6D2_constructorScalarDispatcherAndUintWrap() public {
        bytes32 counter = _deploy("Counter", abi.encode(uint256(5)));
        (bytes memory output,,,) = _execute(counter, "increment(uint256)", abi.encode(uint256(3)));
        assertEq(abi.decode(output, (uint256)), 8);
        assertEq(_read(counter, "get()", bytes("")), abi.encode(uint256(8)));

        bytes32 wrapping = _deploy("Counter", abi.encode(type(uint256).max));
        (output,,,) = _execute(wrapping, "increment(uint256)", abi.encode(uint256(1)));
        assertEq(abi.decode(output, (uint256)), 0);
    }

    function test_stage6D2_mappingUsesDeterministicHashedStorage() public {
        bytes32 target = _deploy("Mapping", bytes(""));
        _execute(target, "set(bytes32,uint256)", abi.encode(actor, uint256(42)));
        assertEq(_read(target, "get(bytes32)", abi.encode(actor)), abi.encode(uint256(42)));

        string memory json = vm.readFile("tooling/tinysol/fixtures/compiler/Mapping.json");
        bytes32 namespace = json.readBytes32(".storageLayout.items[0].namespace");
        bytes32 slot = keccak256(abi.encodePacked(namespace, actor));
        assertEq(harness.storageAt(target, slot), bytes32(uint256(42)));
    }

    function test_stage6D2_controlFlowSignedMathAndBoolShortCircuit() public {
        bytes32 target = _deploy("ControlFlow", bytes(""));
        assertEq(_read(target, "arithmetic(uint256)", abi.encode(uint256(1))), abi.encode(uint256(16)));
        assertEq(_read(target, "signedMath(int256)", abi.encode(int256(-9))), abi.encode(int256(4), true));
        assertEq(_read(target, "logic(bool,bool)", abi.encode(false, false)), abi.encode(true));
        assertEq(_read(target, "logic(bool,bool)", abi.encode(true, false)), abi.encode(false));
    }

    function test_stage6D2_requireRevertRollsBackPriorWrite() public {
        bytes32 target = _deploy("ControlFlow", bytes(""));
        _execute(target, "setOrFail(bool,uint256)", abi.encode(true, uint256(7)));
        (bool success,) = address(harness)
            .call(
                abi.encodeCall(
                    SwapVMStage6D2Harness.execute,
                    (
                        target,
                        abi.encodePacked(bytes4(keccak256("setOrFail(bool,uint256)")), abi.encode(false, uint256(9))),
                        actor
                    )
                )
            );
        assertFalse(success);
        assertEq(_read(target, "getStored()", bytes("")), abi.encode(uint256(7)));
    }

    function test_stage6D2_contextOpcodesAndCanonicalAddressValidation() public {
        bytes32 target = _deploy("Context", bytes(""));
        assertEq(_read(target, "actors()", bytes("")), abi.encode(actor, actor));
        assertEq(
            _read(target, "worldValues()", bytes("")),
            abi.encode(harness.worldId(), uint256(77), uint256(123), uint256(456), int256(-17))
        );
        assertEq(
            _read(target, "chainValues()", bytes("")),
            abi.encode(uint256(999), uint256(1_234), uint256(11), uint256(74), uint256(1_000_000 - 79))
        );

        bytes memory invalidAddressWord = abi.encode(type(uint256).max);
        (bool success,) = address(harness)
            .staticcall(
                abi.encodeCall(
                    SwapVMStage6D2Harness.executeStatic,
                    (target, abi.encodePacked(bytes4(keccak256("echoAddress(address)")), invalidAddressWord), actor)
                )
            );
        assertFalse(success);
    }

    function test_stage6D2_eventRecordMatchesDescriptorLayout() public {
        bytes32 target = _deploy("EventDemo", bytes(""));
        (,, bytes memory records, uint16 count) = _execute(target, "set(uint256,bool)", abi.encode(uint256(55), true));
        assertEq(count, 1);
        assertEq(_word(records, 4), target);
        assertEq(uint8(records[36]), 2);
        assertEq(_word(records, 37), keccak256("Changed(bytes32,uint256,bool)"));
        assertEq(_word(records, 69), actor);
        assertEq(uint32(bytes4(_slice(records, 101, 4))), 64);
        assertEq(_word(records, 105), bytes32(uint256(55)));
        assertEq(_word(records, 137), bytes32(uint256(1)));
    }

    function test_stage6D2_callStaticCallCreateAndSharedMeter() public {
        bytes memory counterPackage = _package("Counter");
        harness.registerPackage(counterPackage);
        bytes32 counter = _deploy("Counter", abi.encode(uint256(2)));
        bytes32 caller = _deploy("NestedCaller", bytes(""));
        (, uint32 directUsed,,) = _execute(counter, "increment(uint256)", abi.encode(uint256(1)));
        (bytes memory output, uint32 nestedUsed,,) =
            _execute(caller, "increment(bytes32,uint256)", abi.encode(counter, uint256(4)));
        assertEq(abi.decode(output, (uint256)), 7);
        assertGt(nestedUsed, directUsed);
        assertEq(_read(caller, "read(bytes32)", abi.encode(counter)), abi.encode(uint256(7)));

        bytes32 factory = _deploy("Factory", bytes(""));
        bytes32 counterHash = keccak256(counterPackage);
        bytes memory records;
        uint16 count;
        (output,, records, count) = _execute(factory, "spawn(bytes32,uint256)", abi.encode(counterHash, uint256(91)));
        bytes32 child = abi.decode(output, (bytes32));
        assertEq(uint8(child[0]), 1);
        assertEq(_read(child, "get()", bytes("")), abi.encode(uint256(91)));
        assertEq(count, 2); // Kernel deployment record, then compiler event.
        assertEq(_recordEmitter(records, 1), factory);
    }

    function test_stage6D2_childRevertRollsBackAndStaticRuntimeDefenseRemainsAuthoritative() public {
        bytes32 control = _deploy("ControlFlow", bytes(""));
        bytes32 caller = _deploy("NestedCaller", bytes(""));
        (bool success,) = address(harness)
            .call(
                abi.encodeCall(
                    SwapVMStage6D2Harness.execute,
                    (
                        caller,
                        abi.encodePacked(
                            bytes4(keccak256("setOrFail(bytes32,bool,uint256)")),
                            abi.encode(control, false, uint256(88))
                        ),
                        actor
                    )
                )
            );
        assertFalse(success);
        assertEq(_read(control, "getStored()", bytes("")), abi.encode(uint256(0)));

        bytes32 eventDemo = _deploy("EventDemo", bytes(""));
        (success,) = address(harness)
            .staticcall(
                abi.encodeCall(
                    SwapVMStage6D2Harness.executeStatic,
                    (
                        eventDemo,
                        abi.encodePacked(bytes4(keccak256("set(uint256,bool)")), abi.encode(uint256(1), true)),
                        actor
                    )
                )
            );
        assertFalse(success);
    }

    function test_stage6D2_dispatcherRejectsUnknownSelectorAndInvalidLength() public {
        bytes32 target = _deploy("Counter", abi.encode(uint256(1)));
        (bool unknown,) =
            address(harness).call(abi.encodeCall(SwapVMStage6D2Harness.execute, (target, hex"deadbeef", actor)));
        assertFalse(unknown);
        (bool truncated,) = address(harness)
            .call(
                abi.encodeCall(
                    SwapVMStage6D2Harness.execute,
                    (target, abi.encodePacked(bytes4(keccak256("increment(uint256)")), bytes31(0)), actor)
                )
            );
        assertFalse(truncated);
    }

    function test_stage6D2_committedFixtureSourceMapHasFailureLine() public view {
        string memory json = vm.readFile("tooling/tinysol/fixtures/compiler/ControlFlow.json");
        uint256 length = json.readUint(".sourceMap[0].width");
        uint256 line = json.readUint(".sourceMap[0].sourceSpan.start.line");
        assertGt(length, 0);
        assertGt(line, 0);
        assertEq(json.readString(".manifest.compiler.status"), "experimental-unaudited");
    }

    function _deploy(string memory name, bytes memory input) private returns (bytes32 target) {
        (target,,,,) = harness.deploy(_package(name), input, actor);
    }

    function _package(string memory name) private view returns (bytes memory) {
        return vm.readFile(string.concat("tooling/tinysol/fixtures/compiler/", name, ".json")).readBytes(".package");
    }

    function _execute(bytes32 target, string memory signature, bytes memory arguments)
        private
        returns (bytes memory output, uint32 used, bytes memory records, uint16 count)
    {
        return harness.execute(target, abi.encodePacked(bytes4(keccak256(bytes(signature))), arguments), actor);
    }

    function _read(bytes32 target, string memory signature, bytes memory arguments)
        private
        view
        returns (bytes memory output)
    {
        (output,,,) =
            harness.executeStatic(target, abi.encodePacked(bytes4(keccak256(bytes(signature))), arguments), actor);
    }

    function _word(bytes memory data, uint256 offset) private pure returns (bytes32 value) {
        assembly ("memory-safe") {
            value := mload(add(add(data, 0x20), offset))
        }
    }

    function _slice(bytes memory data, uint256 offset, uint256 length) private pure returns (bytes memory result) {
        result = new bytes(length);
        for (uint256 i; i < length; ++i) {
            result[i] = data[offset + i];
        }
    }

    function _recordEmitter(bytes memory records, uint256 index) private pure returns (bytes32 emitter) {
        uint256 offset;
        for (uint256 i; i < index; ++i) {
            offset += 4 + uint32(bytes4(_slice(records, offset, 4)));
        }
        return _word(records, offset + 4);
    }
}
