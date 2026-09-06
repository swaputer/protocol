// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {SwapVMMiniVM} from "../src/SwapVMMiniVM.sol";

contract SwapVMStage6D1Harness is SwapVMMiniVM {
    function validateCode(bytes calldata code) external pure returns (bytes memory jumpdest) {
        return _validateCode(code);
    }

    function decodePackage(bytes calldata packageBytes)
        external
        pure
        returns (uint16 constructorEntry, uint16 runtimeEntry, bytes32 abiHash, bytes memory code)
    {
        return _decodePackage(packageBytes);
    }

    function runStatic(bytes calldata code) external view returns (bytes memory output) {
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
        VMContext memory context;
        FrameInput memory frame = FrameInput({
            code: code,
            jumpdest: jumpdest,
            input: bytes(""),
            byteLimit: 1_000,
            staticMode: true,
            context: context,
            entry: 0,
            seed: seed
        });
        return _runCode(frame).output;
    }
}

contract SwapVMStage6D1Test is Test {
    using stdJson for string;

    SwapVMStage6D1Harness internal harness;

    function setUp() public {
        harness = new SwapVMStage6D1Harness();
    }

    function test_stage6D1_codeValidationDifferentialCorpus() public view {
        string memory json = vm.readFile("tooling/tinysol/fixtures/differential-corpus.json");
        for (uint256 i; i < 292; ++i) {
            string memory base = string.concat(".codeCases[", vm.toString(i), "]");
            bool accepted = json.readBool(string.concat(base, ".accepted"));
            bytes memory input = json.readBytes(string.concat(base, ".bytes"));
            string memory errorName = json.readString(string.concat(base, ".error"));
            string memory id = json.readString(string.concat(base, ".id"));
            uint256 offset = json.readUint(string.concat(base, ".offset"));
            (bool success, bytes memory result) =
                address(harness).staticcall(abi.encodeCall(SwapVMStage6D1Harness.validateCode, (input)));
            assertEq(success, accepted, id);
            if (success) {
                assertEq(result.length >= 64, true, id);
            } else {
                assertEq(_selector(result), _errorSelector(errorName), id);
                if (_selector(result) == SwapVMMiniVM.UnknownOpcode.selector) {
                    (, uint256 pc) = _decodeTwoWords(result);
                    assertEq(pc, offset, id);
                } else if (_selector(result) == SwapVMMiniVM.TruncatedImmediate.selector) {
                    (uint256 pc,) = _decodeTwoWords(result);
                    assertEq(pc, offset, id);
                }
            }
        }
    }

    function test_stage6D1_packageDifferentialCorpus() public view {
        string memory json = vm.readFile("tooling/tinysol/fixtures/differential-corpus.json");
        for (uint256 i; i < 12; ++i) {
            string memory base = string.concat(".packageCases[", vm.toString(i), "]");
            bool accepted = json.readBool(string.concat(base, ".accepted"));
            bytes memory input = json.readBytes(string.concat(base, ".bytes"));
            string memory errorName = json.readString(string.concat(base, ".error"));
            string memory id = json.readString(string.concat(base, ".id"));
            (bool success, bytes memory result) =
                address(harness).staticcall(abi.encodeCall(SwapVMStage6D1Harness.decodePackage, (input)));
            assertEq(success, accepted, id);
            if (!success) assertEq(_selector(result), _errorSelector(errorName), id);
        }
    }

    function test_stage6D1_referencePackageFieldsAndHashesMatchProductionDecoder() public view {
        _assertReference("SRC20-v1");
        _assertReference("SRC721-v1");
        _assertReference("SRC1155-v1");
        _assertReference("CPAMM-v1");
    }

    function test_stage6D1_jumpdestBitmapExcludesPushImmediate() public view {
        bytes memory bitmap = harness.validateCode(hex"615b005b00");
        assertEq(bitmap, hex"0000000100");
    }

    function test_stage6D1_staticForbiddenSetMatchesFrozenIsa() public view {
        _assertStaticViolation(hex"55");
        _assertStaticViolation(hex"a0");
        _assertStaticViolation(hex"a1");
        _assertStaticViolation(hex"a2");
        _assertStaticViolation(hex"a3");
        _assertStaticViolation(hex"a4");
        _assertStaticViolation(hex"f0");

        // An allowed opcode may fail for another runtime reason (here stack underflow),
        // but it must not be classified as a static-mode violation.
        (bool success, bytes memory result) =
            address(harness).staticcall(abi.encodeCall(SwapVMStage6D1Harness.runStatic, (hex"54")));
        assertFalse(success);
        assertNotEq(_selector(result), SwapVMMiniVM.StaticViolation.selector);
    }

    function _assertStaticViolation(bytes memory code) private view {
        (bool success, bytes memory result) =
            address(harness).staticcall(abi.encodeCall(SwapVMStage6D1Harness.runStatic, (code)));
        assertFalse(success);
        assertEq(_selector(result), SwapVMMiniVM.StaticViolation.selector);
    }

    function _assertReference(string memory name) private view {
        string memory json = vm.readFile(string.concat("reference/", name, ".json"));
        bytes memory packageBytes = json.readBytes(".package");
        bytes memory expectedCode = json.readBytes(".code");
        uint16 expectedConstructor = uint16(json.readUint(".constructorEntry"));
        uint16 expectedRuntime = uint16(json.readUint(".runtimeEntry"));
        bytes32 expectedAbiHash = json.readBytes32(".abiHash");
        bytes32 expectedCodeHash = json.readBytes32(".codeHash");
        (uint16 constructorEntry, uint16 runtimeEntry, bytes32 abiHash, bytes memory code) =
            harness.decodePackage(packageBytes);
        assertEq(constructorEntry, expectedConstructor, name);
        assertEq(runtimeEntry, expectedRuntime, name);
        assertEq(abiHash, expectedAbiHash, name);
        assertEq(code, expectedCode, name);
        assertEq(keccak256(packageBytes), expectedCodeHash, name);
    }

    function _selector(bytes memory data) private pure returns (bytes4 selector) {
        if (data.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            selector := mload(add(data, 0x20))
        }
    }

    function _decodeTwoWords(bytes memory data) private pure returns (uint256 first, uint256 second) {
        assembly ("memory-safe") {
            first := mload(add(data, 0x24))
            second := mload(add(data, 0x44))
        }
    }

    function _errorSelector(string memory name) private pure returns (bytes4) {
        bytes32 value = keccak256(bytes(name));
        if (value == keccak256("EmptyCode")) return SwapVMMiniVM.EmptyCode.selector;
        if (value == keccak256("CodeTooLarge")) return SwapVMMiniVM.CodeTooLarge.selector;
        if (value == keccak256("UnknownOpcode")) return SwapVMMiniVM.UnknownOpcode.selector;
        if (value == keccak256("TruncatedImmediate")) return SwapVMMiniVM.TruncatedImmediate.selector;
        if (value == keccak256("InvalidPackageLength")) return SwapVMMiniVM.InvalidPackageLength.selector;
        if (value == keccak256("InvalidPackageMagic")) return SwapVMMiniVM.InvalidPackageMagic.selector;
        if (value == keccak256("InvalidPackageVersion")) return SwapVMMiniVM.InvalidPackageVersion.selector;
        if (value == keccak256("InvalidPackageCodeLength")) return SwapVMMiniVM.InvalidPackageCodeLength.selector;
        if (value == keccak256("InvalidPackageEntry")) return SwapVMMiniVM.InvalidPackageEntry.selector;
        revert("unknown corpus error");
    }
}
