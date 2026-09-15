// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {SwaputerCreationCodeStore} from "../src/SwaputerCreationCodeStore.sol";
import {SwaputerToken} from "../src/SwaputerToken.sol";
import {SwaputerHook} from "../src/SwaputerHook.sol";
import {SwaputerKernel} from "../src/SwaputerKernel.sol";
import {SwaputerAppRouter} from "../src/SwaputerAppRouter.sol";
import {SwaputerWorldDeployer} from "../src/SwaputerWorldDeployer.sol";
import {SwaputerWorldFactory} from "../src/SwaputerWorldFactory.sol";

contract SwapVMStage7A2Test is Test {
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;
    using TransientStateLibrary for PoolManager;

    uint256 internal constant INITIAL_SUPPLY = 1e36;
    uint128 internal constant BYTE_GAS_PRICE = 1e12;
    uint24 internal constant POOL_FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    uint160 internal constant SQRT_PRICE_1_1 = 1 << 96;
    uint256 internal constant ACTOR_KEY = 0xA11CE;
    address internal constant FEE_ADMIN = address(0xFEE);
    address internal constant FEE_CONTROLLER = address(0xC0FFEE);

    PoolManager internal manager;
    SwaputerCreationCodeStore internal kernelCodeStore;
    SwaputerCreationCodeStore internal hookCodeStore;
    SwaputerWorldFactory internal factory;
    SwaputerAppRouter internal router;
    SwaputerToken internal token;
    SwaputerKernel internal kernel;
    SwaputerHook internal hook;
    PoolKey internal key;
    bytes32 internal worldId;
    address internal actor;

    function setUp() public virtual {
        vm.deal(address(this), 1e30);
        actor = vm.addr(ACTOR_KEY);
        vm.deal(actor, 100 ether);

        manager = new PoolManager(address(this));
        kernelCodeStore = new SwaputerCreationCodeStore(type(SwaputerKernel).creationCode);
        hookCodeStore = new SwaputerCreationCodeStore(type(SwaputerHook).creationCode);
        factory = new SwaputerWorldFactory(
            manager,
            address(manager).codehash,
            address(kernelCodeStore),
            address(hookCodeStore),
            FEE_ADMIN,
            FEE_CONTROLLER
        );
        router = SwaputerAppRouter(payable(factory.router()));

        SwaputerWorldFactory.CreateWorldParams memory params = _worldParams(bytes32(uint256(1)), bytes32(uint256(2)));
        (worldId, token, kernel, hook) = factory.createWorld(params);
        bool isSealed;
        (key, isSealed) = factory.getPoolKey(worldId);
        assertTrue(isSealed);

        PoolModifyLiquidityTest liquidityRouter = new PoolModifyLiquidityTest(manager);
        token.approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity{value: 1e25}(
            key,
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e24, salt: bytes32(0)}),
            bytes("")
        );
        vm.prank(FEE_ADMIN);
        hook.live();
    }

    function test_factoryPinsArtifactsDeploysAndSealsExactlyOnce() public view {
        assertEq(address(factory.poolManager()), address(manager));
        assertEq(factory.poolManagerCodeHash(), address(manager).codehash);
        assertEq(address(router.poolManager()), address(manager));
        assertEq(address(router.factory()), address(factory));
        assertEq(factory.initialProtocolFeeAdmin(), FEE_ADMIN);
        assertEq(factory.DEFAULT_PROTOCOL_FEE_BPS(), 300);
        assertEq(factory.initialProtocolFeeBps(), factory.DEFAULT_PROTOCOL_FEE_BPS());
        assertEq(hook.feeController(), FEE_CONTROLLER);
        assertEq(hook.protocolFeeBps(), 300);
        assertEq(hook.owner(), FEE_ADMIN);
        assertEq(hook.feeAdmin(), FEE_ADMIN);
        assertTrue(hook.tradingLive());
        assertTrue(hook.poolBound());
        assertEq(hook.boundPoolId(), worldId);
        assertEq(factory.kernelCreationCodeHash(), keccak256(type(SwaputerKernel).creationCode));
        assertEq(factory.hookCreationCodeHash(), keccak256(type(SwaputerHook).creationCode));
        assertEq(factory.EXPECTED_KERNEL_CREATION_CODE_HASH(), keccak256(type(SwaputerKernel).creationCode));
        assertEq(factory.EXPECTED_HOOK_CREATION_CODE_HASH(), keccak256(type(SwaputerHook).creationCode));
        assertEq(PoolId.unwrap(key.toId()), worldId);
        assertEq(Currency.unwrap(key.currency0), address(0));
        assertEq(Currency.unwrap(key.currency1), address(token));
        assertEq(address(key.hooks), address(hook));
        assertEq(kernel.hook(), address(hook));
        assertEq(address(hook.kernel()), address(kernel));
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(address(hook.gasToken()), address(token));
        assertEq(
            uint160(address(hook)) & Hooks.ALL_HOOK_MASK,
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        SwaputerWorldFactory.WorldConfig memory config = factory.getWorldConfig(worldId);
        assertTrue(config.isSealed);
        assertEq(config.configHash == bytes32(0), false);
        assertEq(config.gasToken, address(token));
        assertEq(config.kernel, address(kernel));
        assertEq(config.hook, address(hook));
        assertEq(config.byteGasPrice, BYTE_GAS_PRICE);
        assertEq(config.gasTokenCodeHash, address(token).codehash);
        assertEq(config.kernelCodeHash, address(kernel).codehash);
        assertEq(config.hookCodeHash, address(hook).codehash);
        assertTrue(SwaputerWorldDeployer(config.worldDeployer).used());
        assertEq(config.configHash, _worldConfigHash(worldId, config));
    }

    function test_tradingStartsClosedAndOnlyOwnerCanPermanentlyOpenIt() public {
        SwaputerWorldFactory.CreateWorldParams memory params =
            _worldParams(bytes32(uint256(101)), bytes32(uint256(102)));
        (bytes32 secondWorldId, SwaputerToken secondToken,, SwaputerHook secondHook) = factory.createWorld(params);
        (PoolKey memory secondKey, bool isSealed) = factory.getPoolKey(secondWorldId);

        assertTrue(isSealed);
        assertEq(secondHook.owner(), FEE_ADMIN);
        assertFalse(secondHook.tradingLive());

        PoolModifyLiquidityTest liquidityRouter = new PoolModifyLiquidityTest(manager);
        secondToken.approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity{value: 1e25}(
            secondKey,
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e24, salt: bytes32(0)}),
            bytes("")
        );

        bytes memory wrappedError = abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(secondHook),
            IHooks.beforeSwap.selector,
            abi.encodePacked(SwaputerHook.TradingNotLive.selector),
            abi.encodePacked(Hooks.HookCallFailed.selector)
        );
        vm.expectRevert(wrappedError);
        router.buyNOPExactInput{value: 1 ether}(secondWorldId, 1, TickMath.MIN_SQRT_PRICE + 1, address(this));

        vm.prank(actor);
        vm.expectRevert(abi.encodeWithSelector(SwaputerHook.OnlyOwner.selector, actor));
        secondHook.live();

        vm.prank(FEE_ADMIN);
        secondHook.live();
        assertTrue(secondHook.tradingLive());

        router.buyNOPExactInput{value: 1 ether}(secondWorldId, 1, TickMath.MIN_SQRT_PRICE + 1, address(this));

        vm.prank(FEE_ADMIN);
        vm.expectRevert(SwaputerHook.TradingAlreadyLive.selector);
        secondHook.live();
    }

    function test_hookPermanentlyRejectsAnyOtherPoolBinding() public {
        SwaputerToken otherToken = new SwaputerToken(1 ether, address(this));
        PoolKey memory otherKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(otherToken)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodePacked(SwaputerHook.InvalidWorld.selector),
                abi.encodePacked(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(otherKey, SQRT_PRICE_1_1);
    }

    function test_hookRejectsSecondInitializationOfItsBoundPool() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(SwaputerHook.HookAlreadyBound.selector, worldId),
                abi.encodePacked(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(key, SQRT_PRICE_1_1);
    }

    function test_anyRouterBuyPaysHookFeeFromGrossInput() public {
        PoolSwapTest aggregateRouter = new PoolSwapTest(manager);
        uint256 accruedBefore = hook.accruedProtocolFees();
        uint256 tokenBefore = token.balanceOf(actor);

        vm.prank(actor);
        BalanceDelta delta = aggregateRouter.swap{value: 1 ether}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );

        assertEq(delta.amount0(), -int128(1 ether), "caller pays the full gross amount");
        assertEq(token.balanceOf(actor) - tokenBefore, uint128(delta.amount1()));
        assertEq(hook.accruedProtocolFees() - accruedBefore, 0.03 ether);
        assertEq(_nativeFeeClaimBalance(), hook.accruedProtocolFees());
        assertEq(manager.getNonzeroDeltaCount(), 0);
    }

    function test_buyAccruesFeeBeforeNativeInputIsSettled() public {
        vm.deal(address(manager), 0);

        router.buyNOPExactInput{value: 1 ether}(worldId, 1, TickMath.MIN_SQRT_PRICE + 1, actor);

        assertEq(hook.accruedProtocolFees(), 0.03 ether);
        assertEq(_nativeFeeClaimBalance(), 0.03 ether);
        assertEq(address(manager).balance, 1 ether);
        assertEq(manager.getNonzeroDeltaCount(), 0);
    }

    function test_anyRouterSellPaysHookFeeFromGrossOutput() public {
        router.buyNOPExactInput{value: 2 ether}(worldId, 1, TickMath.MIN_SQRT_PRICE + 1, actor);
        PoolSwapTest aggregateRouter = new PoolSwapTest(manager);
        vm.prank(actor);
        token.approve(address(aggregateRouter), type(uint256).max);
        uint256 accruedBefore = hook.accruedProtocolFees();
        uint256 ethBefore = actor.balance;

        vm.prank(actor);
        BalanceDelta delta = aggregateRouter.swap(
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: -int256(0.25 ether), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("aggregator-metadata")
        );

        uint256 netEthOut = uint128(delta.amount0());
        uint256 chargedFee = hook.accruedProtocolFees() - accruedBefore;
        uint256 grossEthOut = netEthOut + chargedFee;
        assertEq(chargedFee, grossEthOut * 300 / 10_000);
        assertEq(actor.balance - ethBefore, netEthOut);
        assertEq(manager.getNonzeroDeltaCount(), 0);
    }

    function test_exactOutputCannotBypassHookFeeThroughAnyRouter() public {
        PoolSwapTest aggregateRouter = new PoolSwapTest(manager);
        bytes memory wrappedError = abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.beforeSwap.selector,
            abi.encodePacked(SwaputerHook.ExactOutputUnsupported.selector),
            abi.encodePacked(Hooks.HookCallFailed.selector)
        );
        vm.expectRevert(wrappedError);
        aggregateRouter.swap{value: 1 ether}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: int256(0.1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );

        vm.expectRevert(wrappedError);
        aggregateRouter.swap(
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: int256(0.1 ether), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
    }

    function test_manifestWorldConfigGoldenVectorMatchesTypeScript() public view {
        PoolKey memory vectorKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(7)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(9))
        });
        bytes32 vectorWorldId = PoolId.unwrap(vectorKey.toId());
        bytes32 vector = keccak256(
            abi.encode(
                factory.WORLD_CONFIG_TYPEHASH(),
                uint256(31337),
                address(2),
                address(1),
                bytes32(uint256(101)),
                address(10),
                address(3),
                vectorWorldId,
                address(4),
                address(7),
                address(8),
                address(9),
                uint256(1_000_000 ether),
                address(20),
                bytes32(uint256(701)),
                uint128(1e12),
                uint24(3000),
                int24(60),
                uint160(1 << 96),
                bytes32(uint256(107)),
                bytes32(uint256(108)),
                bytes32(uint256(109))
            )
        );
        assertEq(vector, 0x2e83890640ddf1743e749e9f0aa79c8ebb6705b8c9ba74dabeee961665bd4fa3);
    }

    function test_worldDeployerIsOneShotAndFactoryOnly() public {
        SwaputerWorldFactory.WorldConfig memory config = factory.getWorldConfig(worldId);
        SwaputerWorldDeployer deployer = SwaputerWorldDeployer(config.worldDeployer);

        vm.expectPartialRevert(SwaputerWorldDeployer.OnlyFactory.selector);
        deployer.deploy(address(0), address(0), manager, token, FEE_ADMIN, FEE_CONTROLLER, 300, 0, 0, 0, bytes32(0));

        vm.prank(address(factory));
        vm.expectRevert(SwaputerWorldDeployer.AlreadyUsed.selector);
        deployer.deploy(address(0), address(0), manager, token, FEE_ADMIN, FEE_CONTROLLER, 300, 0, 0, 0, bytes32(0));
    }

    function test_factoryRejectsWrongManagerAndArtifactHashes() public {
        vm.expectPartialRevert(SwaputerWorldFactory.PoolManagerCodeHashMismatch.selector);
        new SwaputerWorldFactory(
            manager,
            bytes32(uint256(1)),
            address(kernelCodeStore),
            address(hookCodeStore),
            address(0xFEE),
            address(0xC0FFEE)
        );

        SwaputerCreationCodeStore badStore = new SwaputerCreationCodeStore(hex"00");
        vm.expectPartialRevert(SwaputerWorldDeployer.KernelCreationCodeMismatch.selector);
        new SwaputerWorldFactory(
            manager,
            address(manager).codehash,
            address(badStore),
            address(hookCodeStore),
            address(0xFEE),
            address(0xC0FFEE)
        );
    }

    function test_factoryWrongHookPredictionRollsBackTokenAndWorldDeployer() public {
        bytes32 tokenSalt = bytes32(uint256(101));
        bytes32 bootstrapSalt = bytes32(uint256(102));
        SwaputerWorldFactory.CreateWorldParams memory params = _worldParams(tokenSalt, bootstrapSalt);
        address predictedToken = factory.predictGasToken(tokenSalt, INITIAL_SUPPLY, address(this));
        address predictedWorldDeployer = factory.predictWorldDeployer(bootstrapSalt);
        params.predictedHook = address(uint160(params.predictedHook) + 1);

        vm.expectPartialRevert(SwaputerWorldFactory.HookPredictionMismatch.selector);
        factory.createWorld(params);
        assertEq(predictedToken.code.length, 0);
        assertEq(predictedWorldDeployer.code.length, 0);
        assertEq(params.predictedKernel.code.length, 0);
    }

    function test_routerNOPBuyBurnsAndPreservesForcedHistoricalEth() public {
        uint256 forcedBalance = 7 ether;
        vm.deal(address(router), forcedBalance);
        uint256 balanceBefore = token.balanceOf(address(this));
        uint256 supplyBefore = token.totalSupply();
        uint256 accruedBefore = hook.accruedProtocolFees();

        BalanceDelta delta =
            router.buyNOPExactInput{value: 1 ether}(worldId, 1, TickMath.MIN_SQRT_PRICE + 1, address(this));

        uint256 received = token.balanceOf(address(this)) - balanceBefore;
        assertEq(received, uint128(delta.amount1()));
        assertGt(received, 1);
        assertEq(supplyBefore - token.totalSupply(), BYTE_GAS_PRICE);
        assertEq(kernel.executionHeight(worldId), 1);
        assertEq(kernel.executedBytes(worldId), 1);
        assertEq(address(router).balance, forcedBalance, "refund cannot sweep forced historical ETH");
        assertEq(hook.accruedProtocolFees() - accruedBefore, 0.03 ether);
        assertEq(_nativeFeeClaimBalance(), hook.accruedProtocolFees());
        assertEq(manager.getNonzeroDeltaCount(), 0);
    }

    function test_protocolFeeCanBeAdjustedOnlyByControllerWithinCap() public {
        assertEq(hook.protocolFee(100 ether), 3 ether);
        assertEq(hook.netNativeAfterFee(100 ether), 97 ether);

        vm.prank(actor);
        vm.expectRevert(abi.encodeWithSelector(SwaputerHook.UnauthorizedFeeController.selector, FEE_CONTROLLER, actor));
        hook.setProtocolFeeBps(250);

        vm.prank(FEE_CONTROLLER);
        hook.setProtocolFeeBps(250);
        assertEq(hook.protocolFeeBps(), 250);
        assertEq(hook.protocolFee(100 ether), 2.5 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                SwaputerHook.ProtocolFeeTooHigh.selector, uint256(1_001), uint256(hook.MAX_PROTOCOL_FEE_BPS())
            )
        );
        vm.prank(FEE_CONTROLLER);
        hook.setProtocolFeeBps(1_001);
    }

    function test_hookFeeAdminClaimsAccountedFeesAndCanTransfer() public {
        vm.deal(address(hook), 7 ether);
        router.buyNOPExactInput{value: 1 ether}(worldId, 1, TickMath.MIN_SQRT_PRICE + 1, address(this));
        assertEq(hook.accruedProtocolFees(), 0.03 ether);
        assertEq(_nativeFeeClaimBalance(), 0.03 ether);
        assertEq(address(hook).balance, 7 ether);

        vm.prank(actor);
        vm.expectRevert(abi.encodeWithSelector(SwaputerHook.OnlyFeeAdmin.selector, actor));
        hook.claimProtocolFees();

        address newAdmin = address(0xBEEF);
        vm.prank(FEE_ADMIN);
        hook.transferAdmin(newAdmin);
        assertEq(hook.feeAdmin(), newAdmin);
        assertEq(hook.owner(), FEE_ADMIN, "one-time launch owner must remain immutable");

        vm.prank(FEE_ADMIN);
        vm.expectRevert(abi.encodeWithSelector(SwaputerHook.OnlyFeeAdmin.selector, FEE_ADMIN));
        hook.transferAdmin(actor);

        uint256 adminBalanceBefore = newAdmin.balance;
        vm.prank(newAdmin);
        assertEq(hook.claimProtocolFees(), 0.03 ether);
        assertEq(newAdmin.balance - adminBalanceBefore, 0.03 ether);
        assertEq(hook.accruedProtocolFees(), 0);
        assertEq(_nativeFeeClaimBalance(), 0);
        assertEq(address(hook).balance, 7 ether, "forced ETH is not claimable as protocol fees");
    }

    function _nativeFeeClaimBalance() private view returns (uint256) {
        return manager.balanceOf(address(hook), Currency.wrap(address(0)).toId());
    }

    function testFuzz_routerNOPBuySettlementAndBurn(uint96 rawInput) public {
        uint256 ethIn = bound(uint256(rawInput), 1e15, 10 ether);
        uint256 balanceBefore = token.balanceOf(actor);
        uint256 supplyBefore = token.totalSupply();

        BalanceDelta delta = router.buyNOPExactInput{value: ethIn}(worldId, 1, TickMath.MIN_SQRT_PRICE + 1, actor);

        assertEq(token.balanceOf(actor) - balanceBefore, uint128(delta.amount1()));
        assertEq(supplyBefore - token.totalSupply(), BYTE_GAS_PRICE);
        assertEq(kernel.executionHeight(worldId), 1);
        assertEq(kernel.executedBytes(worldId), 1);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertEq(address(router).balance, 0);
    }

    function test_routerSellBypassesVMAndBurn() public {
        router.buyNOPExactInput{value: 2 ether}(worldId, 1, TickMath.MIN_SQRT_PRICE + 1, address(this));
        uint64 heightBefore = kernel.executionHeight(worldId);
        uint256 supplyBefore = token.totalSupply();
        uint256 ethBefore = address(this).balance;
        uint256 feeBalanceBefore = hook.accruedProtocolFees();
        token.approve(address(router), type(uint256).max);

        BalanceDelta delta =
            router.sellExactInput(worldId, uint128(0.25 ether), 1, TickMath.MAX_SQRT_PRICE - 1, address(this));

        assertGt(delta.amount0(), 0);
        assertLt(delta.amount1(), 0);
        assertGt(address(this).balance, ethBefore);
        uint256 netEthOut = uint256(uint128(delta.amount0()));
        uint256 chargedFee = hook.accruedProtocolFees() - feeBalanceBefore;
        uint256 grossEthOut = netEthOut + chargedFee;
        assertEq(chargedFee, grossEthOut * 300 / 10_000);
        assertEq(address(this).balance - ethBefore, netEthOut);
        assertEq(kernel.executionHeight(worldId), heightBefore);
        assertEq(token.totalSupply(), supplyBefore);
        assertEq(manager.getNonzeroDeltaCount(), 0);
    }

    function test_routerMinimumOutputFailureRollsBackBurnHeightAndSettlement() public {
        uint256 supplyBefore = token.totalSupply();
        uint256 balanceBefore = token.balanceOf(address(this));

        vm.expectPartialRevert(SwaputerAppRouter.MinimumOutputNotMet.selector);
        router.buyNOPExactInput{value: 1 ether}(worldId, type(uint128).max, TickMath.MIN_SQRT_PRICE + 1, address(this));

        assertEq(token.totalSupply(), supplyBefore);
        assertEq(token.balanceOf(address(this)), balanceBefore);
        assertEq(kernel.executionHeight(worldId), 0);
        assertEq(kernel.executedBytes(worldId), 0);
        assertEq(manager.getNonzeroDeltaCount(), 0);
    }

    function test_routerFailedSignedVMExecutionRollsBackNonceBurnAndHeight() public {
        bytes32 missingTarget = bytes32(uint256(0x0101));
        SwaputerKernel.VMEnvelope memory action = _signedAction(
            SwaputerKernel.RootOp.CALL,
            missingTarget,
            bytes(""),
            10,
            0,
            0,
            actor,
            actor,
            1 ether,
            TickMath.MIN_SQRT_PRICE + 1,
            address(router)
        );
        uint256 supplyBefore = token.totalSupply();

        vm.prank(actor);
        vm.expectRevert();
        router.buyVMExactInput{value: 1 ether}(worldId, TickMath.MIN_SQRT_PRICE + 1, action);

        bytes32 actorId = kernel.eoaAccountId(actor);
        assertEq(kernel.executionHeight(worldId), 0);
        assertEq(kernel.executedBytes(worldId), 0);
        assertEq(kernel.nonces(worldId, actorId), 0);
        assertEq(token.totalSupply(), supplyBefore);
        assertEq(manager.getNonzeroDeltaCount(), 0);
    }

    function test_routerRejectsSignedNOPAndInputPastUint128() public {
        SwaputerKernel.VMEnvelope memory action;
        action.op = SwaputerKernel.RootOp.NOP;
        action.worldId = worldId;

        vm.expectRevert(SwaputerAppRouter.SignedNOPForbidden.selector);
        router.buyVMExactInput{value: 1 ether}(worldId, TickMath.MIN_SQRT_PRICE + 1, action);

        uint256 tooLarge = uint256(type(uint128).max) + 1;
        vm.deal(address(this), tooLarge);
        vm.expectPartialRevert(SwaputerAppRouter.InvalidExactInput.selector);
        router.buyNOPExactInput{value: tooLarge}(worldId, 0, TickMath.MIN_SQRT_PRICE + 1, address(this));
    }

    function test_routerFrozenEnvelopeBindingsAndPermissionlessRelay() public {
        bytes memory packageBytes = _package(0, 0, keccak256("Stage7A2.Relay"), hex"00");
        bytes32 codeHash = keccak256(packageBytes);
        bytes memory payload = abi.encodePacked(bytes4(uint32(packageBytes.length)), packageBytes);
        SwaputerKernel.VMEnvelope memory wrongInput = _signedAction(
            SwaputerKernel.RootOp.DEPLOY,
            codeHash,
            payload,
            10,
            0,
            0,
            actor,
            address(0),
            2 ether,
            TickMath.MIN_SQRT_PRICE + 1,
            address(router)
        );
        vm.expectRevert();
        router.buyVMExactInput{value: 1 ether}(worldId, TickMath.MIN_SQRT_PRICE + 1, wrongInput);

        SwaputerKernel.VMEnvelope memory relayed = _signedAction(
            SwaputerKernel.RootOp.DEPLOY,
            codeHash,
            payload,
            10,
            0,
            0,
            actor,
            address(0),
            1 ether,
            TickMath.MIN_SQRT_PRICE + 1,
            address(router)
        );
        router.buyVMExactInput{value: 1 ether}(worldId, TickMath.MIN_SQRT_PRICE + 1, relayed);
        assertEq(kernel.executionHeight(worldId), 1);
        assertEq(kernel.nonces(worldId, kernel.eoaAccountId(actor)), 1);
        assertGt(token.balanceOf(actor), 0);
        assertEq(manager.getNonzeroDeltaCount(), 0);
    }

    function test_routerSignedDeployAndCallUseFrozenVMEnvelope() public {
        bytes memory packageBytes = _package(0, 0, keccak256("Stage7A2.Stop"), hex"00");
        bytes32 codeHash = keccak256(packageBytes);
        bytes memory deployPayload = abi.encodePacked(bytes4(uint32(packageBytes.length)), packageBytes);
        SwaputerKernel.VMEnvelope memory deployAction = _signedAction(
            SwaputerKernel.RootOp.DEPLOY,
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
        bytes32 actorId = kernel.eoaAccountId(actor);
        bytes32 contractId = kernel.contractAccountId(worldId, actorId, 0, codeHash);

        vm.prank(actor);
        router.buyVMExactInput{value: 1 ether}(worldId, TickMath.MIN_SQRT_PRICE + 1, deployAction);
        assertEq(kernel.programCodeHash(worldId, contractId), codeHash);
        assertEq(kernel.executionHeight(worldId), 1);

        SwaputerKernel.VMEnvelope memory callAction = _signedAction(
            SwaputerKernel.RootOp.CALL,
            contractId,
            bytes(""),
            10,
            0,
            1,
            actor,
            actor,
            1 ether,
            TickMath.MIN_SQRT_PRICE + 1,
            address(router)
        );
        vm.prank(actor);
        router.buyVMExactInput{value: 1 ether}(worldId, TickMath.MIN_SQRT_PRICE + 1, callAction);
        assertEq(kernel.executionHeight(worldId), 2);
        assertEq(kernel.executedBytes(worldId), 1);
        assertEq(kernel.nonces(worldId, actorId), 2);
    }

    function test_routerReturnsVMOutputAndHookClearsTransientResult() public {
        bytes memory packageBytes = _package(0, 1, keccak256("Stage7A2.Result"), hex"00602a5f5260205ff3");
        bytes32 codeHash = keccak256(packageBytes);
        bytes memory deployPayload = abi.encodePacked(bytes4(uint32(packageBytes.length)), packageBytes);
        SwaputerKernel.VMEnvelope memory deployAction = _signedAction(
            SwaputerKernel.RootOp.DEPLOY,
            codeHash,
            deployPayload,
            1,
            0,
            0,
            actor,
            actor,
            1 ether,
            TickMath.MIN_SQRT_PRICE + 1,
            address(router)
        );
        bytes32 actorId = kernel.eoaAccountId(actor);
        bytes32 contractId = kernel.contractAccountId(worldId, actorId, 0, codeHash);

        vm.prank(actor);
        router.buyVMExactInput{value: 1 ether}(worldId, TickMath.MIN_SQRT_PRICE + 1, deployAction);

        SwaputerKernel.VMEnvelope memory callAction = _signedAction(
            SwaputerKernel.RootOp.CALL,
            contractId,
            bytes(""),
            8,
            0,
            1,
            actor,
            actor,
            1 ether,
            TickMath.MIN_SQRT_PRICE + 1,
            address(router)
        );
        vm.prank(actor);
        (, bytes32 result, uint32 resultLength) =
            router.buyVMExactInputWithResult{value: 1 ether}(worldId, TickMath.MIN_SQRT_PRICE + 1, callAction);
        assertEq(result, bytes32(uint256(42)));
        assertEq(resultLength, 32);

        vm.expectRevert(abi.encodeWithSelector(SwaputerHook.VMResultUnavailable.selector, address(this)));
        hook.consumeVMResult();
    }

    function test_routerRejectsUnauthorizedExecutorUnsealedWorldAndDirectCallback() public {
        SwaputerKernel.VMEnvelope memory action;
        action.op = SwaputerKernel.RootOp.CALL;
        action.worldId = worldId;
        action.actor = actor;
        action.recipient = actor;
        action.authorizedExecutor = actor;

        vm.expectPartialRevert(SwaputerAppRouter.UnauthorizedExecutor.selector);
        router.buyVMExactInput{value: 1 ether}(worldId, TickMath.MIN_SQRT_PRICE + 1, action);

        vm.expectPartialRevert(SwaputerAppRouter.WorldNotSealed.selector);
        router.buyNOPExactInput{value: 1 ether}(bytes32(uint256(0xBAD)), 0, TickMath.MIN_SQRT_PRICE + 1, address(this));

        vm.expectPartialRevert(SwaputerAppRouter.OnlyPoolManager.selector);
        router.unlockCallback(bytes(""));
    }

    function _worldParams(bytes32 tokenSalt, bytes32 bootstrapSalt)
        internal
        view
        returns (SwaputerWorldFactory.CreateWorldParams memory params)
    {
        address predictedToken = factory.predictGasToken(tokenSalt, INITIAL_SUPPLY, address(this));
        address predictedWorldDeployer = factory.predictWorldDeployer(bootstrapSalt);
        address predictedKernel = factory.predictKernel(predictedWorldDeployer);
        bytes memory hookArgs = abi.encode(
            manager,
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
        params = SwaputerWorldFactory.CreateWorldParams({
            tokenSalt: tokenSalt,
            bootstrapSalt: bootstrapSalt,
            hookSalt: hookSalt,
            predictedKernel: predictedKernel,
            predictedHook: predictedHook,
            initialSupply: INITIAL_SUPPLY,
            initialHolder: address(this),
            distributionCommitment: keccak256("stage7a2-test-distribution"),
            byteGasPrice: BYTE_GAS_PRICE,
            poolFee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            initialSqrtPriceX96: SQRT_PRICE_1_1
        });
    }

    function _worldConfigHash(bytes32 id, SwaputerWorldFactory.WorldConfig memory config)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                factory.WORLD_CONFIG_TYPEHASH(),
                block.chainid,
                address(factory),
                address(manager),
                factory.poolManagerCodeHash(),
                address(router),
                address(factory.referenceRegistry()),
                id,
                config.worldDeployer,
                config.gasToken,
                config.kernel,
                config.hook,
                config.initialSupply,
                config.initialHolder,
                config.distributionCommitment,
                config.byteGasPrice,
                config.poolFee,
                config.tickSpacing,
                config.initialSqrtPriceX96,
                config.gasTokenCodeHash,
                config.kernelCodeHash,
                config.hookCodeHash
            )
        );
    }

    function _signedAction(
        SwaputerKernel.RootOp op,
        bytes32 target,
        bytes memory payload,
        uint32 limit,
        uint128 minNet,
        uint64 nonce,
        address recipient,
        address executor,
        uint128 ethIn,
        uint160 priceLimit,
        address routerAddress
    ) internal view returns (SwaputerKernel.VMEnvelope memory action) {
        action = SwaputerKernel.VMEnvelope({
            op: op,
            worldId: worldId,
            actor: vm.addr(ACTOR_KEY),
            targetOrCodeHash: target,
            payload: payload,
            byteGasLimit: limit,
            minNetTokenOut: minNet,
            nonce: nonce,
            deadline: uint64(block.timestamp + 1 days),
            recipient: recipient,
            authorizedExecutor: executor,
            signature: bytes("")
        });
        bytes32 structHash = keccak256(
            abi.encode(
                kernel.VM_ACTION_TYPEHASH(),
                uint8(action.op),
                action.worldId,
                action.actor,
                action.targetOrCodeHash,
                keccak256(action.payload),
                action.byteGasLimit,
                action.minNetTokenOut,
                ethIn,
                priceLimit,
                action.recipient,
                routerAddress,
                action.authorizedExecutor,
                action.nonce,
                action.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", kernel.domainSeparator(worldId), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ACTOR_KEY, digest);
        action.signature = abi.encodePacked(r, s, v);
    }

    function _package(uint16 constructorEntry, uint16 runtimeEntry, bytes32 abiHash, bytes memory code)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(
            bytes4(0x53564d31),
            bytes2(uint16(1)),
            bytes2(constructorEntry),
            bytes2(runtimeEntry),
            bytes2(uint16(code.length)),
            abiHash,
            code
        );
    }

    receive() external payable {}
}
