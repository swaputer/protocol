// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import {BaseSepoliaSPuter, BaseSepoliaTestETH} from "../../src/testnet/SwaputerTestTokens.sol";

/// @notice Shared exact-curve rehearsal using ERC-20 tETH instead of scarce native test ETH.
/// @dev No production Swaputer contracts or deployment records are modified by this test.
abstract contract SwaputerSPuterCurveTestBase is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint24 internal constant POOL_FEE = 3_000;
    int24 internal constant TICK_SPACING = 60;
    uint256 internal constant PROTOCOL_FEE_BPS = 300;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant INITIAL_PRICE_WAD = 0.0004 ether;
    uint256 internal constant Q192 = 1 << 192;

    address internal constant BUYER = address(0xB0B);
    address internal constant FEE_RECIPIENT = address(0xFEE);

    IPoolManager internal manager;
    PoolModifyLiquidityTest internal liquidityRouter;
    PoolSwapTest internal swapRouter;
    BaseSepoliaTestETH internal testEth;
    BaseSepoliaSPuter internal sPuter;
    PoolKey internal poolKey;
    bool internal quoteIsCurrency0;
    uint256 internal totalSPuterDeposited;

    function _setUpCurve(IPoolManager selectedManager) internal {
        manager = selectedManager;
        liquidityRouter = new PoolModifyLiquidityTest(manager);
        swapRouter = new PoolSwapTest(manager);
        testEth = new BaseSepoliaTestETH();
        sPuter = new BaseSepoliaSPuter(address(this));
        quoteIsCurrency0 = address(testEth) < address(sPuter);

        poolKey = quoteIsCurrency0
            ? PoolKey({
                currency0: Currency.wrap(address(testEth)),
                currency1: Currency.wrap(address(sPuter)),
                fee: POOL_FEE,
                tickSpacing: TICK_SPACING,
                hooks: IHooks(address(0))
            })
            : PoolKey({
                currency0: Currency.wrap(address(sPuter)),
                currency1: Currency.wrap(address(testEth)),
                fee: POOL_FEE,
                tickSpacing: TICK_SPACING,
                hooks: IHooks(address(0))
            });

        manager.initialize(poolKey, _sqrtPriceX96ForEthPerSPuter(INITIAL_PRICE_WAD));
        sPuter.approve(address(liquidityRouter), type(uint256).max);
        _addCurvePositions();
        sPuter.approve(address(liquidityRouter), 0);

        testEth.mint(BUYER, 1_000_000 ether);
        vm.prank(BUYER);
        testEth.approve(address(swapRouter), type(uint256).max);
    }

    function _addCurvePositions() private {
        uint256[6] memory lowerPrices = [
            uint256(0.0004 ether),
            uint256(0.0006 ether),
            uint256(0.0009 ether),
            uint256(0.0012 ether),
            uint256(0.0024 ether),
            uint256(0.0096 ether)
        ];
        uint256[6] memory tokenAmounts = [
            uint256(50 ether),
            uint256(150 ether),
            uint256(800 ether),
            uint256(1_500 ether),
            uint256(2_500 ether),
            uint256(5_000 ether)
        ];

        int24[6] memory boundaries;
        for (uint256 i; i < boundaries.length; ++i) {
            int24 rawTick = TickMath.getTickAtSqrtPrice(_sqrtPriceX96ForEthPerSPuter(lowerPrices[i]));
            boundaries[i] = quoteIsCurrency0 ? _floorToSpacing(rawTick) : _ceilToSpacing(rawTick);
        }

        uint256 balanceBefore = sPuter.balanceOf(address(this));
        for (uint256 i; i < tokenAmounts.length; ++i) {
            int24 tickLower;
            int24 tickUpper;
            if (quoteIsCurrency0) {
                tickUpper = boundaries[i];
                tickLower = i + 1 < boundaries.length ? boundaries[i + 1] : TickMath.minUsableTick(TICK_SPACING);
            } else {
                tickLower = boundaries[i];
                tickUpper = i + 1 < boundaries.length ? boundaries[i + 1] : TickMath.maxUsableTick(TICK_SPACING);
            }
            require(tickLower < tickUpper, "INVALID_TICK_ORDER");

            uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
            uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
            uint128 liquidity = quoteIsCurrency0
                ? LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtUpper, tokenAmounts[i])
                : LiquidityAmounts.getLiquidityForAmount0(sqrtLower, sqrtUpper, tokenAmounts[i]);
            require(liquidity != 0, "ZERO_LIQUIDITY");

            console2.log("SPUTER_CURVE_POSITION", i + 1);
            console2.log("SPUTER_CURVE_TICK_LOWER", int256(tickLower));
            console2.log("SPUTER_CURVE_TICK_UPPER", int256(tickUpper));
            console2.log("SPUTER_CURVE_POSITION_TOKEN_TARGET", tokenAmounts[i]);
            console2.log("SPUTER_CURVE_POSITION_LIQUIDITY", liquidity);

            liquidityRouter.modifyLiquidity(
                poolKey,
                ModifyLiquidityParams({
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: int256(uint256(liquidity)),
                    salt: bytes32(i + 1)
                }),
                bytes("")
            );
        }
        totalSPuterDeposited = balanceBefore - sPuter.balanceOf(address(this));
        assertApproxEqAbs(totalSPuterDeposited, 10_000 ether, 1_000, "all sPuter deposited one-sided");
        assertEq(testEth.balanceOf(address(manager)), 0, "no tETH deposited initially");
    }

    function _buyWithGrossTeth(uint256 grossTeth) internal returns (uint256 tokenOut) {
        uint256 protocolFee = grossTeth * PROTOCOL_FEE_BPS / BPS;
        uint256 swapInput = grossTeth - protocolFee;
        vm.startPrank(BUYER);
        testEth.transfer(FEE_RECIPIENT, protocolFee);
        uint256 tokenBefore = sPuter.balanceOf(BUYER);
        BalanceDelta delta = swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: quoteIsCurrency0,
                amountSpecified: -int256(swapInput),
                sqrtPriceLimitX96: quoteIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
        vm.stopPrank();
        tokenOut = sPuter.balanceOf(BUYER) - tokenBefore;
        assertTrue(BalanceDelta.unwrap(delta) != 0, "swap produced no delta");
    }

    function _spotPriceWad() internal view returns (uint256 priceWad) {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolKey.toId());
        uint256 ratioX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        priceWad =
            quoteIsCurrency0 ? FullMath.mulDiv(1 ether, Q192, ratioX192) : FullMath.mulDiv(1 ether, ratioX192, Q192);
    }

    function _sqrtPriceX96ForEthPerSPuter(uint256 priceWad) internal view returns (uint160 sqrtPriceX96) {
        uint256 ratioWad = quoteIsCurrency0 ? 1e36 / priceWad : priceWad;
        uint256 sqrtRatioWad = Math.sqrt(ratioWad);
        sqrtPriceX96 = uint160(FullMath.mulDiv(sqrtRatioWad, 1 << 96, 1e9));
    }

    function _floorToSpacing(int24 tick) private pure returns (int24) {
        int24 compressed = tick / TICK_SPACING;
        if (tick < 0 && tick % TICK_SPACING != 0) --compressed;
        return compressed * TICK_SPACING;
    }

    function _ceilToSpacing(int24 tick) private pure returns (int24) {
        int24 compressed = tick / TICK_SPACING;
        if (tick > 0 && tick % TICK_SPACING != 0) ++compressed;
        return compressed * TICK_SPACING;
    }

    function _assertCurveCheckpoints() internal {
        uint256 soldAfterOne = _buyWithGrossTeth(1 ether);
        uint256 priceAfterOne = _spotPriceWad();
        assertApproxEqAbs(soldAfterOne, 1_000 ether, 15 ether, "1 tETH token output");
        assertApproxEqAbs(priceAfterOne, 0.0012 ether, 0.00005 ether, "1 tETH spot price");

        uint256 soldToFiveThousand = _buyWithGrossTeth(15.04 ether);
        uint256 cumulativeSold = soldAfterOne + soldToFiveThousand;
        uint256 priceAfterFiveThousand = _spotPriceWad();
        assertApproxEqAbs(cumulativeSold, 5_000 ether, 30 ether, "5,000 sPuter checkpoint");
        assertApproxEqAbs(priceAfterFiveThousand, 0.0096 ether, 0.0005 ether, "5,000 spot price");

        uint256 soldToEightThousand = _buyWithGrossTeth(74.45 ether);
        cumulativeSold += soldToEightThousand;
        uint256 priceAfterEightThousand = _spotPriceWad();
        assertApproxEqAbs(cumulativeSold, 8_000 ether, 40 ether, "8,000 sPuter checkpoint");
        assertApproxEqAbs(priceAfterEightThousand, 0.06 ether, 0.004 ether, "8,000 spot price");

        console2.log("SPUTER_CURVE_QUOTE_IS_CURRENCY0", quoteIsCurrency0);
        console2.log("SPUTER_CURVE_DEPOSITED", totalSPuterDeposited);
        console2.log("SPUTER_CURVE_SOLD_AFTER_1_TETH", soldAfterOne);
        console2.log("SPUTER_CURVE_PRICE_AFTER_1_TETH_WAD", priceAfterOne);
        console2.log("SPUTER_CURVE_SOLD_AT_5K_CHECKPOINT", cumulativeSold - soldToEightThousand);
        console2.log("SPUTER_CURVE_PRICE_AT_5K_CHECKPOINT_WAD", priceAfterFiveThousand);
        console2.log("SPUTER_CURVE_SOLD_AT_FINAL_CHECKPOINT", cumulativeSold);
        console2.log("SPUTER_CURVE_PRICE_AT_FINAL_CHECKPOINT_WAD", priceAfterEightThousand);
        console2.log("SPUTER_CURVE_LP_TETH_BALANCE", testEth.balanceOf(address(manager)));
        console2.log("SPUTER_CURVE_PROTOCOL_FEE_BALANCE", testEth.balanceOf(FEE_RECIPIENT));
    }

    function _assertSellReversesCurve() internal {
        uint256 bought = _buyWithGrossTeth(1 ether);
        uint256 peakPrice = _spotPriceWad();
        uint256 quoteBefore = testEth.balanceOf(BUYER);

        vm.startPrank(BUYER);
        sPuter.approve(address(swapRouter), bought);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: !quoteIsCurrency0,
                amountSpecified: -int256(bought),
                sqrtPriceLimitX96: quoteIsCurrency0 ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
        sPuter.approve(address(swapRouter), 0);
        vm.stopPrank();

        uint256 quoteOut = testEth.balanceOf(BUYER) - quoteBefore;
        uint256 priceAfterSell = _spotPriceWad();
        assertGt(quoteOut, 0, "sell returned no tETH");
        assertLt(priceAfterSell, peakPrice, "sell did not lower price");
        assertApproxEqAbs(priceAfterSell, INITIAL_PRICE_WAD, 0.00002 ether, "round trip price");

        console2.log("SPUTER_CURVE_ROUND_TRIP_BOUGHT", bought);
        console2.log("SPUTER_CURVE_ROUND_TRIP_TETH_OUT", quoteOut);
        console2.log("SPUTER_CURVE_ROUND_TRIP_PEAK_PRICE_WAD", peakPrice);
        console2.log("SPUTER_CURVE_ROUND_TRIP_FINAL_PRICE_WAD", priceAfterSell);
    }
}

