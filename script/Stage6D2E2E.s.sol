// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {SwapVMKernel} from "../src/SwapVMKernel.sol";
import {Stage6BKernelDriver} from "./Stage6BE2E.s.sol";

/// @notice Deterministic compiler-event flow for an ephemeral local Anvil only.
contract Stage6D2E2EScript is Script {
    using stdJson for string;

    uint128 private constant BYTE_GAS_PRICE = 1e12;
    uint32 private constant ACTION_LIMIT = 20_000;
    uint128 private constant ETH_AMOUNT_IN = 1 ether;
    uint160 private constant PRICE_LIMIT = 1;
    bytes32 private constant WORLD_ID = keccak256("SwapVM Stage6D2 compiler event world");

    uint256 private actorKey;
    address private actor;
    Stage6BKernelDriver private driver;
    SwapVMKernel private kernel;

    function setup() external {
        actorKey = vm.envUint("STAGE6D2_PRIVATE_KEY");
        actor = vm.addr(actorKey);
        vm.startBroadcast(actorKey);
        driver = new Stage6BKernelDriver(actor);
        kernel = new SwapVMKernel(address(driver), BYTE_GAS_PRICE);
        driver.bind(kernel);
        vm.stopBroadcast();
        console2.log("STAGE6D2_DRIVER", address(driver));
        console2.log("STAGE6D2_KERNEL", address(kernel));
        console2.logBytes32(WORLD_ID);
    }

    function branchA() external {
        _load();
        bytes32 actorId = kernel.eoaAccountId(actor);
        bytes32 recipient = kernel.eoaAccountId(address(0xBEEF));
        vm.startBroadcast(actorKey);
        bytes32 eventDemo = _deploy(_fixturePackage("EventDemo"), bytes(""));
        _call(eventDemo, abi.encodePacked(bytes4(keccak256("set(uint256,bool)")), abi.encode(uint256(55), true)));
        bytes32 token = _deploy(_fixturePackage("MiniToken"), abi.encode(uint256(1_000), actorId));
        _call(
            token, abi.encodePacked(bytes4(keccak256("transfer(bytes32,uint256)")), abi.encode(recipient, uint256(125)))
        );
        bytes32 nft = _deploy(_fixturePackage("MiniNFT"), abi.encode(bytes32(0)));
        _call(nft, abi.encodePacked(bytes4(keccak256("mint(bytes32,uint256)")), abi.encode(recipient, uint256(7))));
        vm.stopBroadcast();
    }

    function branchB() external {
        _load();
        vm.startBroadcast(actorKey);
        for (uint256 i; i < 6; ++i) {
            driver.executeNOP(WORLD_ID);
        }
        vm.stopBroadcast();
    }

    function _load() private {
        actorKey = vm.envUint("STAGE6D2_PRIVATE_KEY");
        actor = vm.addr(actorKey);
        driver = Stage6BKernelDriver(vm.envAddress("STAGE6D2_DRIVER"));
        kernel = SwapVMKernel(vm.envAddress("STAGE6D2_KERNEL"));
    }

    function _deploy(bytes memory packageBytes, bytes memory constructorInput) private returns (bytes32 contractId) {
        bytes32 actorId = kernel.eoaAccountId(actor);
        bytes32 codeHash = keccak256(packageBytes);
        contractId = kernel.contractAccountId(WORLD_ID, actorId, kernel.creatorNonce(WORLD_ID, actorId), codeHash);
        bytes memory payload = abi.encodePacked(bytes4(uint32(packageBytes.length)), packageBytes, constructorInput);
        driver.execute(_signed(SwapVMKernel.RootOp.DEPLOY, codeHash, payload));
    }

    function _call(bytes32 target, bytes memory payload) private {
        driver.execute(_signed(SwapVMKernel.RootOp.CALL, target, payload));
    }

    function _signed(SwapVMKernel.RootOp op, bytes32 target, bytes memory payload)
        private
        view
        returns (SwapVMKernel.VMEnvelope memory action)
    {
        bytes32 actorId = kernel.eoaAccountId(actor);
        action = SwapVMKernel.VMEnvelope({
            op: op,
            worldId: WORLD_ID,
            actor: actor,
            targetOrCodeHash: target,
            payload: payload,
            byteGasLimit: ACTION_LIMIT,
            minNetTokenOut: 0,
            nonce: kernel.nonces(WORLD_ID, actorId),
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
                ETH_AMOUNT_IN,
                PRICE_LIMIT,
                action.recipient,
                address(driver),
                action.authorizedExecutor,
                action.nonce,
                action.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", kernel.domainSeparator(WORLD_ID), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(actorKey, digest);
        action.signature = abi.encodePacked(r, s, v);
    }

    function _fixturePackage(string memory name) private view returns (bytes memory) {
        return vm.readFile(string.concat("tooling/tinysol/fixtures/compiler/", name, ".json")).readBytes(".package");
    }
}
