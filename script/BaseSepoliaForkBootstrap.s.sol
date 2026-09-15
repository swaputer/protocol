// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

import {SwaputerToken} from "../src/SwaputerToken.sol";
import {SwaputerAppRouter} from "../src/SwaputerAppRouter.sol";
import {SwaputerWorldFactory} from "../src/SwaputerWorldFactory.sol";
import {SwaputerSRC20MarketFactory} from "../src/SwaputerSRC20MarketFactory.sol";

/// @notice Isolated-fork bootstrap for release reproducibility drills.
/// @dev The PoolModifyLiquidityTest instance is deliberately local to the fork and is not a release artifact.
contract BaseSepoliaForkBootstrapScript is Script {
    using PoolIdLibrary for PoolKey;

    uint256 private constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    uint160 private constant SQRT_PRICE_1_1 = 1 << 96;

    function run() external {
        require(block.chainid == BASE_SEPOLIA_CHAIN_ID, "BASE_SEPOLIA_ONLY");
        require(vm.envBool("SVM_ISOLATED_FORK"), "ISOLATED_FORK_ONLY");

        uint256 actorKey = vm.envUint("STAGE7A2_PRIVATE_KEY");
        address actor = vm.addr(actorKey);
        SwaputerWorldFactory factory = SwaputerWorldFactory(vm.envAddress("SVM_FACTORY_ADDRESS"));
        bytes32 worldId = vm.envBytes32("SVM_WORLD_ID");
        SwaputerToken gasToken = SwaputerToken(vm.envAddress("SVM_GAS_TOKEN_ADDRESS"));
        SwaputerAppRouter router = SwaputerAppRouter(payable(vm.envAddress("SVM_ROUTER_ADDRESS")));
        (PoolKey memory key, bool isSealed) = factory.getPoolKey(worldId);

        require(isSealed && PoolId.unwrap(key.toId()) == worldId, "WORLD_NOT_SEALED");
        require(address(factory.poolManager()).code.length != 0, "POOL_MANAGER_MISSING");
        require(factory.router() == address(router), "ROUTER_MISMATCH");
        require(address(gasToken) == Currency.unwrap(key.currency1), "TOKEN_MISMATCH");
        require(factory.getWorldConfig(worldId).initialSqrtPriceX96 == SQRT_PRICE_1_1, "PRICE_NOT_ONE_TO_ONE");

        bytes memory openMint = vm.readFileBinary("tooling/tinysol/programs/open-mint-src20/OpenMintSRC20.svm");
        bytes memory escrow = vm.readFileBinary("tooling/tinysol/programs/market-escrow/MarketEscrow.svm");

        vm.startBroadcast(actorKey);
        PoolModifyLiquidityTest liquidityRouter = new PoolModifyLiquidityTest(IPoolManager(factory.poolManager()));
        gasToken.approve(address(liquidityRouter), type(uint256).max);
        int24 width = key.tickSpacing * 10;
        liquidityRouter.modifyLiquidity{value: 20_000 ether}(
            key,
            ModifyLiquidityParams({tickLower: -width, tickUpper: width, liquidityDelta: 1e23, salt: bytes32(0)}),
            bytes("")
        );
        gasToken.approve(address(liquidityRouter), 0);
        SwaputerSRC20MarketFactory marketFactory =
            new SwaputerSRC20MarketFactory(router, worldId, keccak256(escrow), keccak256(openMint));
        vm.stopBroadcast();

        require(marketFactory.router() == router, "MARKET_ROUTER_MISMATCH");
        require(marketFactory.worldId() == worldId, "MARKET_WORLD_MISMATCH");
        console2.log("FORK_BOOTSTRAP_LIQUIDITY_ROUTER", address(liquidityRouter));
        console2.log("FORK_BOOTSTRAP_MARKET_FACTORY", address(marketFactory));
        console2.log("FORK_BOOTSTRAP_OPEN_MINT_CODE_HASH");
        console2.logBytes32(keccak256(openMint));
        console2.log("FORK_BOOTSTRAP_ESCROW_CODE_HASH");
        console2.logBytes32(keccak256(escrow));
        console2.log("FORK_BOOTSTRAP_ACTOR", actor);
    }
}
