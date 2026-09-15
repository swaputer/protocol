// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {SwaputerKernel} from "../src/SwaputerKernel.sol";
import {SwaputerAppRouter} from "../src/SwaputerAppRouter.sol";
import {SwapVMSETHVault} from "../src/SwapVMSETHVault.sol";
import {SwaputerWorldFactory} from "../src/SwaputerWorldFactory.sol";

/// @notice Deploys and atomically exercises the sETH bridge on the Base Sepolia Events World.
contract EventsBaseSepoliaSETHBridgeScript is Script {
    uint256 private constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    address private constant DEFAULT_ACTOR = 0x590a77Ec892bB78206bcad2444B62d1bC31A2D03;

    bytes32 private constant SETH_CODE_HASH = 0x0ba319925e010cc61d6af3c0ef5dc9edb3bcfa1f6588e4ded86e744dbd3fc162;

    uint128 private constant VM_INPUT = 0.000001 ether;
    uint128 private constant BRIDGE_AMOUNT = 0.00001 ether;
    uint32 private constant DEPLOY_LIMIT = 20_000;
    uint32 private constant SETH_LIMIT = 8_000;
    uint160 private constant SQRT_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint256 private constant MAX_NET_OUTFLOW = 0.01 ether;

    uint256 private actorKey;
    address private actor;
    uint256 private startBalance;
    SwaputerWorldFactory private factory;
    SwaputerAppRouter private router;
    SwaputerKernel private kernel;
    bytes32 private worldId;
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
        actor = vm.envOr("STAGE7A2_ACTOR", DEFAULT_ACTOR);
        require(vm.addr(actorKey) == actor, "ACTOR_MISMATCH");
        factory = SwaputerWorldFactory(vm.envAddress("SVM_FACTORY_ADDRESS"));
        router = SwaputerAppRouter(payable(vm.envAddress("SVM_ROUTER_ADDRESS")));
        kernel = SwaputerKernel(vm.envAddress("SVM_KERNEL_ADDRESS"));
        worldId = vm.envBytes32("SVM_WORLD_ID");
        require(address(factory).code.length != 0, "FACTORY_NOT_DEPLOYED");
        require(address(router).code.length != 0, "ROUTER_NOT_DEPLOYED");
        require(address(kernel).code.length != 0, "KERNEL_NOT_DEPLOYED");
        require(factory.router() == address(router), "FACTORY_ROUTER");
        SwaputerWorldFactory.WorldConfig memory config = factory.getWorldConfig(worldId);
        require(config.isSealed, "WORLD_NOT_SEALED");
        require(config.kernel == address(kernel), "WORLD_KERNEL");
        startBalance = actor.balance;
        require(startBalance >= MAX_NET_OUTFLOW, "INSUFFICIENT_TEST_ETH");
        actorId = kernel.eoaAccountId(actor);
    }

    function _deploySETHAndVault() private {
        bytes memory packageBytes = vm.readFileBinary("tooling/tinysol/programs/seth/SETH.svm");
        require(keccak256(packageBytes) == SETH_CODE_HASH, "SETH_ARTIFACT_HASH");

        uint64 creatorNonce = kernel.creatorNonce(worldId, actorId);
        seth = kernel.contractAccountId(worldId, actorId, creatorNonce, SETH_CODE_HASH);
        require(kernel.programCodeHash(worldId, seth) != SETH_CODE_HASH, "SETH_ALREADY_DEPLOYED");

        // The Router deployment consumes the actor's current EVM nonce; the following CREATE uses nonce + 1.
        address predictedVault = vm.computeCreateAddress(actor, vm.getNonce(actor) + 1);
        bytes memory deployPayload =
            abi.encodePacked(bytes4(uint32(packageBytes.length)), packageBytes, abi.encode(predictedVault));
        SwaputerKernel.VMEnvelope memory deploy = _signedEnvelope(
            SwaputerKernel.RootOp.DEPLOY,
            SETH_CODE_HASH,
            deployPayload,
            DEPLOY_LIMIT,
            actor,
            actor,
            kernel.nonces(worldId, actorId)
        );

        vm.startBroadcast(actorKey);
        router.buyVMExactInput{value: VM_INPUT}(worldId, SQRT_PRICE_LIMIT, deploy);
        vm.stopBroadcast();

        require(kernel.programCodeHash(worldId, seth) == SETH_CODE_HASH, "SETH_DEPLOYMENT");
        vm.startBroadcast(actorKey);
        vault = new SwapVMSETHVault(router, worldId, seth, SETH_CODE_HASH);
        vm.stopBroadcast();
        require(address(vault) == predictedVault, "VAULT_PREDICTION");
        require(_queryAddress("vault()") == address(vault), "SETH_VAULT_BINDING");
    }

    function _exerciseAtomicRoundTrip() private {
        uint64 nonce = kernel.nonces(worldId, actorId);
        bytes memory mintPayload =
            abi.encodePacked(bytes4(keccak256("bridgeMint(bytes32,uint256)")), abi.encode(actorId, BRIDGE_AMOUNT));
        SwaputerKernel.VMEnvelope memory mint =
            _signedEnvelope(SwaputerKernel.RootOp.CALL, seth, mintPayload, SETH_LIMIT, actor, address(vault), nonce);

        vm.startBroadcast(actorKey);
        vault.deposit{value: BRIDGE_AMOUNT + VM_INPUT}(BRIDGE_AMOUNT, VM_INPUT, mint, SQRT_PRICE_LIMIT);
        vm.stopBroadcast();
        require(kernel.nonces(worldId, actorId) == nonce + 1, "DEPOSIT_NONCE");
        require(_balanceOf(actorId) == BRIDGE_AMOUNT, "DEPOSIT_BALANCE");
        require(vault.totalSupply() == BRIDGE_AMOUNT, "DEPOSIT_SUPPLY");
        require(vault.lockedEth() == BRIDGE_AMOUNT, "DEPOSIT_LIABILITY");
        require(address(vault).balance == BRIDGE_AMOUNT, "DEPOSIT_BACKING");
        require(vault.isSolvent(), "DEPOSIT_SOLVENCY");

        bytes memory burnPayload = abi.encodePacked(bytes4(keccak256("bridgeBurn(uint256)")), abi.encode(BRIDGE_AMOUNT));
        SwaputerKernel.VMEnvelope memory burn = _signedEnvelope(
            SwaputerKernel.RootOp.CALL, seth, burnPayload, SETH_LIMIT, actor, address(vault), nonce + 1
        );

        vm.startBroadcast(actorKey);
        vault.redeem{value: VM_INPUT}(BRIDGE_AMOUNT, VM_INPUT, actor, burn, SQRT_PRICE_LIMIT);
        vm.stopBroadcast();
        require(kernel.nonces(worldId, actorId) == nonce + 2, "REDEEM_NONCE");
    }

    function _signedEnvelope(
        SwaputerKernel.RootOp op,
        bytes32 target,
        bytes memory payload,
        uint32 byteLimit,
        address recipient,
        address executor,
        uint64 nonce
    ) private view returns (SwaputerKernel.VMEnvelope memory envelope) {
        envelope = SwaputerKernel.VMEnvelope({
            op: op,
            worldId: worldId,
            actor: actor,
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
                kernel.VM_ACTION_TYPEHASH(),
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
                address(router),
                envelope.authorizedExecutor,
                envelope.nonce,
                envelope.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", kernel.domainSeparator(worldId), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(actorKey, digest);
        envelope.signature = abi.encodePacked(r, s, v);
    }

    function _balanceOf(bytes32 owner) private view returns (uint256 amount) {
        (bytes memory output,) = kernel.staticCall(
            worldId, seth, abi.encodePacked(bytes4(keccak256("balanceOf(bytes32)")), abi.encode(owner)), 2_000
        );
        require(output.length == 32, "BALANCE_WIDTH");
        amount = abi.decode(output, (uint256));
    }

    function _queryAddress(string memory signature) private view returns (address value) {
        (bytes memory output,) =
            kernel.staticCall(worldId, seth, abi.encodePacked(bytes4(keccak256(bytes(signature)))), 2_000);
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
        if (actor.balance < startBalance) require(startBalance - actor.balance <= MAX_NET_OUTFLOW, "OUTFLOW_CAP");
    }

    function _logResult() private view {
        console2.log("EVENTS_SETH_BRIDGE_WORLD_ID");
        console2.logBytes32(worldId);
        console2.log("EVENTS_SETH_BRIDGE_PROGRAM_ID");
        console2.logBytes32(seth);
        console2.log("EVENTS_SETH_BRIDGE_CODE_HASH");
        console2.logBytes32(SETH_CODE_HASH);
        console2.log("EVENTS_SETH_BRIDGE_VAULT", address(vault));
        console2.log("EVENTS_SETH_BRIDGE_FINAL_SOLVENT", vault.isSolvent());
        console2.log("EVENTS_SETH_BRIDGE_ACTOR_BALANCE_WEI", actor.balance);
    }
}
