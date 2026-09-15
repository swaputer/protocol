// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
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

interface IEthereumMainnetPositionManager {
    function poolManager() external view returns (address);
    function permit2() external view returns (address);
    function nextTokenId() external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128);
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
}

interface IEthereumMainnetPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;

    function allowance(address owner, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);
}

/// @notice Deploys the complete Ethereum Mainnet protocol and six-range LP bootstrap.
/// @dev Trading deliberately remains closed. The script never calls SwaputerHook.live().
///      The private key is supplied to Forge by the caller and is never read by Solidity.
contract SwaputerEthereumMainnetDeployScript is Script {
    using Planner for Plan;
    using PoolIdLibrary for PoolKey;

    uint256 private constant ETHEREUM_MAINNET_CHAIN_ID = 1;
    address private constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    bytes32 private constant POOL_MANAGER_CODE_HASH =
        0x785f1014552b7ce7d5fb7d0c970ca60edee94fd00425d7ca21609acac7ce1293;
    IEthereumMainnetPositionManager private constant POSITION_MANAGER =
        IEthereumMainnetPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
    bytes32 private constant POSITION_MANAGER_CODE_HASH =
        0x77e36c08b19959a30dde46dec9abe6208e371ff2f56884a56fe1e1a53615528b;
    IEthereumMainnetPermit2 private constant PERMIT2 =
        IEthereumMainnetPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    bytes32 private constant PERMIT2_CODE_HASH = 0xc67d1657868aa5146eaf24fb879fb1fdec3d2d493b3683a61c9c2f4fb2851131;

    uint256 private constant INITIAL_SUPPLY = 10_000 ether;
    uint128 private constant BYTE_GAS_PRICE = 1_000_000_000_000;
    uint24 private constant POOL_FEE = 3_000;
    int24 private constant TICK_SPACING = 60;
    uint160 private constant INITIAL_SQRT_PRICE_X96 = uint160(50) << 96;
    uint256 private constant MINIMUM_DEPLOYER_BALANCE = 0.01 ether;

    bytes32 private constant TOKEN_SALT = keccak256("Swaputer.sPuter.EthereumMainnet.token.v1");
    bytes32 private constant BOOTSTRAP_SALT = keccak256("Swaputer.sPuter.EthereumMainnet.world.v1");
    bytes32 private constant DISTRIBUTION_COMMITMENT =
        keccak256("Swaputer.sPuter.10000.all-supply-six-range-single-sided.EthereumMainnet.v1");

    address private deployer;
    uint256 private actualBalance;
    uint64 private startingNonce;
    SwaputerCreationCodeStore private kernelStore;
    SwaputerCreationCodeStore private hookStore;
    SwaputerWorldFactory private factory;
    SwaputerAppRouter private router;
    SwaputerToken private sPuter;
    SwaputerKernel private kernel;
    SwaputerHook private hook;
    PoolKey private poolKey;
    bytes32 private worldId;
    address private worldDeployer;
    address private predictedToken;
    address private predictedWorldDeployer;
    address private predictedKernel;
    address private predictedHook;
    uint256 private depositedSPuter;

    function run() external {
        _validateMainnetEnvironment();
        _deployProtocolAndWorld();
        _addAllSupplySingleSided();
        _validateFinalState();
        _logResult();
    }

    function _validateMainnetEnvironment() private {
        require(block.chainid == ETHEREUM_MAINNET_CHAIN_ID, "ETHEREUM_MAINNET_ONLY");
        require(POOL_MANAGER.codehash == POOL_MANAGER_CODE_HASH, "POOL_MANAGER_CODE_HASH");
        require(address(POSITION_MANAGER).codehash == POSITION_MANAGER_CODE_HASH, "POSITION_MANAGER_CODE_HASH");
        require(address(PERMIT2).codehash == PERMIT2_CODE_HASH, "PERMIT2_CODE_HASH");
        require(POSITION_MANAGER.poolManager() == POOL_MANAGER, "POSITION_MANAGER_POOL_MANAGER");
        require(POSITION_MANAGER.permit2() == address(PERMIT2), "POSITION_MANAGER_PERMIT2");

        deployer = vm.envAddress("SPUTER_MAINNET_DEPLOYER");
        require(deployer != address(0), "DEPLOYER_REQUIRED");
        actualBalance = deployer.balance;
        require(actualBalance >= MINIMUM_DEPLOYER_BALANCE, "INSUFFICIENT_DEPLOYER_BALANCE");
        startingNonce = vm.getNonce(deployer);
    }

    function _deployProtocolAndWorld() private {
        _deployCore();
        _createWorld();
        _validateWorld();
    }

    function _deployCore() private {
        vm.startBroadcast(deployer);
        kernelStore = new SwaputerCreationCodeStore(type(SwaputerKernel).creationCode);
        hookStore = new SwaputerCreationCodeStore(type(SwaputerHook).creationCode);
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
    }

    function _createWorld() private {
        predictedToken = factory.predictGasToken(TOKEN_SALT, INITIAL_SUPPLY, deployer);
        predictedWorldDeployer = factory.predictWorldDeployer(BOOTSTRAP_SALT);
        predictedKernel = factory.predictKernel(predictedWorldDeployer);
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
        bytes32 hookSalt;
        (predictedHook, hookSalt) = HookMiner.find(
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
    }

    function _validateWorld() private {
        bool isSealed;
        (poolKey, isSealed) = factory.getPoolKey(worldId);
        worldDeployer = factory.getWorldConfig(worldId).worldDeployer;
        require(isSealed && PoolId.unwrap(poolKey.toId()) == worldId, "WORLD_NOT_SEALED");
        require(address(sPuter) == predictedToken, "TOKEN_PREDICTION");
        require(worldDeployer == predictedWorldDeployer, "WORLD_DEPLOYER_PREDICTION");
        require(address(kernel) == predictedKernel && address(hook) == predictedHook, "WORLD_PREDICTION");
        require(Currency.unwrap(poolKey.currency0) == address(0), "NATIVE_ETH_NOT_CURRENCY0");
        require(Currency.unwrap(poolKey.currency1) == address(sPuter), "SPUTER_NOT_CURRENCY1");
        require(keccak256(bytes(sPuter.name())) == keccak256("Swaputer"), "TOKEN_NAME");
        require(keccak256(bytes(sPuter.symbol())) == keccak256("sPuter"), "TOKEN_SYMBOL");
        require(sPuter.totalSupply() == INITIAL_SUPPLY, "TOKEN_SUPPLY");
        require(uint160(address(hook)) & Hooks.ALL_HOOK_MASK == 0x20cc, "HOOK_PERMISSION_BITS");
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
        vm.stopBroadcast();

        depositedSPuter = balanceBefore - sPuter.balanceOf(deployer);
        require(INITIAL_SUPPLY - depositedSPuter <= 1_000, "SUPPLY_DUST_TOO_LARGE");
        require(sPuter.allowance(deployer, address(PERMIT2)) == 0, "ERC20_ALLOWANCE_REMAINS");
        (uint160 permitAmount,,) = PERMIT2.allowance(deployer, address(sPuter), address(POSITION_MANAGER));
        require(permitAmount == 0, "PERMIT2_ALLOWANCE_REMAINS");
        for (uint256 i; i < liquidities.length; ++i) {
            require(POSITION_MANAGER.ownerOf(positionTokenIds[i]) == deployer, "POSITION_OWNER");
            require(POSITION_MANAGER.getPositionLiquidity(positionTokenIds[i]) == liquidities[i], "POSITION_LIQUIDITY");
            console2.log("SPUTER_MAINNET_POSITION_ID", positionTokenIds[i]);
            console2.log("SPUTER_MAINNET_POSITION_LIQUIDITY", liquidities[i]);
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

    function _validateFinalState() private view {
        require(kernel.executionHeight(worldId) == 0, "UNEXPECTED_EXECUTION");
        require(kernel.executedBytes(worldId) == 0, "UNEXPECTED_EXECUTED_BYTES");
        require(hook.accruedProtocolFees() == 0, "UNEXPECTED_PROTOCOL_FEES");
        require(!hook.tradingLive(), "TRADING_MUST_REMAIN_CLOSED");
    }

    function _logResult() private view {
        console2.log("SPUTER_MAINNET_CHAIN_ID", block.chainid);
        console2.log("SPUTER_MAINNET_BLOCK", block.number);
        console2.log("SPUTER_MAINNET_DEPLOYER", deployer);
        console2.log("SPUTER_MAINNET_ACTUAL_BALANCE_WEI", actualBalance);
        console2.log("SPUTER_MAINNET_STARTING_NONCE", uint256(startingNonce));
        console2.log("SPUTER_MAINNET_KERNEL_STORE", address(kernelStore));
        console2.log("SPUTER_MAINNET_HOOK_STORE", address(hookStore));
        console2.log("SPUTER_MAINNET_FACTORY", address(factory));
        console2.log("SPUTER_MAINNET_REGISTRY", address(factory.referenceRegistry()));
        console2.log("SPUTER_MAINNET_ROUTER", address(router));
        console2.log("SPUTER_MAINNET_WORLD_DEPLOYER", worldDeployer);
        console2.log("SPUTER_MAINNET_TOKEN", address(sPuter));
        console2.log("SPUTER_MAINNET_KERNEL", address(kernel));
        console2.log("SPUTER_MAINNET_HOOK", address(hook));
        console2.log("SPUTER_MAINNET_WORLD_ID");
        console2.logBytes32(worldId);
        console2.log("SPUTER_MAINNET_INITIAL_SQRT_PRICE_X96", INITIAL_SQRT_PRICE_X96);
        console2.log("SPUTER_MAINNET_DEPOSITED_SPuter_WEI", depositedSPuter);
        console2.log("SPUTER_MAINNET_REMAINING_SPuter_WEI", sPuter.balanceOf(deployer));
        console2.log("SPUTER_MAINNET_TRADING_LIVE", hook.tradingLive());
    }
}
