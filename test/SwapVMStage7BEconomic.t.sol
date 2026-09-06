// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

import {SwapVMKernel} from "../src/SwapVMKernel.sol";
import {SwapVMStage7A2Test} from "./SwapVMStage7A2.t.sol";

contract SwapVMStage7BEconomicTest is SwapVMStage7A2Test {
    using BalanceDeltaLibrary for BalanceDelta;
    using TransientStateLibrary for PoolManager;

    event EconomicVector(
        bytes32 indexed scenario,
        uint256 executedBytes,
        uint256 evmGasUsed,
        uint256 actualBurn,
        uint256 maximumExposure,
        uint256 grossOutput,
        uint256 netOutput,
        int256 priceImpactPpm,
        int256 attackerPnl,
        bool victimBoundHeld
    );

    function test_stage7B_sandwichOrderingPreservesVictimMinimumAndAttackerPaysFees() public {
        uint256 checkpoint = vm.snapshotState();
        BalanceDelta isolated = router.buyNOPExactInput{value: 1 ether}(worldId, 1, TickMath.MIN_SQRT_PRICE + 1, actor);
        uint256 isolatedGross = uint128(isolated.amount1()) + BYTE_GAS_PRICE;
        uint128 victimMinimum = uint128(uint256(uint128(isolated.amount1())) * 95 / 100);
        vm.revertToState(checkpoint);

        address attacker = address(0xA77AC);
        vm.deal(attacker, 100 ether);
        uint256 attackerEthBefore = attacker.balance;
        vm.startPrank(attacker);
        router.buyNOPExactInput{value: 5 ether}(worldId, 1, TickMath.MIN_SQRT_PRICE + 1, attacker);
        token.approve(address(router), type(uint256).max);
        vm.stopPrank();

        uint256 supplyBeforeVictim = token.totalSupply();
        uint256 gasBefore = gasleft();
        BalanceDelta victim =
            router.buyNOPExactInput{value: 1 ether}(worldId, victimMinimum, TickMath.MIN_SQRT_PRICE + 1, actor);
        uint256 gasUsed = gasBefore - gasleft();
        uint256 victimNet = uint128(victim.amount1());
        assertGe(victimNet, victimMinimum);
        assertEq(supplyBeforeVictim - token.totalSupply(), BYTE_GAS_PRICE);

        uint256 attackerTokens = token.balanceOf(attacker);
        vm.prank(attacker);
        router.sellExactInput(worldId, uint128(attackerTokens), 0, TickMath.MAX_SQRT_PRICE - 1, attacker);
        int256 pnl = int256(attacker.balance) - int256(attackerEthBefore);
        uint256 victimGross = victimNet + BYTE_GAS_PRICE;
        int256 priceImpactPpm = int256((isolatedGross - victimGross) * 1_000_000 / isolatedGross);
        assertLt(pnl, 0, "fee-paying round trip must not create value in fixed local ordering");
        assertEq(manager.getNonzeroDeltaCount(), 0);
        emit EconomicVector(
            keccak256("attacker-buy-victim-buy-attacker-sell"),
            1,
            gasUsed,
            BYTE_GAS_PRICE,
            BYTE_GAS_PRICE,
            victimGross,
            victimNet,
            priceImpactPpm,
            pnl,
            true
        );
    }

    function test_stage7B_exactMaximumExposureBoundary() public {
        (bytes32 target, uint64 nonce) = _deployStop();
        uint32 byteLimit = 1_000;
        uint256 maximumExposure = uint256(byteLimit) * BYTE_GAS_PRICE;
        uint256 gross = _probeGross(target, byteLimit, nonce);
        uint128 exactMin = uint128(gross - maximumExposure);
        SwapVMKernel.VMEnvelope memory exact = _callAction(target, byteLimit, exactMin, nonce);
        uint256 supplyBefore = token.totalSupply();
        uint256 gasBefore = gasleft();
        vm.prank(actor);
        BalanceDelta succeeded = router.buyVMExactInput{value: 1 ether}(worldId, TickMath.MIN_SQRT_PRICE + 1, exact);
        uint256 gasUsed = gasBefore - gasleft();
        assertEq(kernel.executedBytes(worldId), 1);
        assertEq(supplyBefore - token.totalSupply(), BYTE_GAS_PRICE);
        assertGe(uint128(succeeded.amount1()), exactMin);
        assertLt(BYTE_GAS_PRICE, maximumExposure);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        emit EconomicVector(
            keccak256("max-exposure-boundary"),
            1,
            gasUsed,
            BYTE_GAS_PRICE,
            maximumExposure,
            gross,
            uint128(succeeded.amount1()),
            0,
            0,
            true
        );
    }

    function test_stage7B_grossOneUnitBelowRequiredRevertsAtomically() public {
        (bytes32 target, uint64 nonce) = _deployStop();
        uint32 byteLimit = 1_000;
        uint256 maximumExposure = uint256(byteLimit) * BYTE_GAS_PRICE;
        uint256 gross = _probeGross(target, byteLimit, nonce);
        SwapVMKernel.VMEnvelope memory action =
            _callAction(target, byteLimit, uint128(gross - maximumExposure + 1), nonce);
        uint256 supplyBefore = token.totalSupply();
        uint64 heightBefore = kernel.executionHeight(worldId);
        vm.prank(actor);
        vm.expectRevert();
        router.buyVMExactInput{value: 1 ether}(worldId, TickMath.MIN_SQRT_PRICE + 1, action);
        assertEq(token.totalSupply(), supplyBefore);
        assertEq(kernel.executionHeight(worldId), heightBefore);
        assertEq(kernel.nonces(worldId, kernel.eoaAccountId(actor)), nonce);
        assertEq(manager.getNonzeroDeltaCount(), 0);
    }

    function test_stage7B_liquidityAddRemoveAroundVictimPreservesMinimumAndSettlement() public {
        uint256 checkpoint = vm.snapshotState();
        BalanceDelta isolated = router.buyNOPExactInput{value: 1 ether}(worldId, 1, TickMath.MIN_SQRT_PRICE + 1, actor);
        uint128 victimMinimum = uint128(uint256(uint128(isolated.amount1())) * 90 / 100);
        vm.revertToState(checkpoint);

        PoolModifyLiquidityTest attackerLiquidityRouter = new PoolModifyLiquidityTest(manager);
        token.approve(address(attackerLiquidityRouter), type(uint256).max);
        bytes32 attackerSalt = keccak256("stage7b-adversarial-lp");
        int256 liquidity = 1e22;
        attackerLiquidityRouter.modifyLiquidity{value: 1e24}(
            key,
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: liquidity, salt: attackerSalt}),
            bytes("")
        );

        uint256 supplyBefore = token.totalSupply();
        BalanceDelta victim =
            router.buyNOPExactInput{value: 1 ether}(worldId, victimMinimum, TickMath.MIN_SQRT_PRICE + 1, actor);
        assertGe(uint128(victim.amount1()), victimMinimum);
        assertEq(supplyBefore - token.totalSupply(), BYTE_GAS_PRICE);

        attackerLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: -liquidity, salt: attackerSalt}),
            bytes("")
        );
        assertEq(manager.getNonzeroDeltaCount(), 0);
    }

    function _deployStop() private returns (bytes32 target, uint64 nonce) {
        bytes memory packageBytes = _package(0, 0, keccak256("Stage7B.Economic.Stop"), hex"00");
        bytes32 codeHash = keccak256(packageBytes);
        bytes memory deployPayload = abi.encodePacked(bytes4(uint32(packageBytes.length)), packageBytes);
        SwapVMKernel.VMEnvelope memory deployAction = _signedAction(
            SwapVMKernel.RootOp.DEPLOY,
            codeHash,
            deployPayload,
            10,
            0,
            0,
            actor,
            actor,
            1 ether,
            TickMath.MIN_SQRT_PRICE + 1,
            address(router)
        );
        vm.prank(actor);
        router.buyVMExactInput{value: 1 ether}(worldId, TickMath.MIN_SQRT_PRICE + 1, deployAction);
        target = kernel.contractAccountId(worldId, kernel.eoaAccountId(actor), 0, codeHash);
        nonce = 1;
    }

    function _probeGross(bytes32 target, uint32 byteLimit, uint64 nonce) private returns (uint256 gross) {
        uint256 checkpoint = vm.snapshotState();
        SwapVMKernel.VMEnvelope memory probe = _callAction(target, byteLimit, 0, nonce);
        vm.prank(actor);
        BalanceDelta probeDelta = router.buyVMExactInput{value: 1 ether}(worldId, TickMath.MIN_SQRT_PRICE + 1, probe);
        gross = uint128(probeDelta.amount1()) + BYTE_GAS_PRICE;
        vm.revertToState(checkpoint);
    }

    function _callAction(bytes32 target, uint32 byteLimit, uint128 minNet, uint64 nonce)
        private
        view
        returns (SwapVMKernel.VMEnvelope memory)
    {
        return _signedAction(
            SwapVMKernel.RootOp.CALL,
            target,
            bytes(""),
            byteLimit,
            minNet,
            nonce,
            actor,
            actor,
            1 ether,
            TickMath.MIN_SQRT_PRICE + 1,
            address(router)
        );
    }
}
