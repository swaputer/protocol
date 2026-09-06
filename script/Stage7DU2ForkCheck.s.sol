// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {SwapVMCreationCodeStore} from "../src/SwapVMCreationCodeStore.sol";
import {SwapVMGasToken} from "../src/SwapVMGasToken.sol";
import {SwapVMHook} from "../src/SwapVMHook.sol";
import {SwapVMKernel} from "../src/SwapVMKernel.sol";
import {SwapVMRouter} from "../src/SwapVMRouter.sol";
import {SwapVMWorldFactory} from "../src/SwapVMWorldFactory.sol";

/// @notice Read-only fork compatibility proof against the official Base Sepolia PoolManager.
/// @dev Run with `forge script --fork-url`; no transaction is signed or broadcast upstream.
contract Stage7DU2ForkCheckScript is Script {
    using BalanceDeltaLibrary for BalanceDelta;

    PoolManager internal constant MANAGER = PoolManager(0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408);
    bytes32 internal constant MANAGER_CODE_HASH = 0x03c45db6d09b14da7c1f7239a5a49697f976d395277e6d2acb6fbed3f9e0249f;
    address internal constant LIQUIDITY_ROUTER = 0x37429cD17Cb1454C34E7F50b09725202Fd533039;
    bytes32 internal constant LIQUIDITY_ROUTER_CODE_HASH =
        0x5d39a7244938a909f70906d72c9814c8024046513f5699cd6fb30d10d7e0a5db;
    bytes32 internal constant TOKEN_SALT = 0x3759c435ce279ce074811ee5a2644fe5b2ef4bb873ca21ad5ee903565433faef;
    bytes32 internal constant BOOTSTRAP_SALT = 0xdf010f36bf156164481ba9fe4a254f6d5b826a38894ac0106bf86fd1ad573d5e;
    uint256 internal constant INITIAL_SUPPLY = 1_000_000_000 ether;
    uint128 internal constant BYTE_GAS_PRICE = 1_000_000_000_000;
    uint24 internal constant POOL_FEE = 3_000;
    int24 internal constant TICK_SPACING = 60;
    uint160 internal constant SQRT_PRICE_1_1 = 1 << 96;
    address internal constant PROBE_ACTOR = 0x000000000000000000000000000000000000dEaD;

    function run() external {
        require(block.chainid == 84_532, "CHAIN_ID_MISMATCH");
        require(address(MANAGER).codehash == MANAGER_CODE_HASH, "POOL_MANAGER_CODE_HASH_MISMATCH");
        require(LIQUIDITY_ROUTER.codehash == LIQUIDITY_ROUTER_CODE_HASH, "LIQUIDITY_ROUTER_CODE_HASH_MISMATCH");
        vm.deal(PROBE_ACTOR, 100 ether);
        vm.startPrank(PROBE_ACTOR);

        uint256 gasBefore = gasleft();
        SwapVMCreationCodeStore kernelStore = new SwapVMCreationCodeStore(type(SwapVMKernel).creationCode);
        uint256 kernelStoreGas = gasBefore - gasleft();
        gasBefore = gasleft();
        SwapVMCreationCodeStore hookStore = new SwapVMCreationCodeStore(type(SwapVMHook).creationCode);
        uint256 hookStoreGas = gasBefore - gasleft();
        gasBefore = gasleft();
        SwapVMWorldFactory factory = new SwapVMWorldFactory(
            MANAGER,
            MANAGER_CODE_HASH,
            address(kernelStore),
            address(hookStore),
            vm.envAddress("SVM_PROTOCOL_FEE_ADMIN"),
            vm.envAddress("SVM_FEE_CONTROLLER"),
            uint16(vm.envUint("SVM_INITIAL_PROTOCOL_FEE_BPS"))
        );
        uint256 factoryGas = gasBefore - gasleft();

        SwapVMWorldFactory.CreateWorldParams memory params;
        params.tokenSalt = TOKEN_SALT;
        params.bootstrapSalt = BOOTSTRAP_SALT;
        params.initialSupply = INITIAL_SUPPLY;
        params.initialHolder = PROBE_ACTOR;
        params.distributionCommitment = 0x66535c0450d86529bbd9d36149c4251e78d0966e2d63426afc84951727e66170;
        params.byteGasPrice = BYTE_GAS_PRICE;
        params.poolFee = POOL_FEE;
        params.tickSpacing = TICK_SPACING;
        params.initialSqrtPriceX96 = SQRT_PRICE_1_1;
        address predictedToken = factory.predictGasToken(TOKEN_SALT, INITIAL_SUPPLY, PROBE_ACTOR);
        address predictedWorldDeployer = factory.predictWorldDeployer(BOOTSTRAP_SALT);
        params.predictedKernel = factory.predictKernel(predictedWorldDeployer);
        bytes memory hookArguments = abi.encode(
            MANAGER,
            SwapVMKernel(params.predictedKernel),
            SwapVMGasToken(predictedToken),
            factory.initialProtocolFeeAdmin(),
            factory.feeController(),
            factory.initialProtocolFeeBps(),
            BYTE_GAS_PRICE,
            POOL_FEE,
            TICK_SPACING
        );
        (params.predictedHook, params.hookSalt) = HookMiner.find(
            predictedWorldDeployer,
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG,
            type(SwapVMHook).creationCode,
            hookArguments
        );

        gasBefore = gasleft();
        (bytes32 worldId, SwapVMGasToken token, SwapVMKernel kernel, SwapVMHook hook) = factory.createWorld(params);
        uint256 createWorldGas = gasBefore - gasleft();
        require(address(hook.poolManager()) == address(MANAGER), "POOL_MANAGER_BINDING_MISMATCH");
        require(uint160(address(hook)) & Hooks.ALL_HOOK_MASK == 0x20cc, "HOOK_PERMISSION_BITS_MISMATCH");

        (PoolKey memory key, bool isSealed) = factory.getPoolKey(worldId);
        require(isSealed, "WORLD_NOT_SEALED");
        PoolModifyLiquidityTest liquidityRouter = PoolModifyLiquidityTest(payable(LIQUIDITY_ROUTER));
        token.approve(address(liquidityRouter), type(uint256).max);
        gasBefore = gasleft();
        BalanceDelta liquidityDelta = liquidityRouter.modifyLiquidity{value: 0.1 ether}(
            key,
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 3 ether, salt: bytes32(0)}),
            bytes("")
        );
        uint256 liquidityGas = gasBefore - gasleft();

        SwapVMRouter router = SwapVMRouter(payable(factory.router()));
        uint256 supplyBefore = token.totalSupply();
        uint256 balanceBefore = token.balanceOf(PROBE_ACTOR);
        gasBefore = gasleft();
        BalanceDelta buyDelta =
            router.buyNOPExactInput{value: 0.001 ether}(worldId, 1, TickMath.MIN_SQRT_PRICE + 1, PROBE_ACTOR);
        uint256 nopBuyGas = gasBefore - gasleft();
        require(buyDelta.amount1() > 0, "NOP_BUY_NO_TOKEN_OUTPUT");
        require(token.totalSupply() == supplyBefore - BYTE_GAS_PRICE, "NOP_BUY_BURN_MISMATCH");
        require(kernel.executionHeight(worldId) == 1, "NOP_BUY_HEIGHT_MISMATCH");
        require(kernel.executedBytes(worldId) == 1, "NOP_BUY_EXECUTED_BYTES_MISMATCH");
        require(
            token.balanceOf(PROBE_ACTOR) - balanceBefore == uint128(buyDelta.amount1()),
            "NOP_BUY_BALANCE_DELTA_MISMATCH"
        );

        token.approve(address(router), type(uint256).max);
        gasBefore = gasleft();
        BalanceDelta sellDelta =
            router.sellExactInput(worldId, uint128(0.0001 ether), 1, TickMath.MAX_SQRT_PRICE - 1, PROBE_ACTOR);
        uint256 sellGas = gasBefore - gasleft();
        require(sellDelta.amount0() > 0, "SELL_NO_NATIVE_OUTPUT");
        require(sellDelta.amount1() < 0, "SELL_NO_TOKEN_INPUT");
        require(kernel.executionHeight(worldId) == 1, "SELL_CHANGED_HEIGHT");
        require(token.totalSupply() == supplyBefore - BYTE_GAS_PRICE, "SELL_CHANGED_SUPPLY");

        console2.log("STAGE7D_U2_KERNEL_STORE_GAS", kernelStoreGas);
        console2.log("STAGE7D_U2_HOOK_STORE_GAS", hookStoreGas);
        console2.log("STAGE7D_U2_FACTORY_GAS", factoryGas);
        console2.log("STAGE7D_U2_CREATE_WORLD_GAS", createWorldGas);
        console2.log("STAGE7D_U2_BOOTSTRAP_LIQUIDITY_GAS", liquidityGas);
        console2.log("STAGE7D_U2_BOOTSTRAP_NATIVE_WEI", uint256(-int256(liquidityDelta.amount0())));
        console2.log("STAGE7D_U2_BOOTSTRAP_TOKEN_UNITS", uint256(-int256(liquidityDelta.amount1())));
        console2.log("STAGE7D_U2_NOP_BUY_GAS", nopBuyGas);
        console2.log("STAGE7D_U2_SELL_GAS", sellGas);
        vm.stopPrank();
    }
}
