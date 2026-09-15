// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {SwaputerToken} from "../src/SwaputerToken.sol";
import {SwaputerHook} from "../src/SwaputerHook.sol";
import {SwaputerWorldFactory} from "../src/SwaputerWorldFactory.sol";

/// @notice Base Sepolia proof that protocol fees are enforced by the Hook for an unrelated router.
contract Stage7HookFeeLiveScript is Script {
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;

    uint256 private constant BUY_INPUT = 0.00001 ether;

    function run() external {
        uint256 actorKey = vm.envUint("STAGE7A2_PRIVATE_KEY");
        address actor = vm.addr(actorKey);
        bytes32 worldId = vm.envBytes32("SVM_WORLD_ID");
        SwaputerWorldFactory factory = SwaputerWorldFactory(vm.envAddress("SVM_FACTORY_ADDRESS"));
        SwaputerHook hook = SwaputerHook(payable(vm.envAddress("SVM_HOOK_ADDRESS")));
        SwaputerToken token = SwaputerToken(vm.envAddress("SVM_GAS_TOKEN_ADDRESS"));
        (PoolKey memory key, bool isSealed) = factory.getPoolKey(worldId);

        require(isSealed && PoolId.unwrap(key.toId()) == worldId, "WORLD");
        require(hook.poolBound() && hook.boundPoolId() == worldId, "HOOK_BINDING");
        require(hook.feeAdmin() == actor && hook.feeController() == actor, "FEE_AUTHORITY");
        require(hook.protocolFeeBps() == 300, "INITIAL_FEE");

        vm.startBroadcast(actorKey);
        PoolSwapTest aggregateRouter = new PoolSwapTest(IPoolManager(address(factory.poolManager())));
        vm.stopBroadcast();

        uint256 accruedBeforeBuy = hook.accruedProtocolFees();
        uint256 tokenBeforeBuy = token.balanceOf(actor);
        vm.startBroadcast(actorKey);
        BalanceDelta buyDelta = aggregateRouter.swap{value: BUY_INPUT}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(BUY_INPUT), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
        vm.stopBroadcast();

        uint256 bought = token.balanceOf(actor) - tokenBeforeBuy;
        uint256 buyFee = hook.accruedProtocolFees() - accruedBeforeBuy;
        require(buyDelta.amount0() == -int128(int256(BUY_INPUT)), "BUY_GROSS_INPUT");
        require(bought == uint128(buyDelta.amount1()), "BUY_OUTPUT");
        require(buyFee == BUY_INPUT * 300 / 10_000, "BUY_HOOK_FEE");

        uint256 sellInput = bought / 4;
        require(sellInput != 0 && sellInput <= uint256(uint128(type(int128).max)), "SELL_INPUT");
        uint256 accruedBeforeSell = hook.accruedProtocolFees();
        vm.startBroadcast(actorKey);
        token.approve(address(aggregateRouter), sellInput);
        BalanceDelta sellDelta = aggregateRouter.swap(
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: -int256(sellInput), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("third-party-router")
        );
        token.approve(address(aggregateRouter), 0);
        vm.stopBroadcast();

        uint256 sellFee = hook.accruedProtocolFees() - accruedBeforeSell;
        uint256 netEthOut = uint128(sellDelta.amount0());
        uint256 grossEthOut = netEthOut + sellFee;
        require(sellFee == grossEthOut * 300 / 10_000, "SELL_HOOK_FEE");

        uint256 claimed = hook.accruedProtocolFees();
        require(claimed != 0 && address(hook).balance == claimed, "CLAIMABLE_FEES");
        vm.startBroadcast(actorKey);
        hook.setProtocolFeeBps(250);
        hook.setProtocolFeeBps(300);
        hook.claimProtocolFees();
        vm.stopBroadcast();
        require(hook.protocolFeeBps() == 300, "FINAL_FEE");
        require(hook.accruedProtocolFees() == 0 && address(hook).balance == 0, "CLAIM_COMPLETE");

        console2.log("HOOK_FEE_AGGREGATE_ROUTER", address(aggregateRouter));
        console2.log("HOOK_FEE_BUY_GROSS_WEI", BUY_INPUT);
        console2.log("HOOK_FEE_BUY_WEI", buyFee);
        console2.log("HOOK_FEE_SELL_GROSS_WEI", grossEthOut);
        console2.log("HOOK_FEE_SELL_WEI", sellFee);
        console2.log("HOOK_FEE_CLAIMED_WEI", claimed);
    }
}
