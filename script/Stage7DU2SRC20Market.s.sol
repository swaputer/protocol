// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {SwaputerKernel} from "../src/SwaputerKernel.sol";
import {SwaputerAppRouter} from "../src/SwaputerAppRouter.sol";
import {SwapVMSRC20Market} from "../src/SwapVMSRC20Market.sol";

/// @notice Deploys and exercises the zero-value SRC20 market on the existing Base Sepolia U2 World.
contract Stage7DU2SRC20MarketScript is Script {
    uint256 private constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    uint256 private constant RELEASE_START_BALANCE = 12_413_260_640_785_848_061;
    uint256 private constant RELEASE_ETH_CAP = 0.5 ether;

    address private constant ACTOR = 0x590a77Ec892bB78206bcad2444B62d1bC31A2D03;
    SwaputerAppRouter private constant ROUTER = SwaputerAppRouter(payable(0xEDAbF849F3F74FE3C92FCEa50968332f77B06F07));
    SwaputerKernel private constant KERNEL = SwaputerKernel(0xA048C894A738185c24B4A5020Fb6708dAb160283);
    bytes32 private constant WORLD_ID = 0x9c414214b34b78217698b02c5b1a7af65f6d43c500ed2bd865ea4c54ed4360b9;
    bytes32 private constant TOKEN = 0x012928db8f5a86bc849ed1a66d4ff19bb5af3a9a49688aa9d6d060f41f82d8d8;
    bytes32 private constant TOKEN_CODE_HASH = 0x1a049200e47e150864788daeba7b106628283d0d6219ddf7be80f89ebb691b2e;

    uint128 private constant ORDER_AMOUNT = 100 ether;
    uint128 private constant UNIT_PRICE = 0.00001 ether;
    uint128 private constant ORDER_PRICE = 0.001 ether;
    uint128 private constant VM_INPUT = 0.001 ether;
    uint32 private constant TRANSFER_LIMIT = 500;

    uint256 private actorKey;
    SwapVMSRC20Market private market;
    bytes32 private escrow;
    bytes32 private escrowCodeHash;

    function run() external {
        require(block.chainid == BASE_SEPOLIA_CHAIN_ID, "BASE_SEPOLIA_ONLY");
        actorKey = vm.envUint("STAGE7A2_PRIVATE_KEY");
        require(vm.addr(actorKey) == ACTOR, "ACTOR_MISMATCH");
        require(ACTOR.balance >= 0.01 ether, "INSUFFICIENT_TEST_ETH");
        require(KERNEL.programCodeHash(WORLD_ID, TOKEN) == TOKEN_CODE_HASH, "TOKEN_CODE_HASH");
        escrow = vm.envBytes32("STAGE7D_U2_MARKET_ESCROW");
        escrowCodeHash = vm.envBytes32("STAGE7D_U2_MARKET_ESCROW_CODE_HASH");
        require(escrow != bytes32(0) && escrowCodeHash != bytes32(0), "ESCROW_REQUIRED");
        require(KERNEL.programCodeHash(WORLD_ID, escrow) == escrowCodeHash, "ESCROW_CODE_HASH");
        _enforceReleaseCap();

        vm.startBroadcast(actorKey);
        market = new SwapVMSRC20Market(ROUTER, WORLD_ID, TOKEN, TOKEN_CODE_HASH, escrow, escrowCodeHash);
        vm.stopBroadcast();
        _assertBindings();

        uint256 balanceBefore = _balanceOf(ACTOR);
        uint256 supplyBefore = _queryUint("totalSupply()", bytes(""));
        uint64 heightBefore = KERNEL.executionHeight(WORLD_ID);
        uint64 nonceBefore = KERNEL.nonces(WORLD_ID, KERNEL.eoaAccountId(ACTOR));

        uint256 buyOrderId = _createBuyOrder();
        _fillBuyOrder(buyOrderId);
        _assertFilled(buyOrderId, SwapVMSRC20Market.Side.Buy);

        uint256 cancelledOrderId = _createBuyOrder();
        vm.startBroadcast(actorKey);
        market.cancelOrder(cancelledOrderId);
        vm.stopBroadcast();
        SwapVMSRC20Market.Order memory cancelled = market.getOrder(cancelledOrderId);
        require(cancelled.status == SwapVMSRC20Market.Status.Cancelled, "CANCEL_STATUS");

        require(KERNEL.executionHeight(WORLD_ID) == heightBefore + 1, "HEIGHT_DELTA");
        require(KERNEL.nonces(WORLD_ID, KERNEL.eoaAccountId(ACTOR)) == nonceBefore + 1, "NONCE_DELTA");
        require(_balanceOf(ACTOR) == balanceBefore, "SELF_TRANSFER_BALANCE");
        require(_queryUint("totalSupply()", bytes("")) == supplyBefore, "SRC20_SUPPLY_CHANGED");
        require(market.lockedEth() == 0 && address(market).balance == 0, "MARKET_ETH_REMAINS");
        _enforceReleaseCap();

        console2.log("STAGE7D_U2_SRC20_MARKET", address(market));
        console2.log("STAGE7D_U2_SRC20_MARKET_RUNTIME_CODE_HASH");
        console2.logBytes32(address(market).codehash);
        console2.log("STAGE7D_U2_SRC20_MARKET_BUY_ORDER", buyOrderId);
        console2.log("STAGE7D_U2_SRC20_MARKET_CANCELLED_ORDER", cancelledOrderId);
        console2.log("STAGE7D_U2_SRC20_MARKET_HEIGHT", KERNEL.executionHeight(WORLD_ID));
        console2.log("STAGE7D_U2_SRC20_MARKET_UNAUDITED", true);
    }

    function _createBuyOrder() private returns (uint256 orderId) {
        vm.startBroadcast(actorKey);
        orderId = market.createBuyOrder{value: ORDER_PRICE + VM_INPUT}(
            ORDER_AMOUNT, UNIT_PRICE, VM_INPUT, uint64(block.timestamp + 1 days)
        );
        vm.stopBroadcast();
    }

    function _fillBuyOrder(uint256 orderId) private {
        SwaputerKernel.VMEnvelope memory envelope = _signedTransfer();
        vm.startBroadcast(actorKey);
        market.fillBuyOrder(orderId, envelope, TickMath.MIN_SQRT_PRICE + 1);
        vm.stopBroadcast();
    }

    function _signedTransfer() private view returns (SwaputerKernel.VMEnvelope memory envelope) {
        bytes32 actorId = KERNEL.eoaAccountId(ACTOR);
        bytes memory payload =
            abi.encodePacked(bytes4(keccak256("transfer(bytes32,uint256)")), abi.encode(actorId, ORDER_AMOUNT));
        envelope = SwaputerKernel.VMEnvelope({
            op: SwaputerKernel.RootOp.CALL,
            worldId: WORLD_ID,
            actor: ACTOR,
            targetOrCodeHash: TOKEN,
            payload: payload,
            byteGasLimit: TRANSFER_LIMIT,
            minNetTokenOut: 1,
            nonce: KERNEL.nonces(WORLD_ID, actorId),
            deadline: uint64(block.timestamp + 1 days),
            recipient: ACTOR,
            authorizedExecutor: address(market),
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
                uint160(TickMath.MIN_SQRT_PRICE + 1),
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

    function _assertBindings() private view {
        require(address(market.router()) == address(ROUTER), "ROUTER_BINDING");
        require(address(market.kernel()) == address(KERNEL), "KERNEL_BINDING");
        require(market.worldId() == WORLD_ID, "WORLD_BINDING");
        require(market.token() == TOKEN && market.tokenCodeHash() == TOKEN_CODE_HASH, "TOKEN_BINDING");
        require(market.escrow() == escrow && market.escrowCodeHash() == escrowCodeHash, "ESCROW_BINDING");
        require(market.quotePrice(ORDER_AMOUNT, UNIT_PRICE) == ORDER_PRICE, "PRICE_QUOTE");
    }

    function _assertFilled(uint256 orderId, SwapVMSRC20Market.Side expectedSide) private view {
        SwapVMSRC20Market.Order memory order = market.getOrder(orderId);
        require(order.side == expectedSide, "ORDER_SIDE");
        require(order.status == SwapVMSRC20Market.Status.Filled, "ORDER_STATUS");
        require(order.maker == ACTOR && order.taker == ACTOR, "ORDER_PARTIES");
        require(order.amount == ORDER_AMOUNT && order.priceWei == ORDER_PRICE, "ORDER_TERMS");
    }

    function _balanceOf(address account) private view returns (uint256) {
        return _queryUint("balanceOf(bytes32)", abi.encode(KERNEL.eoaAccountId(account)));
    }

    function _queryUint(string memory signature, bytes memory arguments) private view returns (uint256 value) {
        (bytes memory output,) =
            KERNEL.staticCall(WORLD_ID, TOKEN, abi.encodePacked(bytes4(keccak256(bytes(signature))), arguments), 2_000);
        require(output.length == 32, "QUERY_WIDTH");
        value = abi.decode(output, (uint256));
    }

    function _enforceReleaseCap() private view {
        if (ACTOR.balance < RELEASE_START_BALANCE) {
            require(RELEASE_START_BALANCE - ACTOR.balance <= RELEASE_ETH_CAP, "RELEASE_ETH_CAP_EXCEEDED");
        }
    }
}
