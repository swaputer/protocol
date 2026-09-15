// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";

import {SwaputerKernel} from "../../src/SwaputerKernel.sol";
import {SwapVMSRC20Market} from "../../src/SwapVMSRC20Market.sol";
import {SwapVMSRC20MarketTest} from "../SwapVMSRC20Market.t.sol";

contract SwapVMSRC20MarketInvariantTest is StdInvariant, SwapVMSRC20MarketTest {
    using TransientStateLibrary for IPoolManager;

    function setUp() public override {
        super.setUp();

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = this.actionCreateBuy.selector;
        selectors[1] = this.actionCancelBuy.selector;
        selectors[2] = this.actionFillBuy.selector;
        selectors[3] = this.actionCreateSell.selector;
        selectors[4] = this.actionCancelSell.selector;
        selectors[5] = this.actionSettleSell.selector;
        targetContract(address(this));
        targetSelector(FuzzSelector({addr: address(this), selectors: selectors}));
    }

    function actionCreateBuy(uint96 rawAmount, uint64 rawUnitPrice) external {
        uint128 amount = uint128(bound(uint256(rawAmount), 0.001 ether, 100 ether));
        uint128 unitPrice = uint128(bound(uint256(rawUnitPrice), 1 gwei, 0.001 ether));
        uint128 price = market.quotePrice(amount, unitPrice);
        uint256 value = uint256(price) + VM_INPUT;
        if (buyer.balance < value) return;

        vm.prank(buyer);
        market.createBuyOrder{value: value}(amount, unitPrice, VM_INPUT, uint64(block.timestamp + 1 days));
    }

    function actionCancelBuy(uint256 rawOrderId) external {
        uint256 count = market.orderCount();
        if (count == 0) return;
        uint256 orderId = bound(rawOrderId, 1, count);
        SwapVMSRC20Market.Order memory order = market.getOrder(orderId);
        if (
            order.side != SwapVMSRC20Market.Side.Buy || order.status != SwapVMSRC20Market.Status.Open
                || order.maker != buyer
        ) return;
        vm.prank(buyer);
        market.cancelOrder(orderId);
    }

    function actionFillBuy(uint256 rawOrderId) external {
        uint256 count = market.orderCount();
        if (count == 0) return;
        uint256 orderId = bound(rawOrderId, 1, count);
        SwapVMSRC20Market.Order memory order = market.getOrder(orderId);
        if (
            order.side != SwapVMSRC20Market.Side.Buy || order.status != SwapVMSRC20Market.Status.Open
                || _balanceOf(actor) < order.amount || actor.balance < VM_INPUT
        ) return;

        SwaputerKernel.VMEnvelope memory transfer =
            _signedTransfer(ACTOR_KEY, actor, buyer, order.amount, _nonce(actor), order.vmEthAmount);
        vm.prank(actor);
        market.fillBuyOrder(orderId, transfer, TickMath.MIN_SQRT_PRICE + 1);
    }

    function actionCreateSell(uint96 rawAmount, uint64 rawUnitPrice) external {
        uint256 available = _balanceOf(actor);
        if (available == 0 || actor.balance < VM_INPUT) return;
        uint256 maximum = available < 100 ether ? available : 100 ether;
        if (maximum < 1 gwei) return;
        uint128 amount = uint128(bound(uint256(rawAmount), 1 gwei, maximum));
        uint128 unitPrice = uint128(bound(uint256(rawUnitPrice), 1 gwei, 0.001 ether));
        if (_allowance(kernel.eoaAccountId(actor), escrow) < amount) _approveEscrow(SRC_SUPPLY);

        SwaputerKernel.VMEnvelope memory deposit =
            _signedEscrowDeposit(ACTOR_KEY, actor, amount, _nonce(actor), VM_INPUT);
        vm.prank(actor);
        market.createSellOrder{value: VM_INPUT}(
            amount, unitPrice, VM_INPUT, uint64(block.timestamp + 1 days), deposit, TickMath.MIN_SQRT_PRICE + 1
        );
    }

    function actionCancelSell(uint256 rawOrderId) external {
        uint256 count = market.orderCount();
        if (count == 0 || actor.balance < VM_INPUT) return;
        uint256 orderId = bound(rawOrderId, 1, count);
        SwapVMSRC20Market.Order memory order = market.getOrder(orderId);
        if (
            order.side != SwapVMSRC20Market.Side.Sell || order.status != SwapVMSRC20Market.Status.Open
                || order.maker != actor
        ) return;

        SwaputerKernel.VMEnvelope memory release =
            _signedEscrowRelease(ACTOR_KEY, actor, actor, order.amount, _nonce(actor), order.vmEthAmount);
        vm.prank(actor);
        market.cancelSellOrder{value: order.vmEthAmount}(orderId, release, TickMath.MIN_SQRT_PRICE + 1);
    }

    function actionSettleSell(uint256 rawOrderId) external {
        uint256 count = market.orderCount();
        if (count == 0) return;
        uint256 orderId = bound(rawOrderId, 1, count);
        SwapVMSRC20Market.Order memory order = market.getOrder(orderId);
        uint256 value = uint256(order.priceWei) + uint256(order.vmEthAmount);
        if (
            order.side != SwapVMSRC20Market.Side.Sell || order.status != SwapVMSRC20Market.Status.Open
                || buyer.balance < value
        ) return;

        SwaputerKernel.VMEnvelope memory release =
            _signedEscrowRelease(BUYER_KEY, buyer, buyer, order.amount, _nonce(buyer), order.vmEthAmount);
        vm.prank(buyer);
        market.settleSellOrder{value: value}(orderId, release, TickMath.MIN_SQRT_PRICE + 1);
    }

    function invariant_openOrdersExactlyMatchLiabilities() public view {
        uint256 openBuyLiability;
        uint256 openSellLiability;
        uint256 count = market.orderCount();
        for (uint256 orderId = 1; orderId <= count; ++orderId) {
            SwapVMSRC20Market.Order memory order = market.getOrder(orderId);
            if (order.status != SwapVMSRC20Market.Status.Open) continue;
            if (order.side == SwapVMSRC20Market.Side.Buy) {
                openBuyLiability += uint256(order.priceWei) + uint256(order.vmEthAmount);
            } else {
                openSellLiability += uint256(order.amount);
                assertTrue(market.isSellOrderSolvent(orderId));
            }
        }
        assertEq(market.lockedEth(), openBuyLiability);
        assertGe(address(market).balance, openBuyLiability);
        assertEq(market.escrowedTokenAmount(), openSellLiability);
        assertEq(market.activeSellAmount(actor), openSellLiability);
        assertEq(_balanceOfId(escrow), openSellLiability);
    }

    function invariant_src20BalancesRemainConserved() public view {
        uint256 totalSupply = _queryUint("totalSupply()", bytes(""));
        assertEq(_balanceOf(actor) + _balanceOf(buyer) + _balanceOfId(escrow), totalSupply);
        assertEq(totalSupply, SRC_SUPPLY);
    }

    function invariant_marketBindingsAndPoolDeltasRemainStable() public view {
        assertEq(address(market.router()), address(router));
        assertEq(address(market.kernel()), address(kernel));
        assertEq(market.worldId(), worldId);
        assertEq(market.token(), src20);
        assertEq(market.escrow(), escrow);
        IPoolManager poolManager = IPoolManager(address(manager));
        assertEq(poolManager.getNonzeroDeltaCount(), 0);
        assertEq(poolManager.currencyDelta(address(router), key.currency0), 0);
        assertEq(poolManager.currencyDelta(address(router), key.currency1), 0);
    }
}
