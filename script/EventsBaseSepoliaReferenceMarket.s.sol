// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {SwapVMKernel} from "../src/SwapVMKernel.sol";
import {SwapVMRouter} from "../src/SwapVMRouter.sol";
import {SwapVMSRC20Market} from "../src/SwapVMSRC20Market.sol";
import {SwapVMWorldFactory} from "../src/SwapVMWorldFactory.sol";

/// @notice Deploys the hardened reference market for the canonical Base Sepolia demo SRC20.
/// @dev The exercise creates and cancels one escrowed sell order, proving token balance-delta
///      accounting without leaving application liabilities behind.
contract EventsBaseSepoliaReferenceMarketScript is Script {
    uint256 private constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    bytes32 private constant TOKEN_CODE_HASH = 0xaf15e40fe9fc1181a7143abb413562d69e1ab49a655209ac966204646c85c14b;
    bytes32 private constant ESCROW_CODE_HASH = 0x6da9921193ebfe79468ef74f5b94925b66bf8230e145234a77868f1e5a85614b;

    uint128 private constant VM_INPUT = 0.000001 ether;
    uint128 private constant ORDER_AMOUNT = 1 ether;
    uint128 private constant UNIT_PRICE = 0.00001 ether;
    uint32 private constant DEPLOY_LIMIT = 16_000;
    uint32 private constant TOKEN_LIMIT = 2_000;
    uint32 private constant ESCROW_LIMIT = 8_000;
    uint160 private constant SQRT_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;

    uint256 private actorKey;
    address private actor;
    bytes32 private actorId;
    bytes32 private escrow;
    bytes32 private token;
    bytes32 private worldId;
    SwapVMWorldFactory private factory;
    SwapVMRouter private router;
    SwapVMKernel private kernel;
    SwapVMSRC20Market private market;

    function run() external {
        _validateEnvironment();
        _deployEscrowAndMarket();
        _exerciseEscrowRoundTrip();
        _logResult();
    }

    function _validateEnvironment() private {
        require(block.chainid == BASE_SEPOLIA_CHAIN_ID, "BASE_SEPOLIA_ONLY");
        actorKey = vm.envUint("STAGE7A2_PRIVATE_KEY");
        actor = vm.envOr("STAGE7A2_ACTOR", vm.addr(actorKey));
        require(vm.addr(actorKey) == actor, "ACTOR_MISMATCH");
        factory = SwapVMWorldFactory(vm.envAddress("SVM_FACTORY_ADDRESS"));
        router = SwapVMRouter(payable(vm.envAddress("SVM_ROUTER_ADDRESS")));
        kernel = SwapVMKernel(vm.envAddress("SVM_KERNEL_ADDRESS"));
        worldId = vm.envBytes32("SVM_WORLD_ID");
        token = vm.envBytes32("SVM_DEFAULT_SRC20_ID");
        require(address(factory).code.length != 0, "FACTORY_NOT_DEPLOYED");
        require(address(router).code.length != 0, "ROUTER_NOT_DEPLOYED");
        require(address(kernel).code.length != 0, "KERNEL_NOT_DEPLOYED");
        require(factory.router() == address(router), "FACTORY_ROUTER");
        SwapVMWorldFactory.WorldConfig memory config = factory.getWorldConfig(worldId);
        require(config.isSealed && config.kernel == address(kernel), "WORLD_BINDING");
        require(kernel.programCodeHash(worldId, token) == TOKEN_CODE_HASH, "TOKEN_CODE_HASH");
        actorId = kernel.eoaAccountId(actor);
    }

    function _deployEscrowAndMarket() private {
        bytes memory packageBytes = vm.readFileBinary("tooling/tinysol/programs/market-escrow/MarketEscrow.svm");
        require(keccak256(packageBytes) == ESCROW_CODE_HASH, "ESCROW_ARTIFACT_HASH");

        escrow = kernel.contractAccountId(worldId, actorId, kernel.creatorNonce(worldId, actorId), ESCROW_CODE_HASH);
        require(kernel.programCodeHash(worldId, escrow) == bytes32(0), "ESCROW_ALREADY_DEPLOYED");

        address predictedMarket = vm.computeCreateAddress(actor, vm.getNonce(actor) + 1);
        bytes memory deployPayload =
            abi.encodePacked(bytes4(uint32(packageBytes.length)), packageBytes, abi.encode(token, predictedMarket));
        SwapVMKernel.VMEnvelope memory deploy = _signedEnvelope(
            SwapVMKernel.RootOp.DEPLOY,
            ESCROW_CODE_HASH,
            deployPayload,
            DEPLOY_LIMIT,
            actor,
            actor,
            kernel.nonces(worldId, actorId)
        );

        vm.startBroadcast(actorKey);
        router.buyVMExactInput{value: VM_INPUT}(worldId, SQRT_PRICE_LIMIT, deploy);
        vm.stopBroadcast();
        require(kernel.programCodeHash(worldId, escrow) == ESCROW_CODE_HASH, "ESCROW_DEPLOYMENT");

        vm.startBroadcast(actorKey);
        market = new SwapVMSRC20Market(router, worldId, token, TOKEN_CODE_HASH, escrow, ESCROW_CODE_HASH);
        vm.stopBroadcast();
        require(address(market) == predictedMarket, "MARKET_PREDICTION");
        require(market.tokenScale() == 1 ether, "TOKEN_SCALE");
    }

    function _exerciseEscrowRoundTrip() private {
        uint256 balanceBefore = _tokenBalance(actorId);
        bytes memory approvePayload =
            abi.encodePacked(bytes4(keccak256("approve(bytes32,uint256)")), abi.encode(escrow, ORDER_AMOUNT));
        SwapVMKernel.VMEnvelope memory approve = _signedEnvelope(
            SwapVMKernel.RootOp.CALL, token, approvePayload, TOKEN_LIMIT, actor, actor, kernel.nonces(worldId, actorId)
        );
        vm.startBroadcast(actorKey);
        router.buyVMExactInput{value: VM_INPUT}(worldId, SQRT_PRICE_LIMIT, approve);
        vm.stopBroadcast();

        bytes memory depositPayload =
            abi.encodePacked(bytes4(keccak256("deposit(bytes32,uint256)")), abi.encode(actorId, ORDER_AMOUNT));
        SwapVMKernel.VMEnvelope memory deposit = _signedEnvelope(
            SwapVMKernel.RootOp.CALL,
            escrow,
            depositPayload,
            ESCROW_LIMIT,
            actor,
            address(market),
            kernel.nonces(worldId, actorId)
        );
        vm.startBroadcast(actorKey);
        uint256 orderId = market.createSellOrder{value: VM_INPUT}(
            ORDER_AMOUNT, UNIT_PRICE, VM_INPUT, uint64(block.timestamp + 1 days), deposit, SQRT_PRICE_LIMIT
        );
        vm.stopBroadcast();
        require(market.escrowedTokenAmount() == ORDER_AMOUNT, "ESCROW_ACCOUNTING");
        require(market.isSellOrderSolvent(orderId), "OPEN_ORDER_SOLVENCY");

        bytes memory releasePayload =
            abi.encodePacked(bytes4(keccak256("release(bytes32,uint256)")), abi.encode(actorId, ORDER_AMOUNT));
        SwapVMKernel.VMEnvelope memory release = _signedEnvelope(
            SwapVMKernel.RootOp.CALL,
            escrow,
            releasePayload,
            ESCROW_LIMIT,
            actor,
            address(market),
            kernel.nonces(worldId, actorId)
        );
        vm.startBroadcast(actorKey);
        market.cancelSellOrder{value: VM_INPUT}(orderId, release, SQRT_PRICE_LIMIT);
        vm.stopBroadcast();

        require(market.escrowedTokenAmount() == 0, "FINAL_ESCROW_ACCOUNTING");
        require(_tokenBalance(actorId) == balanceBefore, "TOKEN_ROUND_TRIP");
        require(market.isSellOrderSolvent(orderId), "FINAL_SOLVENCY");
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

    function _tokenBalance(bytes32 account) private view returns (uint256 balance) {
        (bytes memory output,) = kernel.staticCall(
            worldId, token, abi.encodePacked(bytes4(keccak256("balanceOf(bytes32)")), abi.encode(account)), 2_000
        );
        require(output.length == 32, "BALANCE_WIDTH");
        balance = abi.decode(output, (uint256));
    }

    function _logResult() private view {
        console2.log("REFERENCE_MARKET_WORLD_ID");
        console2.logBytes32(worldId);
        console2.log("REFERENCE_MARKET_TOKEN");
        console2.logBytes32(token);
        console2.log("REFERENCE_MARKET_ESCROW");
        console2.logBytes32(escrow);
        console2.log("REFERENCE_MARKET_ADDRESS", address(market));
        console2.log("REFERENCE_MARKET_ESCROW_SOLVENT", market.isSellOrderSolvent(1));
    }
}
