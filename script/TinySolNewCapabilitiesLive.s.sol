// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {SwapVMKernel} from "../src/SwapVMKernel.sol";
import {SwapVMRouter} from "../src/SwapVMRouter.sol";

contract TinySolNewCapabilitiesLiveScript is Script {
    uint256 private constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    uint160 private constant SQRT_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint128 private constant VM_ETH_IN = 1_000_000_000_000;
    uint32 private constant ACTION_LIMIT = 8_000;

    SwapVMRouter private router;
    SwapVMKernel private kernel;
    bytes32 private worldId;
    address private actor;
    uint256 private actorKey;
    uint64 private nonce;

    function run() external {
        require(block.chainid == BASE_SEPOLIA_CHAIN_ID, "BASE_SEPOLIA_ONLY");
        actorKey = vm.envUint("STAGE7A2_PRIVATE_KEY");
        actor = vm.addr(actorKey);
        router = SwapVMRouter(payable(vm.envAddress("SVM_ROUTER_ADDRESS")));
        kernel = SwapVMKernel(vm.envAddress("SVM_KERNEL_ADDRESS"));
        worldId = vm.envBytes32("SVM_WORLD_ID");

        bytes memory packageBytes = vm.envBytes("TINYSOL_NEW_CAPABILITIES_PACKAGE");
        bytes32 codeHash = keccak256(packageBytes);
        bytes32 actorId = kernel.eoaAccountId(actor);
        uint64 creatorNonce = kernel.creatorNonce(worldId, actorId);
        bytes32 programId = kernel.contractAccountId(worldId, actorId, creatorNonce, codeHash);
        nonce = kernel.nonces(worldId, actorId);

        bytes memory deployPayload = abi.encodePacked(bytes4(uint32(packageBytes.length)), packageBytes);
        _broadcast(SwapVMKernel.RootOp.DEPLOY, codeHash, deployPayload);
        require(kernel.programCodeHash(worldId, programId) == codeHash, "DEPLOY_HASH_MISMATCH");

        _broadcast(SwapVMKernel.RootOp.CALL, programId, abi.encodePacked(bytes4(keccak256("write()"))));
        (bytes memory output,) =
            kernel.staticCall(worldId, programId, abi.encodePacked(bytes4(keccak256("read()"))), ACTION_LIMIT);
        bytes memory expected = bytes.concat(
            abi.encode(uint256(6), uint256(228), uint256(189), uint256(160), uint256(229), uint256(165), uint256(189)),
            abi.encode(uint256(3), uint256(97), uint256(98), uint256(99)),
            abi.encode(uint256(3), uint256(7), uint256(0), uint256(11)),
            abi.encode(uint256(4), uint256(116), uint256(105), uint256(110), uint256(121)),
            abi.encode(uint256(2), uint256(120), uint256(121)),
            abi.encode(uint256(1), uint256(5)),
            abi.encode(uint256(2), uint256(111), uint256(107))
        );
        require(keccak256(output) == keccak256(expected), "BOUNDED_OUTPUT_MISMATCH");

        console2.log("TINYSOL_NEW_CAPABILITIES_PROGRAM_ID");
        console2.logBytes32(programId);
        console2.log("TINYSOL_NEW_CAPABILITIES_CODE_HASH");
        console2.logBytes32(codeHash);
        console2.log("TINYSOL_NEW_CAPABILITIES_OUTPUT_BYTES", output.length);
    }

    function _broadcast(SwapVMKernel.RootOp op, bytes32 target, bytes memory payload) private {
        SwapVMKernel.VMEnvelope memory action = SwapVMKernel.VMEnvelope({
            op: op,
            worldId: worldId,
            actor: actor,
            targetOrCodeHash: target,
            payload: payload,
            byteGasLimit: ACTION_LIMIT,
            minNetTokenOut: 1,
            nonce: nonce++,
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

        vm.startBroadcast(actorKey);
        router.buyVMExactInputWithResult{value: VM_ETH_IN}(worldId, SQRT_PRICE_LIMIT, action);
        vm.stopBroadcast();
    }
}
