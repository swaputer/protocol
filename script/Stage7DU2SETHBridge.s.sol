// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {SwapVMKernel} from "../src/SwapVMKernel.sol";
import {SwapVMRouter} from "../src/SwapVMRouter.sol";
import {SwapVMSETHVault} from "../src/SwapVMSETHVault.sol";
import {SwapVMWorldFactory} from "../src/SwapVMWorldFactory.sol";

/// @notice Deploys and atomically exercises the experimental sETH bridge on the current Base Sepolia v1.2 World.
/// @dev Testnet-only, unaudited and deliberately capped to a tiny round-trip amount.
contract Stage7DU2SETHBridgeScript is Script {
    uint256 private constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    address private constant ACTOR = 0x590a77Ec892bB78206bcad2444B62d1bC31A2D03;

    SwapVMWorldFactory private constant FACTORY = SwapVMWorldFactory(0x25be74e0FaB494D7cF0e7d681a3897f9d82908c1);
    SwapVMRouter private constant ROUTER = SwapVMRouter(payable(0x6719Fa2876EBce93c32490905C53e05ac1Da0109));
    SwapVMKernel private constant KERNEL = SwapVMKernel(0xDEa4512A2D03bbeB19dF29429534dcdd299909D8);
    bytes32 private constant WORLD_ID = 0x34e0ee268b9ff628d76cf0213fbfd448c34d357ecf90bed536959669b6b53c9f;

    bytes32 private constant FACTORY_CODE_HASH = 0x4aac054fc350138e88c54d33e4bf701ac51ffdbff7e006a62102d246a429a8cd;
    bytes32 private constant ROUTER_CODE_HASH = 0xc61e52cf5c63f088a821699b97bf37ad3e5c9089db790fc74ce1464fa9fe2ed9;
    bytes32 private constant KERNEL_CODE_HASH = 0xaffb47ff4a99efbca993df417258b6048f491a8f5e043191f1eec4a5e5667e49;
    bytes32 private constant SETH_CODE_HASH = 0x5a88d8a65d8a00370ac13895f6fedfa82a88d5e360caaa325135e3b33fc6c872;

    uint128 private constant VM_INPUT = 0.000001 ether;
    uint128 private constant BRIDGE_AMOUNT = 0.00001 ether;
    uint32 private constant DEPLOY_LIMIT = 20_000;
    uint32 private constant SETH_LIMIT = 8_000;
    uint160 private constant SQRT_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint256 private constant MAX_NET_OUTFLOW = 0.01 ether;

    uint256 private actorKey;
    uint256 private startBalance;
    bytes32 private actorId;
    bytes32 private seth;
    SwapVMSETHVault private vault;

    function run() external {
        _validateEnvironment();
        _deploySETHAndVault();
        _exerciseAtomicRoundTrip();
        _validateFinalState();
        _logResult();
    }

    function _validateEnvironment() private {
        require(block.chainid == BASE_SEPOLIA_CHAIN_ID, "BASE_SEPOLIA_ONLY");
        actorKey = vm.envUint("STAGE7A2_PRIVATE_KEY");
        require(vm.addr(actorKey) == ACTOR, "ACTOR_MISMATCH");
        require(address(FACTORY).codehash == FACTORY_CODE_HASH, "FACTORY_CODE_HASH");
        require(address(ROUTER).codehash == ROUTER_CODE_HASH, "ROUTER_CODE_HASH");
        require(address(KERNEL).codehash == KERNEL_CODE_HASH, "KERNEL_CODE_HASH");
        require(FACTORY.router() == address(ROUTER), "FACTORY_ROUTER");
        SwapVMWorldFactory.WorldConfig memory config = FACTORY.getWorldConfig(WORLD_ID);
        require(config.isSealed, "WORLD_NOT_SEALED");
        require(config.kernel == address(KERNEL), "WORLD_KERNEL");
        startBalance = ACTOR.balance;
        require(startBalance >= MAX_NET_OUTFLOW, "INSUFFICIENT_TEST_ETH");
        actorId = KERNEL.eoaAccountId(ACTOR);
    }

    function _deploySETHAndVault() private {
        bytes memory packageBytes = vm.readFileBinary("tooling/tinysol/programs/seth/SETH.svm");
        require(keccak256(packageBytes) == SETH_CODE_HASH, "SETH_ARTIFACT_HASH");

        uint64 creatorNonce = KERNEL.creatorNonce(WORLD_ID, actorId);
        seth = KERNEL.contractAccountId(WORLD_ID, actorId, creatorNonce, SETH_CODE_HASH);
        require(KERNEL.programCodeHash(WORLD_ID, seth) != SETH_CODE_HASH, "SETH_ALREADY_DEPLOYED");

        // The Router deployment consumes the actor's current EVM nonce; the following CREATE uses nonce + 1.
        address predictedVault = vm.computeCreateAddress(ACTOR, vm.getNonce(ACTOR) + 1);
        bytes memory deployPayload =
            abi.encodePacked(bytes4(uint32(packageBytes.length)), packageBytes, abi.encode(predictedVault));
        SwapVMKernel.VMEnvelope memory deploy = _signedEnvelope(
            SwapVMKernel.RootOp.DEPLOY,
            SETH_CODE_HASH,
            deployPayload,
            DEPLOY_LIMIT,
            ACTOR,
            ACTOR,
            KERNEL.nonces(WORLD_ID, actorId)
        );

        vm.startBroadcast(actorKey);
        ROUTER.buyVMExactInput{value: VM_INPUT}(WORLD_ID, SQRT_PRICE_LIMIT, deploy);
        vm.stopBroadcast();

        require(KERNEL.programCodeHash(WORLD_ID, seth) == SETH_CODE_HASH, "SETH_DEPLOYMENT");
        vm.startBroadcast(actorKey);
        vault = new SwapVMSETHVault(ROUTER, WORLD_ID, seth, SETH_CODE_HASH);
        vm.stopBroadcast();
        require(address(vault) == predictedVault, "VAULT_PREDICTION");
        require(_queryAddress("vault()") == address(vault), "SETH_VAULT_BINDING");
    }

    function _exerciseAtomicRoundTrip() private {
        uint64 nonce = KERNEL.nonces(WORLD_ID, actorId);
        bytes memory mintPayload =
            abi.encodePacked(bytes4(keccak256("bridgeMint(bytes32,uint256)")), abi.encode(actorId, BRIDGE_AMOUNT));
        SwapVMKernel.VMEnvelope memory mint =
            _signedEnvelope(SwapVMKernel.RootOp.CALL, seth, mintPayload, SETH_LIMIT, ACTOR, address(vault), nonce);

        vm.startBroadcast(actorKey);
        vault.deposit{value: BRIDGE_AMOUNT + VM_INPUT}(BRIDGE_AMOUNT, VM_INPUT, mint, SQRT_PRICE_LIMIT);
        vm.stopBroadcast();
        require(KERNEL.nonces(WORLD_ID, actorId) == nonce + 1, "DEPOSIT_NONCE");
        require(_balanceOf(actorId) == BRIDGE_AMOUNT, "DEPOSIT_BALANCE");
        require(vault.totalSupply() == BRIDGE_AMOUNT, "DEPOSIT_SUPPLY");
        require(vault.lockedEth() == BRIDGE_AMOUNT, "DEPOSIT_LIABILITY");
        require(address(vault).balance == BRIDGE_AMOUNT, "DEPOSIT_BACKING");
        require(vault.isSolvent(), "DEPOSIT_SOLVENCY");

        bytes memory burnPayload = abi.encodePacked(bytes4(keccak256("bridgeBurn(uint256)")), abi.encode(BRIDGE_AMOUNT));
        SwapVMKernel.VMEnvelope memory burn =
            _signedEnvelope(SwapVMKernel.RootOp.CALL, seth, burnPayload, SETH_LIMIT, ACTOR, address(vault), nonce + 1);

        vm.startBroadcast(actorKey);
        vault.redeem{value: VM_INPUT}(BRIDGE_AMOUNT, VM_INPUT, ACTOR, burn, SQRT_PRICE_LIMIT);
        vm.stopBroadcast();
        require(KERNEL.nonces(WORLD_ID, actorId) == nonce + 2, "REDEEM_NONCE");
    }

    function _signedEnvelope(
        SwapVMKernel.RootOp op,
        bytes32 target,
        bytes memory payload,
        uint32 byteLimit,
        address recipient,
        address executor,
        uint64 nonce
    ) private view returns (SwapVMKernel.VMEnvelope memory envelope) {
        envelope = SwapVMKernel.VMEnvelope({
            op: op,
            worldId: WORLD_ID,
            actor: ACTOR,
            targetOrCodeHash: target,
            payload: payload,
            byteGasLimit: byteLimit,
            minNetTokenOut: 1,
            nonce: nonce,
            deadline: uint64(block.timestamp + 1 days),
            recipient: recipient,
            authorizedExecutor: executor,
            signature: bytes("")
        });
        bytes32 structHash = keccak256(
            abi.encode(
                KERNEL.VM_ACTION_TYPEHASH(),
                uint8(envelope.op),
                envelope.worldId,
                envelope.actor,
                envelope.targetOrCodeHash,
                keccak256(envelope.payload),
                envelope.byteGasLimit,
                envelope.minNetTokenOut,
                VM_INPUT,
                SQRT_PRICE_LIMIT,
                envelope.recipient,
                address(ROUTER),
                envelope.authorizedExecutor,
                envelope.nonce,
                envelope.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", KERNEL.domainSeparator(WORLD_ID), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(actorKey, digest);
        envelope.signature = abi.encodePacked(r, s, v);
    }

    function _balanceOf(bytes32 owner) private view returns (uint256 amount) {
        (bytes memory output,) = KERNEL.staticCall(
            WORLD_ID, seth, abi.encodePacked(bytes4(keccak256("balanceOf(bytes32)")), abi.encode(owner)), 2_000
        );
        require(output.length == 32, "BALANCE_WIDTH");
        amount = abi.decode(output, (uint256));
    }

    function _queryAddress(string memory signature) private view returns (address value) {
        (bytes memory output,) =
            KERNEL.staticCall(WORLD_ID, seth, abi.encodePacked(bytes4(keccak256(bytes(signature)))), 2_000);
        require(output.length == 32, "ADDRESS_WIDTH");
        value = address(uint160(abi.decode(output, (uint256))));
    }

    function _validateFinalState() private view {
        require(_balanceOf(actorId) == 0, "FINAL_BALANCE");
        require(vault.totalSupply() == 0, "FINAL_SUPPLY");
        require(vault.lockedEth() == 0, "FINAL_LIABILITY");
        require(address(vault).balance == 0, "FINAL_BACKING");
        require(vault.backingSurplus() == 0, "FINAL_SURPLUS");
        require(vault.isSolvent(), "FINAL_SOLVENCY");
        if (ACTOR.balance < startBalance) require(startBalance - ACTOR.balance <= MAX_NET_OUTFLOW, "OUTFLOW_CAP");
    }

    function _logResult() private view {
        console2.log("SETH_BRIDGE_UNAUDITED_EXPERIMENTAL", true);
        console2.log("SETH_BRIDGE_WORLD_ID");
        console2.logBytes32(WORLD_ID);
        console2.log("SETH_BRIDGE_PROGRAM_ID");
        console2.logBytes32(seth);
        console2.log("SETH_BRIDGE_CODE_HASH");
        console2.logBytes32(SETH_CODE_HASH);
        console2.log("SETH_BRIDGE_VAULT", address(vault));
        console2.log("SETH_BRIDGE_FINAL_SOLVENT", vault.isSolvent());
        console2.log("SETH_BRIDGE_ACTOR_BALANCE_WEI", ACTOR.balance);
    }
}
