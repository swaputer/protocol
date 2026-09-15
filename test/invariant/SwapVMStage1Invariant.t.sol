// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {SwaputerToken} from "../../src/SwaputerToken.sol";
import {SwaputerHook} from "../../src/SwaputerHook.sol";
import {SwaputerKernel} from "../../src/SwaputerKernel.sol";

contract SwapVMStage1Handler is Test {
    PoolSwapTest private immutable _router;
    SwaputerToken private immutable _token;
    PoolKey private _key;

    uint256 public successfulBuys;
    uint256 public successfulSells;

    constructor(PoolSwapTest router, SwaputerToken token, PoolKey memory key_) {
        _router = router;
        _token = token;
        _key = key_;
        token.approve(address(router), type(uint256).max);
    }

    function buy(uint96 rawAmount) external {
        uint256 amount = bound(uint256(rawAmount), 2e12, 5 ether);
        try _router.swap{value: amount}(
            _key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            _settings(),
            bytes("")
        ) returns (
            BalanceDelta
        ) {
            ++successfulBuys;
        } catch {}
    }

    function sellExactInput(uint96 rawAmount) external {
        uint256 balance = _token.balanceOf(address(this));
        if (balance == 0) return;
        uint256 amount = bound(uint256(rawAmount), 1, balance > 5 ether ? 5 ether : balance);
        try _router.swap(
            _key,
            SwapParams({
                zeroForOne: false, amountSpecified: -int256(amount), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            _settings(),
            bytes("")
        ) returns (
            BalanceDelta
        ) {
            ++successfulSells;
        } catch {}
    }

    function sellExactOutput(uint80 rawAmount) external {
        uint256 ethOut = bound(uint256(rawAmount), 1, 0.1 ether);
        try _router.swap(
            _key,
            SwapParams({
                zeroForOne: false, amountSpecified: int256(ethOut), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            _settings(),
            bytes("")
        ) returns (
            BalanceDelta
        ) {
            ++successfulSells;
        } catch {}
    }

    function _settings() private pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
    }

    receive() external payable {}
}

contract SwapVMStage1InvariantTest is StdInvariant, Test {
    using TransientStateLibrary for IPoolManager;

    uint256 internal constant INITIAL_SUPPLY = 1e36;
    uint128 internal constant BYTE_GAS_PRICE = 1e12;
    uint24 internal constant POOL_FEE = 3000;
    int24 internal constant TICK_SPACING = 60;

    PoolManager internal manager;
    SwaputerToken internal token;
    SwaputerKernel internal kernel;
    SwaputerHook internal hook;
    PoolSwapTest internal swapRouter;
    PoolKey internal key;
    bytes32 internal worldId;
    SwapVMStage1Handler internal handler;

    function setUp() public {
        vm.deal(address(this), 1e30);
        manager = new PoolManager(address(this));
        token = new SwaputerToken(INITIAL_SUPPLY, address(this));
        PoolModifyLiquidityTest liquidityRouter = new PoolModifyLiquidityTest(manager);
        swapRouter = new PoolSwapTest(manager);

        uint64 nextNonce = vm.getNonce(address(this));
        address predictedKernel = vm.computeCreateAddress(address(this), nextNonce);
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        bytes memory args = abi.encode(
            manager,
            SwaputerKernel(predictedKernel),
            token,
            address(this),
            address(this),
            uint16(0),
            BYTE_GAS_PRICE,
            POOL_FEE,
            TICK_SPACING
        );
        (address expectedHook, bytes32 salt) =
            HookMiner.find(address(this), flags, type(SwaputerHook).creationCode, args);
        kernel = new SwaputerKernel(expectedHook, BYTE_GAS_PRICE);
        hook = new SwaputerHook{salt: salt}(
            manager, kernel, token, address(this), address(this), 0, BYTE_GAS_PRICE, POOL_FEE, TICK_SPACING
        );

        key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        worldId = PoolId.unwrap(key.toId());
        manager.initialize(key, 1 << 96);
        token.approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity{value: 1e25}(
            key,
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e24, salt: bytes32(0)}),
            bytes("")
        );
        hook.live();

        handler = new SwapVMStage1Handler(swapRouter, token, key);
        vm.deal(address(handler), 1e28);
        token.transfer(address(handler), 1000 ether);

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = SwapVMStage1Handler.buy.selector;
        selectors[1] = SwapVMStage1Handler.sellExactInput.selector;
        selectors[2] = SwapVMStage1Handler.sellExactOutput.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_onlySuccessfulBuysAdvanceHeightAndBurn() public view {
        uint256 buys = handler.successfulBuys();
        assertEq(kernel.executionHeight(worldId), buys);
        assertEq(token.totalSupply(), INITIAL_SUPPLY - (buys * BYTE_GAS_PRICE));
        assertEq(kernel.executedBytes(worldId), buys == 0 ? 0 : 1);
        assertEq(token.balanceOf(address(hook)), 0);
    }

    function invariant_allPoolManagerTransientDeltasAreZero() public view {
        IPoolManager poolManager = IPoolManager(address(manager));
        assertEq(poolManager.getNonzeroDeltaCount(), 0);
        assertEq(poolManager.currencyDelta(address(swapRouter), key.currency0), 0);
        assertEq(poolManager.currencyDelta(address(swapRouter), key.currency1), 0);
        assertEq(poolManager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(poolManager.currencyDelta(address(hook), key.currency1), 0);
    }

    receive() external payable {}
}