contract SwaputerSPuterLocalCurveTest is SwaputerSPuterCurveTestBase {
    function setUp() public {
        _setUpCurve(IPoolManager(address(new PoolManager(address(this)))));
    }

    function test_balancedMultiRangeCurveWithErc20Teth() public {
        _assertCurveCheckpoints();
    }

    function test_sellReversesTheCurveWithoutNativeEth() public {
        _assertSellReversesCurve();
    }
}

contract SwaputerSPuterBaseSepoliaForkTest is SwaputerSPuterCurveTestBase {
    uint256 private constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    address private constant BASE_SEPOLIA_POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    bytes32 private constant BASE_SEPOLIA_POOL_MANAGER_CODE_HASH =
        0x03c45db6d09b14da7c1f7239a5a49697f976d395277e6d2acb6fbed3f9e0249f;

    modifier onlyBaseSepoliaFork() {
        vm.skip(block.chainid != BASE_SEPOLIA_CHAIN_ID, "requires a Base Sepolia fork");
        _;
    }

    function setUp() public {
        if (block.chainid != BASE_SEPOLIA_CHAIN_ID) return;
        assertEq(BASE_SEPOLIA_POOL_MANAGER.codehash, BASE_SEPOLIA_POOL_MANAGER_CODE_HASH, "PoolManager code hash");
        _setUpCurve(IPoolManager(BASE_SEPOLIA_POOL_MANAGER));
    }

    function test_baseSepoliaOfficialPoolManagerErc20TethCurve() public onlyBaseSepoliaFork {
        _assertCurveCheckpoints();
    }

    function test_baseSepoliaErc20TethSellReversesCurve() public onlyBaseSepoliaFork {
        _assertSellReversesCurve();
    }
}
