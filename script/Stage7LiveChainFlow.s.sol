// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {SwapVMKernel} from "../src/SwapVMKernel.sol";
import {SwapVMRouter} from "../src/SwapVMRouter.sol";
import {SwapVMSRC20Market} from "../src/SwapVMSRC20Market.sol";
import {SwaputerSRC20MarketFactory} from "../src/SwaputerSRC20MarketFactory.sol";

/// @notice End-to-end Base Sepolia chain exercise:
///   create OpenMint SRC20 -> mint -> transfer -> market buy fill -> market sell settle.
contract Stage7LiveChainFlowScript is Script {
    uint256 private constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    uint256 private constant RELEASE_ETH_CAP = 0.5 ether;

    address private constant DEFAULT_ACTOR = 0x590a77Ec892bB78206bcad2444B62d1bC31A2D03;
    address private constant DEFAULT_BUYER = 0x23bAB887727e86b8FbD74a09d7EdAC80a3A62090;

    bytes32 private constant OPEN_MINT_CODE_HASH = 0xaedd7bd1543d57afaeb94f6b46e28ba4c1ef7cdd2ad4affca011b17056036869;
    bytes32 private constant ESCROW_CODE_HASH = 0x6da9921193ebfe79468ef74f5b94925b66bf8230e145234a77868f1e5a85614b;

    uint160 private constant SQRT_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint128 private constant VM_ETH_IN = 1_000_000_000_000; // 0.000001 ETH
    uint32 private constant DEPLOY_LIMIT = 16_000;
    uint32 private constant ACTION_LIMIT = 2_000;
    uint32 private constant ESCROW_LIMIT = 8_000;
    uint128 private constant ORDER_AMOUNT = 1 ether;
    uint128 private constant BUY_UNIT_PRICE_WEI = 1_000_000_000; // 1 gwei
    uint128 private constant SELL_UNIT_PRICE_WEI = 2_000_000_000; // 2 gwei

    bytes32 private constant NAME = bytes32("OpenMint SVM Demo");
    bytes32 private constant SYMBOL = bytes32("OMS");
    uint256 private constant SUPPLY_CAP = 1_000_000 ether;
    uint256 private constant MINT_AMOUNT = 1_000 ether;

    SwaputerSRC20MarketFactory private marketFactory;
    SwapVMRouter private router;
    SwapVMKernel private kernel;
    bytes32 private worldId;
    address private actor;
    address private buyer;

    function run() external {
        require(block.chainid == BASE_SEPOLIA_CHAIN_ID, "BASE_SEPOLIA_ONLY");
        uint256 actorKey = vm.envUint("STAGE7A2_PRIVATE_KEY");
        uint256 buyerKey = vm.envUint("STAGE7A2_SECOND_KEY");
        actor = vm.envOr("STAGE7A2_ACTOR", DEFAULT_ACTOR);
        buyer = vm.envOr("STAGE7A2_BUYER", DEFAULT_BUYER);

        require(vm.addr(actorKey) == actor, "ACTOR_MISMATCH");
        require(vm.addr(buyerKey) == buyer, "BUYER_MISMATCH");
        router = SwapVMRouter(payable(vm.envAddress("SVM_ROUTER_ADDRESS")));
        kernel = SwapVMKernel(vm.envAddress("SVM_KERNEL_ADDRESS"));
        worldId = vm.envBytes32("SVM_WORLD_ID");
        marketFactory = SwaputerSRC20MarketFactory(vm.envAddress("SVM_MARKET_FACTORY_ADDRESS"));
        require(address(marketFactory.router()) == address(router), "MARKET_FACTORY_ROUTER");
        require(marketFactory.worldId() == worldId, "MARKET_FACTORY_WORLD");
        require(marketFactory.escrowCodeHash() == ESCROW_CODE_HASH, "MARKET_FACTORY_ESCROW_HASH");
        require(marketFactory.trustedTokenCodeHash() == OPEN_MINT_CODE_HASH, "MARKET_FACTORY_TOKEN_HASH");

        bytes memory packageBytes = vm.readFileBinary("tooling/tinysol/programs/open-mint-src20/OpenMintSRC20.svm");
        bytes32 codeHash = keccak256(packageBytes);
        require(codeHash == OPEN_MINT_CODE_HASH, "OPEN_MINT_HASH");

        bytes32 actorId = kernel.eoaAccountId(actor);
        bytes32 buyerId = kernel.eoaAccountId(buyer);
        bytes32 contractId = kernel.contractAccountId(worldId, actorId, kernel.creatorNonce(worldId, actorId), codeHash);
        uint64 actorActionNonce = kernel.nonces(worldId, actorId);
        uint64 buyerActionNonce = kernel.nonces(worldId, buyerId);
        uint64 heightBefore = kernel.executionHeight(worldId);
        uint256 ethBalanceBefore = actor.balance;

        bytes memory constructorArgs = abi.encode(NAME, SYMBOL, SUPPLY_CAP, MINT_AMOUNT);
        bytes memory deployPayload =
            abi.encodePacked(bytes4(uint32(packageBytes.length)), packageBytes, constructorArgs);
        SwapVMKernel.VMEnvelope memory deployAction = _signedAction(
            actorKey,
            actor,
            SwapVMKernel.RootOp.DEPLOY,
            codeHash,
            deployPayload,
            DEPLOY_LIMIT,
            actorActionNonce++,
            VM_ETH_IN,
            actor,
            actor
        );
        vm.startBroadcast(actorKey);
        router.buyVMExactInput{value: VM_ETH_IN}(worldId, SQRT_PRICE_LIMIT, deployAction);
        vm.stopBroadcast();
        // Mint once to actor.
        bytes memory mintPayload = abi.encodePacked(bytes4(keccak256("mint(bytes32)")), abi.encode(actorId));
        SwapVMKernel.VMEnvelope memory mintAction = _signedAction(
            actorKey,
            actor,
            SwapVMKernel.RootOp.CALL,
            contractId,
            mintPayload,
            ACTION_LIMIT,
            actorActionNonce++,
            VM_ETH_IN,
            actor,
            actor
        );
        vm.startBroadcast(actorKey);
        router.buyVMExactInput{value: VM_ETH_IN}(worldId, SQRT_PRICE_LIMIT, mintAction);
        vm.stopBroadcast();

        uint256 actorBalanceAfterMint = _balanceOf(contractId, actorId);
        require(actorBalanceAfterMint == MINT_AMOUNT, "MINT_BALANCE");

        // Transfer part to buyer account so buyer can participate in both sides.
        bytes memory transferToBuyerPayload =
            abi.encodePacked(bytes4(keccak256("transfer(bytes32,uint256)")), abi.encode(buyerId, MINT_AMOUNT / 100));
        SwapVMKernel.VMEnvelope memory transferToBuyer = _signedAction(
            actorKey,
            actor,
            SwapVMKernel.RootOp.CALL,
            contractId,
            transferToBuyerPayload,
            ACTION_LIMIT,
            actorActionNonce++,
            VM_ETH_IN,
            actor,
            actor
        );
        vm.startBroadcast(actorKey);
        router.buyVMExactInput{value: VM_ETH_IN}(worldId, SQRT_PRICE_LIMIT, transferToBuyer);
        vm.stopBroadcast();

        uint256 buyerTokenAfterReceive = _balanceOf(contractId, buyerId);
        require(buyerTokenAfterReceive == MINT_AMOUNT / 100, "BUYER_MINT_TRANSFER");

        // Deploy escrow + create market
        bytes memory escrowPackage = vm.readFileBinary("tooling/tinysol/programs/market-escrow/MarketEscrow.svm");
        require(keccak256(escrowPackage) == ESCROW_CODE_HASH, "ESCROW_HASH");
        bytes32 escrowId =
            kernel.contractAccountId(worldId, actorId, kernel.creatorNonce(worldId, actorId), ESCROW_CODE_HASH);
        address predictedMarket = marketFactory.predictMarket(contractId, codeHash, escrowId);
        bytes memory deployEscrowPayload = abi.encodePacked(
            bytes4(uint32(escrowPackage.length)), escrowPackage, abi.encode(contractId, predictedMarket)
        );
        SwapVMKernel.VMEnvelope memory escrowDeploy = _signedAction(
            actorKey,
            actor,
            SwapVMKernel.RootOp.DEPLOY,
            ESCROW_CODE_HASH,
            deployEscrowPayload,
            DEPLOY_LIMIT,
            actorActionNonce++,
            VM_ETH_IN,
            actor,
            actor
        );
        vm.startBroadcast(actorKey);
        router.buyVMExactInput{value: VM_ETH_IN}(worldId, SQRT_PRICE_LIMIT, escrowDeploy);
        vm.stopBroadcast();

        vm.startBroadcast(actorKey);
        address marketAddress = marketFactory.createMarket(contractId, codeHash, escrowId);
        vm.stopBroadcast();
        require(marketAddress != address(0), "MARKET_ZERO");

        SwapVMSRC20Market market = SwapVMSRC20Market(payable(marketAddress));
        require(market.token() == contractId && market.escrow() == escrowId, "MARKET_BINDING");

        // Buyer creates buy order, actor fills it.
        uint64 expiry = uint64(block.timestamp + 1 days);
        uint128 orderPrice = market.quotePrice(ORDER_AMOUNT, BUY_UNIT_PRICE_WEI);
        vm.startBroadcast(buyerKey);
        uint256 buyOrderId =
            market.createBuyOrder{value: orderPrice + VM_ETH_IN}(ORDER_AMOUNT, BUY_UNIT_PRICE_WEI, VM_ETH_IN, expiry);
        vm.stopBroadcast();
        require(orderPrice > 0, "BUY_PRICE_ZERO");

        SwapVMKernel.VMEnvelope memory buyFill = _signedAction(
            actorKey,
            actor,
            SwapVMKernel.RootOp.CALL,
            contractId,
            abi.encodePacked(bytes4(keccak256("transfer(bytes32,uint256)")), abi.encode(buyerId, ORDER_AMOUNT)),
            ACTION_LIMIT,
            actorActionNonce++,
            VM_ETH_IN,
            buyer,
            marketAddress
        );
        vm.startBroadcast(actorKey);
        market.fillBuyOrder(buyOrderId, buyFill, SQRT_PRICE_LIMIT);
        vm.stopBroadcast();

        // Actor gives buyer one more token unit for sell-side liquidity
        SwapVMKernel.VMEnvelope memory seedForSell = _signedAction(
            actorKey,
            actor,
            SwapVMKernel.RootOp.CALL,
            contractId,
            abi.encodePacked(bytes4(keccak256("transfer(bytes32,uint256)")), abi.encode(buyerId, ORDER_AMOUNT)),
            ACTION_LIMIT,
            actorActionNonce++,
            VM_ETH_IN,
            actor,
            actor
        );
        vm.startBroadcast(actorKey);
        router.buyVMExactInput{value: VM_ETH_IN}(worldId, SQRT_PRICE_LIMIT, seedForSell);
        vm.stopBroadcast();

        // Buyer creates sell order: approve + deposit + create.
        uint128 sellAmount = ORDER_AMOUNT / 2;
        uint128 sellPrice = market.quotePrice(sellAmount, SELL_UNIT_PRICE_WEI);
        SwapVMKernel.VMEnvelope memory approveSell = _signedAction(
            buyerKey,
            buyer,
            SwapVMKernel.RootOp.CALL,
            contractId,
            abi.encodePacked(bytes4(keccak256("approve(bytes32,uint256)")), abi.encode(escrowId, sellAmount)),
            ACTION_LIMIT,
            buyerActionNonce++,
            VM_ETH_IN,
            buyer,
            buyer
        );
        vm.startBroadcast(buyerKey);
        router.buyVMExactInput{value: VM_ETH_IN}(worldId, SQRT_PRICE_LIMIT, approveSell);
        vm.stopBroadcast();

        SwapVMKernel.VMEnvelope memory deposit = _signedAction(
            buyerKey,
            buyer,
            SwapVMKernel.RootOp.CALL,
            escrowId,
            abi.encodePacked(bytes4(keccak256("deposit(bytes32,uint256)")), abi.encode(buyerId, sellAmount)),
            ESCROW_LIMIT,
            buyerActionNonce++,
            VM_ETH_IN,
            buyer,
            marketAddress
        );

        vm.startBroadcast(buyerKey);
        uint256 sellOrderId = market.createSellOrder{value: VM_ETH_IN}(
            sellAmount, SELL_UNIT_PRICE_WEI, VM_ETH_IN, expiry, deposit, SQRT_PRICE_LIMIT
        );
        vm.stopBroadcast();
        require(sellOrderId != 0, "SELL_ID_ZERO");

        SwapVMKernel.VMEnvelope memory settle = _signedAction(
            actorKey,
            actor,
            SwapVMKernel.RootOp.CALL,
            escrowId,
            abi.encodePacked(bytes4(keccak256("release(bytes32,uint256)")), abi.encode(actorId, sellAmount)),
            ESCROW_LIMIT,
            actorActionNonce++,
            VM_ETH_IN,
            actor,
            marketAddress
        );
        vm.startBroadcast(actorKey);
        market.settleSellOrder{value: sellPrice + VM_ETH_IN}(sellOrderId, settle, SQRT_PRICE_LIMIT);
        vm.stopBroadcast();

        require(_queryOrderStatus(market, buyOrderId) == 2, "BUY_NOT_FILLED");
        require(_queryOrderStatus(market, sellOrderId) == 2, "SELL_NOT_FILLED");

        uint256 actorTokenAfter = _balanceOf(contractId, actorId);
        uint256 buyerTokenAfter = _balanceOf(contractId, buyerId);
        require(actorTokenAfter > 0, "ACTOR_NO_TOKEN");
        require(buyerTokenAfter > MINT_AMOUNT / 100, "BUYER_NO_TOKEN_GROWTH");
        require(kernel.executionHeight(worldId) > heightBefore, "HEIGHT_NOT_CHANGED");

        console2.log("LIVE_CHAIN_FLOW_WORLD_ID");
        console2.logBytes32(worldId);
        console2.log("LIVE_CHAIN_FLOW_SRC20_ID");
        console2.logBytes32(contractId);
        console2.log("LIVE_CHAIN_FLOW_ESCROW_ID");
        console2.logBytes32(escrowId);
        console2.log("LIVE_CHAIN_FLOW_MARKET", marketAddress);
        console2.log("LIVE_CHAIN_FLOW_BUY_ORDER", buyOrderId);
        console2.log("LIVE_CHAIN_FLOW_SELL_ORDER", sellOrderId);
        console2.log("LIVE_CHAIN_FLOW_ACTOR_TOKEN_AFTER", actorTokenAfter);
        console2.log("LIVE_CHAIN_FLOW_BUYER_TOKEN_AFTER", buyerTokenAfter);
        console2.log("LIVE_CHAIN_FLOW_ETH_SPENT", ethBalanceBefore - actor.balance);
        console2.log("LIVE_CHAIN_FLOW_HEIGHT", kernel.executionHeight(worldId));
        if (actor.balance < ethBalanceBefore) {
            require(ethBalanceBefore - actor.balance <= RELEASE_ETH_CAP, "RELEASE_ETH_CAP_EXCEEDED");
        }
    }

    function _signedAction(
        uint256 actorKey,
        address envelopeActor,
        SwapVMKernel.RootOp op,
        bytes32 target,
        bytes memory payload,
        uint32 byteLimit,
        uint64 nonce,
        uint128 ethInput,
        address recipient,
        address executor
    ) private view returns (SwapVMKernel.VMEnvelope memory action) {
        action = SwapVMKernel.VMEnvelope({
            op: op,
            worldId: worldId,
            actor: envelopeActor,
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
                uint8(action.op),
                action.worldId,
                action.actor,
                action.targetOrCodeHash,
                keccak256(action.payload),
                action.byteGasLimit,
                action.minNetTokenOut,
                ethInput,
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

    function _balanceOf(bytes32 contractId, bytes32 accountId) private view returns (uint256 balance) {
        (bytes memory output,) = kernel.staticCall(
            worldId, contractId, abi.encodePacked(bytes4(keccak256("balanceOf(bytes32)")), abi.encode(accountId)), 2_000
        );
        require(output.length == 32, "BALANCE_WIDTH");
        balance = abi.decode(output, (uint256));
    }

    function _queryOrderStatus(SwapVMSRC20Market market, uint256 orderId) private view returns (uint256 status) {
        SwapVMSRC20Market.Order memory order = market.getOrder(orderId);
        status = uint256(uint8(order.status));
    }
}
