// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {SwaputerKernel} from "../src/SwaputerKernel.sol";
import {SwaputerAppRouter} from "../src/SwaputerAppRouter.sol";

/// @notice Compares the TypeScript MiniVM corpus with the active Base Sepolia SVM world.
contract Stage7LiveTinySolDifferentialScript is Script {
    using stdJson for string;

    uint256 private constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    uint160 private constant SQRT_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint128 private constant VM_ETH_IN = 1_000_000_000_000; // 0.000001 ETH
    uint32 private constant ACTION_LIMIT = 2_000;

    uint256 private constant DEPLOY_CASE = 28;
    uint256 private constant ARITHMETIC_CASE = 29;
    uint256 private constant CONTROL_FLOW_CASE = 30;
    uint256 private constant INTERNAL_CALL_CASE = 31;
    uint256 private constant ABI_EVENT_CASE = 32;
    uint256 private constant REVERT_CASE = 33;
    uint256 private constant ARITHMETIC_SMALL_CASE = 34;
    uint256 private constant ARITHMETIC_BALANCED_CASE = 35;
    uint256 private constant ARITHMETIC_LARGE_CASE = 36;
    uint256 private constant ABI_INVALID_BOOL_CASE = 45;
    uint256 private constant ABI_INVALID_ADDRESS_CASE = 46;
    uint256 private constant ABI_SHORT_CALLDATA_CASE = 47;
    uint256 private constant ABI_EXTRA_CALLDATA_CASE = 48;
    uint256 private constant ABI_UNKNOWN_SELECTOR_CASE = 49;

    address private constant DEFAULT_ACTOR = 0x590a77Ec892bB78206bcad2444B62d1bC31A2D03;
    address private constant RECIPIENT = 0x000000000000000000000000000000000000bEEF;
    bytes32 private constant NOTE = bytes32("TinySol ABI conformance");

    SwaputerAppRouter private router;
    SwaputerKernel private kernel;
    bytes32 private worldId;
    address private actor;
    uint256 private actorKey;
    uint64 private actionNonce;
    string private corpus;

    function run() external {
        require(block.chainid == BASE_SEPOLIA_CHAIN_ID, "BASE_SEPOLIA_ONLY");
        actorKey = vm.envUint("STAGE7A2_PRIVATE_KEY");
        actor = vm.envOr("STAGE7A2_ACTOR", DEFAULT_ACTOR);
        require(vm.addr(actorKey) == actor, "ACTOR_MISMATCH");

        router = SwaputerAppRouter(payable(vm.envAddress("SVM_ROUTER_ADDRESS")));
        kernel = SwaputerKernel(vm.envAddress("SVM_KERNEL_ADDRESS"));
        worldId = vm.envBytes32("SVM_WORLD_ID");
        corpus = vm.readFile("tooling/tinysol/fixtures/simulator-solidity-differential.json");
        string memory compilerFixture = vm.readFile("tooling/tinysol/fixtures/compiler/Conformance.json");

        bytes memory packageBytes = compilerFixture.readBytes(".package");
        bytes32 codeHash = compilerFixture.readBytes32(".codeHash");
        require(keccak256(packageBytes) == codeHash, "COMPILER_PACKAGE_HASH");
        require(codeHash == _expectedCodeHash(), "MODEL_PACKAGE_HASH");

        bytes32 actorId = kernel.eoaAccountId(actor);
        uint64 creatorNonceBefore = kernel.creatorNonce(worldId, actorId);
        bytes32 contractId = kernel.contractAccountId(worldId, actorId, creatorNonceBefore, codeHash);
        actionNonce = kernel.nonces(worldId, actorId);
        uint64 heightBefore = kernel.executionHeight(worldId);

        bytes memory deployPayload =
            abi.encodePacked(bytes4(uint32(packageBytes.length)), packageBytes, abi.encode(uint256(5)));
        _execute(SwaputerKernel.RootOp.DEPLOY, codeHash, deployPayload, DEPLOY_CASE);
        require(kernel.programCodeHash(worldId, contractId) == codeHash, "DEPLOYED_CODE_HASH");
        require(kernel.creatorNonce(worldId, actorId) == creatorNonceBefore + 1, "CREATOR_NONCE");
        require(_queryUint(contractId, "getScalar()", bytes("")) == 5, "CONSTRUCTOR_SCALAR");
        require(_queryUint(contractId, "balanceOf(bytes32)", abi.encode(actorId)) == 6, "CONSTRUCTOR_MAPPING");

        _assertStatic(
            contractId,
            abi.encodePacked(bytes4(keccak256("arithmetic(uint256,uint256)")), abi.encode(uint256(9), uint256(4))),
            ARITHMETIC_CASE
        );
        _assertStatic(
            contractId,
            abi.encodePacked(bytes4(keccak256("arithmetic(uint256,uint256)")), abi.encode(uint256(1), uint256(0))),
            ARITHMETIC_SMALL_CASE
        );
        _assertStatic(
            contractId,
            abi.encodePacked(bytes4(keccak256("arithmetic(uint256,uint256)")), abi.encode(uint256(2), uint256(3))),
            ARITHMETIC_BALANCED_CASE
        );
        _assertStatic(
            contractId,
            abi.encodePacked(
                bytes4(keccak256("arithmetic(uint256,uint256)")),
                abi.encode(uint256(1_000_000_000_000_000_000), uint256(2_000_000_000_000_000_000))
            ),
            ARITHMETIC_LARGE_CASE
        );

        _execute(
            SwaputerKernel.RootOp.CALL,
            contractId,
            abi.encodePacked(bytes4(keccak256("controlFlow(uint256,bool)")), abi.encode(uint256(4), true)),
            CONTROL_FLOW_CASE
        );
        require(_queryUint(contractId, "getScalar()", bytes("")) == 14, "CONTROL_STORAGE");

        _execute(
            SwaputerKernel.RootOp.CALL,
            contractId,
            abi.encodePacked(bytes4(keccak256("internalCall(uint256)")), abi.encode(uint256(12))),
            INTERNAL_CALL_CASE
        );
        require(_queryUint(contractId, "getScalar()", bytes("")) == 19, "INTERNAL_STORAGE");

        bytes memory abiArguments = abi.encode(actorId, RECIPIENT, NOTE, true, uint256(73));
        _execute(
            SwaputerKernel.RootOp.CALL,
            contractId,
            abi.encodePacked(bytes4(keccak256("abiRoundTrip(bytes32,address,bytes32,bool,uint256)")), abiArguments),
            ABI_EVENT_CASE
        );
        require(_queryUint(contractId, "balanceOf(bytes32)", abi.encode(actorId)) == 73, "ABI_STORAGE");

        _assertRevertRollback(contractId, actorId);
        _assertAbiCanonicalization(contractId, actorId);
        require(kernel.executionHeight(worldId) == heightBefore + 4, "EXECUTION_HEIGHT");
        require(kernel.nonces(worldId, actorId) == actionNonce, "ACTION_NONCE");

        console2.log("TINYSOL_DIFFERENTIAL_WORLD_ID");
        console2.logBytes32(worldId);
        console2.log("TINYSOL_DIFFERENTIAL_CODE_HASH");
        console2.logBytes32(codeHash);
        console2.log("TINYSOL_DIFFERENTIAL_CONTRACT_ID");
        console2.logBytes32(contractId);
        console2.log("TINYSOL_DIFFERENTIAL_CASES", uint256(14));
        console2.log("TINYSOL_DIFFERENTIAL_LOCAL_MATRIX_CASES", corpus.readUint(".conformanceMatrix.caseCount"));
        console2.log("TINYSOL_DIFFERENTIAL_CHAIN_EXECUTIONS", uint256(4));
    }

    function _execute(SwaputerKernel.RootOp op, bytes32 target, bytes memory payload, uint256 caseIndex) private {
        SwaputerKernel.VMEnvelope memory action = _signedAction(op, target, payload, actionNonce++);
        vm.startBroadcast(actorKey);
        (, bytes32 outputWord, uint32 outputLength) =
            router.buyVMExactInputWithResult{value: VM_ETH_IN}(worldId, SQRT_PRICE_LIMIT, action);
        vm.stopBroadcast();

        bytes memory expectedOutput = _expectedBytes(caseIndex, "output");
        require(outputLength == expectedOutput.length, "OUTPUT_LENGTH");
        require(outputWord == _resultWord(expectedOutput), "OUTPUT_WORD");
        require(kernel.executedBytes(worldId) == _expectedExecutedBytes(caseIndex), "EXECUTED_BYTES");
    }

    function _assertStatic(bytes32 contractId, bytes memory payload, uint256 caseIndex) private view {
        (bytes memory output, uint32 executedBytes) = kernel.staticCall(worldId, contractId, payload, ACTION_LIMIT);
        require(keccak256(output) == keccak256(_expectedBytes(caseIndex, "output")), "STATIC_OUTPUT");
        require(executedBytes == _expectedExecutedBytes(caseIndex), "STATIC_EXECUTED_BYTES");
    }

    function _assertRevertRollback(bytes32 contractId, bytes32 actorId) private view {
        require(!corpus.readBool(_casePath(REVERT_CASE, "success")), "MODEL_REVERT_SUCCESS");
        require(
            keccak256(bytes(corpus.readString(_casePath(REVERT_CASE, "errorCode"))))
                == keccak256(bytes("EXPLICIT_REVERT")),
            "MODEL_REVERT_CODE"
        );
        uint256 balanceBefore = _queryUint(contractId, "balanceOf(bytes32)", abi.encode(actorId));
        bytes memory payload = abi.encodePacked(
            bytes4(keccak256("abiRoundTrip(bytes32,address,bytes32,bool,uint256)")),
            abi.encode(actorId, RECIPIENT, NOTE, false, uint256(91))
        );
        bool accepted;
        try kernel.staticCall(worldId, contractId, payload, ACTION_LIMIT) returns (bytes memory, uint32) {
            accepted = true;
        } catch {}
        require(!accepted, "REVERT_ACCEPTED");
        require(_queryUint(contractId, "balanceOf(bytes32)", abi.encode(actorId)) == balanceBefore, "REVERT_STORAGE");
    }

    function _assertAbiCanonicalization(bytes32 contractId, bytes32 actorId) private view {
        bytes4 selector = bytes4(keccak256("abiRoundTrip(bytes32,address,bytes32,bool,uint256)"));
        _assertExpectedRevert(
            contractId,
            abi.encodePacked(selector, abi.encode(actorId, RECIPIENT, NOTE, uint256(2), uint256(73))),
            ABI_INVALID_BOOL_CASE
        );
        _assertExpectedRevert(
            contractId,
            abi.encodePacked(selector, abi.encode(actorId, uint256(1) << 160, NOTE, true, uint256(73))),
            ABI_INVALID_ADDRESS_CASE
        );
        bytes memory canonical =
            abi.encodePacked(selector, abi.encode(bytes32(uint256(1)), address(0), bytes32(0), true, uint256(0)));
        bytes memory shortPayload = new bytes(canonical.length - 1);
        for (uint256 index; index < shortPayload.length; ++index) {
            shortPayload[index] = canonical[index];
        }
        _assertExpectedRevert(contractId, shortPayload, ABI_SHORT_CALLDATA_CASE);
        _assertExpectedRevert(contractId, bytes.concat(canonical, bytes32(0)), ABI_EXTRA_CALLDATA_CASE);
        _assertExpectedRevert(contractId, hex"deadbeef", ABI_UNKNOWN_SELECTOR_CASE);
    }

    function _assertExpectedRevert(bytes32 contractId, bytes memory payload, uint256 caseIndex) private view {
        require(!corpus.readBool(_casePath(caseIndex, "success")), "MODEL_EXPECTED_SUCCESS");
        require(
            keccak256(bytes(corpus.readString(_casePath(caseIndex, "errorCode"))))
                == keccak256(bytes("EXPLICIT_REVERT")),
            "MODEL_REVERT_CODE"
        );
        bool accepted;
        try kernel.staticCall(worldId, contractId, payload, ACTION_LIMIT) returns (bytes memory, uint32) {
            accepted = true;
        } catch {}
        require(!accepted, "INVALID_ABI_ACCEPTED");
    }

    function _signedAction(SwaputerKernel.RootOp op, bytes32 target, bytes memory payload, uint64 nonce)
        private
        view
        returns (SwaputerKernel.VMEnvelope memory action)
    {
        action = SwaputerKernel.VMEnvelope({
            op: op,
            worldId: worldId,
            actor: actor,
            targetOrCodeHash: target,
            payload: payload,
            byteGasLimit: ACTION_LIMIT,
            minNetTokenOut: 1,
            nonce: nonce,
            deadline: uint64(block.timestamp + 1 days),
            recipient: actor,
            authorizedExecutor: actor,
            signature: bytes("")
        });
        bytes32 structHash = keccak256(
            abi.encode(
                kernel.VM_ACTION_TYPEHASH(),
                uint8(action.op),
                action.worldId,
                action.actor,
                action.targetOrCodeHash,
                keccak256(action.payload),
                action.byteGasLimit,
                action.minNetTokenOut,
                VM_ETH_IN,
                SQRT_PRICE_LIMIT,
                action.recipient,
                address(router),
                action.authorizedExecutor,
                action.nonce,
                action.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", kernel.domainSeparator(worldId), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(actorKey, digest);
        action.signature = abi.encodePacked(r, s, v);
    }

    function _queryUint(bytes32 contractId, string memory signature, bytes memory arguments)
        private
        view
        returns (uint256 value)
    {
        (bytes memory output,) = kernel.staticCall(
            worldId, contractId, abi.encodePacked(bytes4(keccak256(bytes(signature))), arguments), ACTION_LIMIT
        );
        require(output.length == 32, "QUERY_WIDTH");
        value = abi.decode(output, (uint256));
    }

    function _expectedCodeHash() private view returns (bytes32) {
        return corpus.readBytes32(".cases[28].result.deploymentDiff[0].codeHash");
    }

    function _expectedExecutedBytes(uint256 caseIndex) private view returns (uint32) {
        return uint32(corpus.readUint(_casePath(caseIndex, "executedBytes")));
    }

    function _expectedBytes(uint256 caseIndex, string memory field) private view returns (bytes memory) {
        return corpus.readBytes(_casePath(caseIndex, field));
    }

    function _casePath(uint256 caseIndex, string memory field) private pure returns (string memory) {
        return string.concat(".cases[", vm.toString(caseIndex), "].result.", field);
    }

    function _resultWord(bytes memory output) private pure returns (bytes32 word) {
        if (output.length == 0) return bytes32(0);
        require(output.length <= 32, "MODEL_OUTPUT_TOO_LONG");
        assembly ("memory-safe") {
            word := mload(add(output, 0x20))
        }
    }
}
