// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {SwaputerKernel} from "../src/SwaputerKernel.sol";
import {SwaputerAppRouter} from "../src/SwaputerAppRouter.sol";
import {SwapVMSRC20Market} from "../src/SwapVMSRC20Market.sol";

/// @notice Leaves one fully collateralized SRC20 sell order open on the current Base Sepolia World.
contract EventsBaseSepoliaOpenSellOrderScript is Script {
    uint256 private constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    address private constant ACTOR = 0x590a77Ec892bB78206bcad2444B62d1bC31A2D03;

    SwaputerAppRouter private constant ROUTER = SwaputerAppRouter(payable(0xEe164c82878AE80F2BE88B10771FAB2c4E29b24B));
    SwaputerKernel private constant KERNEL = SwaputerKernel(0xA751dAFFD61C2d259414573EfCD743cfB24ed10b);
    SwapVMSRC20Market private constant MARKET = SwapVMSRC20Market(payable(0xE183C4d7Ad2F5D882B4c6025DBf4f47cD0669446));

    bytes32 private constant WORLD_ID = 0x20f614ee9d36602f82422765fa005cedcb6c042fe7fbf5b368124820a829f757;
    bytes32 private constant TOKEN = 0x01ddc42fa71a13cc1ac4fad55e5adf116d9f6a299c18b467b3b90a8b722f946e;
    bytes32 private constant TOKEN_CODE_HASH = 0xaf15e40fe9fc1181a7143abb413562d69e1ab49a655209ac966204646c85c14b;
    bytes32 private constant ESCROW = 0x0182fbdf03d5b496c634e0eab2c603bea4297d738e5e1bb6083d98a4ccba2e3c;
    bytes32 private constant ESCROW_CODE_HASH = 0x6da9921193ebfe79468ef74f5b94925b66bf8230e145234a77868f1e5a85614b;

    uint128 private constant VM_INPUT = 0.000001 ether;
    uint128 private constant ORDER_AMOUNT = 100 ether;
    uint128 private constant UNIT_PRICE = 0.00001 ether;
    uint32 private constant TOKEN_LIMIT = 1_000;
    uint32 private constant ESCROW_LIMIT = 8_000;
    uint160 private constant SQRT_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;

    uint256 private actorKey;
    bytes32 private actorId;

    function run() external {
        require(block.chainid == BASE_SEPOLIA_CHAIN_ID, "BASE_SEPOLIA_ONLY");
        actorKey = vm.envUint("STAGE7A2_PRIVATE_KEY");
        require(vm.addr(actorKey) == ACTOR, "ACTOR_MISMATCH");
        require(address(MARKET.router()) == address(ROUTER), "MARKET_ROUTER");
        require(address(MARKET.kernel()) == address(KERNEL), "MARKET_KERNEL");
        require(MARKET.worldId() == WORLD_ID, "MARKET_WORLD");
        require(MARKET.token() == TOKEN && MARKET.tokenCodeHash() == TOKEN_CODE_HASH, "MARKET_TOKEN");
        require(MARKET.escrow() == ESCROW && MARKET.escrowCodeHash() == ESCROW_CODE_HASH, "MARKET_ESCROW");
        require(MARKET.escrowedTokenAmount() == 0, "ESCROW_NOT_EMPTY");
        actorId = KERNEL.eoaAccountId(ACTOR);

        uint256 previousOrderCount = MARKET.orderCount();
        _executeApprove();
        uint256 orderId = _createOpenSellOrder();

        require(orderId == previousOrderCount + 1 && MARKET.orderCount() == orderId, "ORDER_ID");
        require(MARKET.escrowedTokenAmount() == ORDER_AMOUNT, "ESCROW_LIABILITY");
        require(MARKET.activeSellAmount(ACTOR) == ORDER_AMOUNT, "ACTIVE_SELL");
        require(MARKET.isSellOrderSolvent(orderId), "SELL_INSOLVENT");
        require(_tokenBalance(ESCROW) == ORDER_AMOUNT, "ESCROW_BALANCE");
        SwapVMSRC20Market.Order memory order = MARKET.getOrder(orderId);
        require(
            order.side == SwapVMSRC20Market.Side.Sell && order.status == SwapVMSRC20Market.Status.Open, "ORDER_NOT_OPEN"
        );

        console2.log("EVENTS_OPEN_SELL_MARKET", address(MARKET));
        console2.log("EVENTS_OPEN_SELL_ORDER_ID", orderId);
        console2.log("EVENTS_OPEN_SELL_AMOUNT", ORDER_AMOUNT);
        console2.log("EVENTS_OPEN_SELL_UNIT_PRICE_WEI", UNIT_PRICE);
        console2.log("EVENTS_OPEN_SELL_EXPIRY", order.expiry);
    }

    function _executeApprove() private {
        bytes memory payload =
            abi.encodePacked(bytes4(keccak256("approve(bytes32,uint256)")), abi.encode(ESCROW, ORDER_AMOUNT));
        SwaputerKernel.VMEnvelope memory envelope = _signed(TOKEN, payload, TOKEN_LIMIT, ACTOR, ACTOR);
        vm.startBroadcast(actorKey);
        ROUTER.buyVMExactInput{value: VM_INPUT}(WORLD_ID, SQRT_PRICE_LIMIT, envelope);
        vm.stopBroadcast();
    }

    function _createOpenSellOrder() private returns (uint256 orderId) {
        bytes memory payload =
            abi.encodePacked(bytes4(keccak256("deposit(bytes32,uint256)")), abi.encode(actorId, ORDER_AMOUNT));
        SwaputerKernel.VMEnvelope memory envelope = _signed(ESCROW, payload, ESCROW_LIMIT, ACTOR, address(MARKET));
        vm.startBroadcast(actorKey);
        orderId = MARKET.createSellOrder{value: VM_INPUT}(
            ORDER_AMOUNT, UNIT_PRICE, VM_INPUT, uint64(block.timestamp + 30 days), envelope, SQRT_PRICE_LIMIT
        );
        vm.stopBroadcast();
    }

    function _signed(bytes32 target, bytes memory payload, uint32 byteLimit, address recipient, address executor)
        private
        view
        returns (SwaputerKernel.VMEnvelope memory envelope)
    {
        envelope = SwaputerKernel.VMEnvelope({
            op: SwaputerKernel.RootOp.CALL,
            worldId: WORLD_ID,
            actor: ACTOR,
            targetOrCodeHash: target,
            payload: payload,
            byteGasLimit: byteLimit,
            minNetTokenOut: 1,
            nonce: KERNEL.nonces(WORLD_ID, actorId),
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

    function _tokenBalance(bytes32 account) private view returns (uint256 amount) {
        (bytes memory output,) = KERNEL.staticCall(
            WORLD_ID, TOKEN, abi.encodePacked(bytes4(keccak256("balanceOf(bytes32)")), abi.encode(account)), 3_000
        );
        require(output.length == 32, "BALANCE_WIDTH");
        amount = abi.decode(output, (uint256));
    }
}
