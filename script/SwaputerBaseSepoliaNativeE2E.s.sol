// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {Plan, Planner} from "@uniswap/v4-periphery/test/shared/Planner.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {SwaputerCreationCodeStore} from "../src/SwaputerCreationCodeStore.sol";
import {SwaputerToken} from "../src/SwaputerToken.sol";
import {SwaputerHook} from "../src/SwaputerHook.sol";
import {SwaputerKernel} from "../src/SwaputerKernel.sol";
import {SwaputerAppRouter} from "../src/SwaputerAppRouter.sol";
import {SwaputerWorldFactory} from "../src/SwaputerWorldFactory.sol";

interface ISwaputerPositionManager {
    function poolManager() external view returns (address);
    function permit2() external view returns (address);
    function nextTokenId() external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128);
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
}

interface ISwaputerPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;

    function allowance(address owner, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);
}

interface ISwaputerStateView {
    function getSlot0(PoolId poolId)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
}

/// @notice Deploys and smoke-tests the exact native-ETH Swaputer path on Base Sepolia.
/// @dev Use Foundry's encrypted account option; this script never reads a private-key environment variable.
///      The release is isolated from the existing active Base Sepolia deployment and is testnet-only.
contract SwaputerBaseSepoliaNativeE2EScript is Script {
    using BalanceDeltaLibrary for BalanceDelta;
    using Planner for Plan;
    using PoolIdLibrary for PoolKey;

    uint256 private constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    address private constant POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    bytes32 private constant POOL_MANAGER_CODE_HASH =
        0x03c45db6d09b14da7c1f7239a5a49697f976d395277e6d2acb6fbed3f9e0249f;
    ISwaputerPositionManager private constant POSITION_MANAGER =
        ISwaputerPositionManager(0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80);
    bytes32 private constant POSITION_MANAGER_CODE_HASH =
        0xe8329b35b8b34290b6cf03affc0836f7b23205229cc96ffdc66544b93112c076;
    ISwaputerPermit2 private constant PERMIT2 = ISwaputerPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    ISwaputerStateView private constant STATE_VIEW = ISwaputerStateView(0x571291b572ed32ce6751a2Cb2486EbEe8DEfB9B4);

    uint256 private constant INITIAL_SUPPLY = 10_000 ether;
    uint128 private constant BYTE_GAS_PRICE = 1_000_000_000_000;
    uint24 private constant POOL_FEE = 3_000;
    int24 private constant TICK_SPACING = 60;
    uint160 private constant INITIAL_SQRT_PRICE_X96 = uint160(50) << 96;
    uint128 private constant SMOKE_BUY_INPUT = 0.000001 ether;
    uint160 private constant BUY_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 private constant SELL_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;
    uint256 private constant MAX_TESTNET_NATIVE_SPEND = 0.05 ether;

    bytes32 private constant TOKEN_SALT = keccak256("Swaputer.sPuter.BaseSepolia.native-e2e.token.v1");
    bytes32 private constant BOOTSTRAP_SALT = keccak256("Swaputer.sPuter.BaseSepolia.native-e2e.world.v1");
    bytes32 private constant DISTRIBUTION_COMMITMENT =
        keccak256("Swaputer.sPuter.10000.all-supply-six-range-single-sided.BaseSepolia.v1");

    address private deployer;
    uint256 private startingBalance;
    SwaputerWorldFactory private factory;
    SwaputerAppRouter private router;
    SwaputerToken private sPuter;
    SwaputerKernel private kernel;
    SwaputerHook private hook;
    PoolKey private poolKey;
    bytes32 private worldId;
    uint256 private depositedSPuter;

    function run() external {
        _validateEnvironment();
        _deployProtocolAndWorld();
        _addAllSupplySingleSided();
        _runNativeRoundTrip();
        _validateFinalState();
        _logResult();
    }

    function _validateEnvironment() private {
        require(block.chainid == BASE_SEPOLIA_CHAIN_ID, "BASE_SEPOLIA_ONLY");
        require(POOL_MANAGER.codehash == POOL_MANAGER_CODE_HASH, "POOL_MANAGER_CODE_HASH");
        require(address(POSITION_MANAGER).codehash == POSITION_MANAGER_CODE_HASH, "POSITION_MANAGER_CODE_HASH");
        require(POSITION_MANAGER.poolManager() == POOL_MANAGER, "POSITION_MANAGER_POOL_MANAGER");
        require(POSITION_MANAGER.permit2() == address(PERMIT2), "POSITION_MANAGER_PERMIT2");

        deployer = vm.envAddress("SPUTER_TESTNET_DEPLOYER");
        require(deployer != address(0), "DEPLOYER_REQUIRED");
        startingBalance = deployer.balance;
        require(startingBalance >= MAX_TESTNET_NATIVE_SPEND, "INSUFFICIENT_TESTNET_GAS_BALANCE");
    }

    function _deployProtocolAndWorld() private {
        vm.startBroadcast(deployer);
        SwaputerCreationCodeStore kernelStore = new SwaputerCreationCodeStore(type(SwaputerKernel).creationCode);
        SwaputerCreationCodeStore hookStore = new SwaputerCreationCodeStore(type(SwaputerHook).creationCode);
        factory = new SwaputerWorldFactory(
            IPoolManager(POOL_MANAGER),
            POOL_MANAGER_CODE_HASH,
            address(kernelStore),
            address(hookStore),
            deployer,
            deployer
        );
        vm.stopBroadcast();

        router = SwaputerAppRouter(payable(factory.router()));
        address predictedToken = factory.predictGasToken(TOKEN_SALT, INITIAL_SUPPLY, deployer);
        address predictedWorldDeployer = factory.predictWorldDeployer(BOOTSTRAP_SALT);
        address predictedKernel = factory.predictKernel(predictedWorldDeployer);
        bytes memory hookArgs = abi.encode(
            IPoolManager(POOL_MANAGER),
            SwaputerKernel(predictedKernel),
            predictedToken,
            factory.initialProtocolFeeAdmin(),
            factory.feeController(),
            factory.initialProtocolFeeBps(),
            BYTE_GAS_PRICE,
            POOL_FEE,
            TICK_SPACING
        );
        (address predictedHook, bytes32 hookSalt) = HookMiner.find(
            predictedWorldDeployer,
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG,
            type(SwaputerHook).creationCode,
            hookArgs
        );
        SwaputerWorldFactory.CreateWorldParams memory params = SwaputerWorldFactory.CreateWorldParams({
            tokenSalt: TOKEN_SALT,
            bootstrapSalt: BOOTSTRAP_SALT,
            hookSalt: hookSalt,
            predictedKernel: predictedKernel,
            predictedHook: predictedHook,
            initialSupply: INITIAL_SUPPLY,
            initialHolder: deployer,
            distributionCommitment: DISTRIBUTION_COMMITMENT,
            byteGasPrice: BYTE_GAS_PRICE,
            poolFee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            initialSqrtPriceX96: INITIAL_SQRT_PRICE_X96
        });

        vm.startBroadcast(deployer);
        (worldId, sPuter, kernel, hook) = factory.createWorld(params);
        vm.stopBroadcast();

        bool isSealed;
        (poolKey, isSealed) = factory.getPoolKey(worldId);
        require(isSealed && PoolId.unwrap(poolKey.toId()) == worldId, "WORLD_NOT_SEALED");
        require(address(sPuter) == predictedToken, "TOKEN_PREDICTION");
        require(address(kernel) == predictedKernel && address(hook) == predictedHook, "WORLD_PREDICTION");
        require(keccak256(bytes(sPuter.name())) == keccak256("Swaputer"), "TOKEN_NAME");
        require(keccak256(bytes(sPuter.symbol())) == keccak256("sPuter"), "TOKEN_SYMBOL");
        require(sPuter.totalSupply() == INITIAL_SUPPLY, "TOKEN_SUPPLY");
        require(uint160(address(hook)) & Hooks.ALL_HOOK_MASK == 0x20cc, "HOOK_PERMISSION_BITS");

        (uint160 sqrtPriceX96, int24 tick,, uint24 lpFee) = STATE_VIEW.getSlot0(poolKey.toId());
        require(sqrtPriceX96 == INITIAL_SQRT_PRICE_X96, "INITIAL_PRICE");
        require(tick > 78_240, "INITIAL_POSITION_NOT_SINGLE_SIDED");
        require(lpFee == POOL_FEE, "LP_FEE");
    }

    function _addAllSupplySingleSided() private {
        int24[6] memory lowerTicks = [int24(74_160), 70_080, 67_200, 60_300, 46_440, -887_220];
        int24[6] memory upperTicks = [int24(78_240), 74_160, 70_080, 67_200, 60_300, 46_440];
        uint256[6] memory tokenTargets = [
            uint256(50 ether),
            uint256(150 ether),
            uint256(800 ether),
            uint256(1_500 ether),
            uint256(2_500 ether),
            uint256(5_000 ether)
        ];
        uint128[6] memory liquidities;
        uint256[6] memory positionTokenIds;

        for (uint256 i; i < liquidities.length; ++i) {
            liquidities[i] = LiquidityAmounts.getLiquidityForAmount1(
                TickMath.getSqrtPriceAtTick(lowerTicks[i]), TickMath.getSqrtPriceAtTick(upperTicks[i]), tokenTargets[i]
            );
            require(liquidities[i] != 0, "ZERO_LIQUIDITY");
        }

        uint256 balanceBefore = sPuter.balanceOf(deployer);
        require(balanceBefore == INITIAL_SUPPLY, "INITIAL_HOLDER_BALANCE");
        vm.startBroadcast(deployer);
        sPuter.approve(address(PERMIT2), INITIAL_SUPPLY);
        PERMIT2.approve(
            address(sPuter), address(POSITION_MANAGER), uint160(INITIAL_SUPPLY), uint48(block.timestamp + 1 hours)
        );
        for (uint256 i; i < liquidities.length; ++i) {
            positionTokenIds[i] = POSITION_MANAGER.nextTokenId();
            POSITION_MANAGER.modifyLiquidities(
                _mintPlan(poolKey, lowerTicks[i], upperTicks[i], liquidities[i], tokenTargets[i]),
                block.timestamp + 10 minutes
            );
        }
        PERMIT2.approve(address(sPuter), address(POSITION_MANAGER), 0, 0);
        sPuter.approve(address(PERMIT2), 0);
        hook.live();
        vm.stopBroadcast();

        depositedSPuter = balanceBefore - sPuter.balanceOf(deployer);
        require(INITIAL_SUPPLY - depositedSPuter <= 1_000, "SUPPLY_DUST_TOO_LARGE");
        require(sPuter.allowance(deployer, address(PERMIT2)) == 0, "ERC20_ALLOWANCE_REMAINS");
        (uint160 permitAmount,,) = PERMIT2.allowance(deployer, address(sPuter), address(POSITION_MANAGER));
        require(permitAmount == 0, "PERMIT2_ALLOWANCE_REMAINS");
        for (uint256 i; i < liquidities.length; ++i) {
            require(POSITION_MANAGER.ownerOf(positionTokenIds[i]) == deployer, "POSITION_OWNER");
            require(POSITION_MANAGER.getPositionLiquidity(positionTokenIds[i]) == liquidities[i], "POSITION_LIQUIDITY");
            console2.log("SPUTER_BASE_SEPOLIA_POSITION_ID", positionTokenIds[i]);
            console2.log("SPUTER_BASE_SEPOLIA_POSITION_LIQUIDITY", liquidities[i]);
        }
    }

    function _runNativeRoundTrip() private {
        uint256 tokenBefore = sPuter.balanceOf(deployer);
        uint256 supplyBefore = sPuter.totalSupply();
        vm.startBroadcast(deployer);
        BalanceDelta buyDelta = router.buyNOPExactInput{value: SMOKE_BUY_INPUT}(worldId, 1, BUY_PRICE_LIMIT, deployer);
        vm.stopBroadcast();

        uint256 bought = sPuter.balanceOf(deployer) - tokenBefore;
        require(buyDelta.amount0() == -int128(int256(uint256(SMOKE_BUY_INPUT))), "BUY_GROSS_INPUT");
        require(bought > BYTE_GAS_PRICE, "BUY_OUTPUT_TOO_SMALL");
        require(sPuter.totalSupply() == supplyBefore - BYTE_GAS_PRICE, "NOP_BYTE_GAS_BURN");

        vm.startBroadcast(deployer);
        sPuter.approve(address(router), bought);
        BalanceDelta sellDelta = router.sellExactInput(worldId, uint128(bought), 1, SELL_PRICE_LIMIT, deployer);
        sPuter.approve(address(router), 0);
        vm.stopBroadcast();

        require(sellDelta.amount0() > 0, "SELL_NO_NATIVE_OUTPUT");
        require(sPuter.allowance(deployer, address(router)) == 0, "ROUTER_ALLOWANCE_REMAINS");
        console2.log("SPUTER_BASE_SEPOLIA_SMOKE_BUY_WEI", SMOKE_BUY_INPUT);
        console2.log("SPUTER_BASE_SEPOLIA_SMOKE_TOKEN_OUT", bought);
        console2.log("SPUTER_BASE_SEPOLIA_SMOKE_SELL_WEI_OUT", uint256(uint128(sellDelta.amount0())));
    }

    function _validateFinalState() private view {
        require(kernel.executionHeight(worldId) == 1, "NOP_EXECUTION_HEIGHT");
        require(kernel.executedBytes(worldId) == 1, "NOP_EXECUTED_BYTES");
        require(hook.accruedProtocolFees() > 0, "PROTOCOL_FEES_NOT_ACCRUED");
        require(hook.tradingLive(), "TRADING_NOT_LIVE");
        if (deployer.balance < startingBalance) {
            require(startingBalance - deployer.balance <= MAX_TESTNET_NATIVE_SPEND, "TESTNET_SPEND_CAP");
        }
    }

    function _mintPlan(PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 tokenMaximum)
        private
        view
        returns (bytes memory)
    {
        Plan memory plan = Planner.init();
        plan.add(
            Actions.MINT_POSITION,
            abi.encode(
                key, tickLower, tickUpper, uint256(liquidity), uint128(0), uint128(tokenMaximum), deployer, bytes("")
            )
        );
        plan.add(Actions.CLOSE_CURRENCY, abi.encode(key.currency0));
        plan.add(Actions.CLOSE_CURRENCY, abi.encode(key.currency1));
        plan.add(Actions.SWEEP, abi.encode(key.currency0, deployer));
        return plan.encode();
    }

    function _logResult() private view {
        (uint160 finalSqrtPriceX96, int24 finalTick,,) = STATE_VIEW.getSlot0(poolKey.toId());
        console2.log("SPUTER_BASE_SEPOLIA_TESTNET_ONLY", true);
        console2.log("SPUTER_BASE_SEPOLIA_FACTORY", address(factory));
        console2.log("SPUTER_BASE_SEPOLIA_ROUTER", address(router));
        console2.log("SPUTER_BASE_SEPOLIA_TOKEN", address(sPuter));
        console2.log("SPUTER_BASE_SEPOLIA_KERNEL", address(kernel));
        console2.log("SPUTER_BASE_SEPOLIA_HOOK", address(hook));
        console2.log("SPUTER_BASE_SEPOLIA_WORLD_ID");
        console2.logBytes32(worldId);
        console2.log("SPUTER_BASE_SEPOLIA_DEPOSITED", depositedSPuter);
        console2.log("SPUTER_BASE_SEPOLIA_FINAL_SQRT_PRICE_X96", finalSqrtPriceX96);
        console2.log("SPUTER_BASE_SEPOLIA_FINAL_TICK", int256(finalTick));
        console2.log("SPUTER_BASE_SEPOLIA_PROTOCOL_FEES", hook.accruedProtocolFees());
    }
}
