// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {SwapVMGasToken} from "../src/SwapVMGasToken.sol";
import {SwapVMHook} from "../src/SwapVMHook.sol";
import {SwapVMKernel} from "../src/SwapVMKernel.sol";
import {ReceiptFixture} from "./utils/ReceiptFixture.sol";

contract SwapVMStage1Test is Test {
    using BalanceDeltaLibrary for BalanceDelta;
    using TransientStateLibrary for IPoolManager;

    uint256 internal constant INITIAL_SUPPLY = 1e36;
    uint128 internal constant BYTE_GAS_PRICE = 1e12;
    uint24 internal constant POOL_FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    uint160 internal constant SQRT_PRICE_1_1 = 1 << 96;
    int24 internal constant TICK_LOWER = -600;
    int24 internal constant TICK_UPPER = 600;
    int128 internal constant INITIAL_LIQUIDITY = 1e24;

    bytes32 internal constant EVENTS_TOPIC = keccak256("Events(bytes32,uint64,bytes)");
    bytes32 internal constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    bytes32 internal constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");

    PoolManager internal manager;
    SwapVMGasToken internal token;
    SwapVMKernel internal kernel;
    SwapVMHook internal hook;
    PoolModifyLiquidityTest internal liquidityRouter;
    PoolSwapTest internal swapRouter;
    PoolKey internal key;
    bytes32 internal worldId;

    function setUp() public {
        vm.deal(address(this), 1e30);

        manager = new PoolManager(address(this));
        token = new SwapVMGasToken(INITIAL_SUPPLY, address(this));
        liquidityRouter = new PoolModifyLiquidityTest(manager);
        swapRouter = new PoolSwapTest(manager);

        uint64 nextNonce = vm.getNonce(address(this));
        address predictedKernel = vm.computeCreateAddress(address(this), nextNonce);
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        bytes memory constructorArgs = abi.encode(
            manager,
            SwapVMKernel(predictedKernel),
            token,
            address(this),
            address(this),
            uint16(0),
            BYTE_GAS_PRICE,
            POOL_FEE,
            TICK_SPACING
        );
        (address expectedHook, bytes32 salt) =
            HookMiner.find(address(this), flags, type(SwapVMHook).creationCode, constructorArgs);

        kernel = new SwapVMKernel(expectedHook, BYTE_GAS_PRICE);
        assertEq(address(kernel), predictedKernel, "kernel address prediction");
        hook = new SwapVMHook{salt: salt}(
            manager, kernel, token, address(this), address(this), 0, BYTE_GAS_PRICE, POOL_FEE, TICK_SPACING
        );
        assertEq(address(hook), expectedHook, "hook CREATE2 address");

        key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        worldId = PoolId.unwrap(key.toId());

        manager.initialize(key, SQRT_PRICE_1_1);
        token.approve(address(liquidityRouter), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity{value: 1e25}(
            key,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: INITIAL_LIQUIDITY, salt: bytes32(0)
            }),
            bytes("")
        );
    }

    function test_hookAddressHasExactlyRequiredPermissionBits() public view {
        uint160 permissionBits = uint160(address(hook)) & Hooks.ALL_HOOK_MASK;
        assertEq(
            permissionBits,
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        Hooks.Permissions memory permissions = hook.getHookPermissions();
        assertTrue(permissions.afterSwap);
        assertTrue(permissions.afterSwapReturnDelta);
        assertTrue(permissions.beforeSwap);
        assertTrue(permissions.beforeSwapReturnDelta);
        assertTrue(permissions.beforeInitialize);
        assertFalse(permissions.afterInitialize);
        assertFalse(permissions.beforeAddLiquidity);
        assertFalse(permissions.afterAddLiquidity);
        assertFalse(permissions.beforeRemoveLiquidity);
        assertFalse(permissions.afterRemoveLiquidity);
        assertFalse(permissions.beforeDonate);
        assertFalse(permissions.afterDonate);
        assertFalse(permissions.afterAddLiquidityReturnDelta);
        assertFalse(permissions.afterRemoveLiquidityReturnDelta);
    }

    function test_kernelPinsFrozenVersionsAndIsaHash() public view {
        assertEq(kernel.VM_VERSION(), 2);
        assertEq(kernel.RECEIPT_VERSION(), 1);
        assertEq(kernel.ISA_HASH(), 0x5958f1a3baf744e5ed92f096a964ee14779db2e32e70a2982c53080eb3cd92c2);
    }

    function test_exactInputEthBuyExecutesStopTakesBurnsAndReturnsNet() public {
        uint256 buyerBalanceBefore = token.balanceOf(address(this));
        uint256 supplyBefore = token.totalSupply();

        vm.recordLogs();
        BalanceDelta finalDelta = _buyExactInput(1 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint128 grossTokenOut = _grossTokenOut(logs);
        uint128 netTokenOut = uint128(finalDelta.amount1());
        assertGt(grossTokenOut, BYTE_GAS_PRICE);
        assertEq(netTokenOut, grossTokenOut - BYTE_GAS_PRICE, "positive unspecified delta reduces output");
        assertEq(token.balanceOf(address(this)) - buyerBalanceBefore, netTokenOut, "actual buyer net output");
        assertEq(supplyBefore - token.totalSupply(), BYTE_GAS_PRICE, "real totalSupply burn");
        assertEq(token.balanceOf(address(hook)), 0, "taken fee burned immediately");
        assertEq(kernel.executedBytes(worldId), 1);
        assertEq(kernel.executionHeight(worldId), 1);

        (bytes memory payload, uint256 eventCount) = _findEventPayload(logs);
        assertEq(eventCount, 1, "one SwapVM Events");
        _assertReceipt(payload, grossTokenOut);
        _assertOneBurnTransfer(logs);
        _assertDeltasSettled();
    }

    function test_stage6A_fixture_unsignedNop() public {
        vm.recordLogs();
        _buyExactInput(1 ether);
        ReceiptFixture.assertOrWrite(vm, "unsigned-nop", address(kernel), vm.getRecordedLogs());
    }

    function test_receiptIsUniquelyIdentifiedAmidSwapAndTransfers() public {
        vm.recordLogs();
        _buyExactInput(2 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 poolSwapLogs;
        uint256 erc20TransferLogs;
        uint256 canonicalEvents;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_TOPIC) ++poolSwapLogs;
            if (logs[i].emitter == address(token) && logs[i].topics[0] == TRANSFER_TOPIC) ++erc20TransferLogs;
            if (logs[i].emitter == address(kernel) && logs[i].topics[0] == EVENTS_TOPIC) ++canonicalEvents;
        }

        assertEq(poolSwapLogs, 1);
        assertGt(erc20TransferLogs, 1);
        assertEq(canonicalEvents, 1, "kernel address + Events selector is unique");
    }

    function test_buyRevertsWhenGrossDoesNotCoverOneByteFeeAndRollsBackEverything() public {
        uint256 supplyBefore = token.totalSupply();
        uint256 tokenBalanceBefore = token.balanceOf(address(this));
        uint256 managerEthBefore = address(manager).balance;

        vm.recordLogs();
        vm.expectRevert();
        _buyExactInput(BYTE_GAS_PRICE);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(kernel.executionHeight(worldId), 0);
        assertEq(kernel.executedBytes(worldId), 0);
        assertEq(token.totalSupply(), supplyBefore);
        assertEq(token.balanceOf(address(this)), tokenBalanceBefore);
        assertEq(address(manager).balance, managerEthBefore);
        (, uint256 eventCount) = _findEventPayload(logs);
        assertEq(eventCount, 0, "reverted execution leaves no Events");
        _assertDeltasSettled();
    }

    function test_exactInputTokenSellBypassesVmAndBurn() public {
        _buyExactInput(1 ether);
        uint64 heightBefore = kernel.executionHeight(worldId);
        uint256 supplyBefore = token.totalSupply();
        uint32 bytesBefore = kernel.executedBytes(worldId);

        vm.recordLogs();
        BalanceDelta delta = _sellExactInput(0.25 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertLt(delta.amount1(), 0, "TOKEN input delta");
        assertGt(delta.amount0(), 0, "ETH output delta");
        _assertSellDidNotExecute(heightBefore, bytesBefore, supplyBefore, logs);
    }

    function test_exactOutputTokenSellIsRejected() public {
        _buyExactInput(2 ether);
        uint64 heightBefore = kernel.executionHeight(worldId);
        uint256 supplyBefore = token.totalSupply();
        uint32 bytesBefore = kernel.executedBytes(worldId);

        vm.expectRevert();
        _sellExactOutput(0.1 ether);
        assertEq(kernel.executionHeight(worldId), heightBefore);
        assertEq(kernel.executedBytes(worldId), bytesBefore);
        assertEq(token.totalSupply(), supplyBefore);
    }

    function test_sellIgnoresRouterSpecificHookData() public {
        _buyExactInput(2 ether);
        uint64 heightBefore = kernel.executionHeight(worldId);
        uint256 supplyBefore = token.totalSupply();
        BalanceDelta delta = swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: -int256(0.1 ether), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            _settings(),
            hex"00"
        );
        assertGt(delta.amount0(), 0);
        assertEq(kernel.executionHeight(worldId), heightBefore);
        assertEq(token.totalSupply(), supplyBefore);
    }

    function test_exactOutputEthBuyReverts() public {
        vm.expectRevert();
        swapRouter.swap{value: 2 ether}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: int256(0.1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            _settings(),
            bytes("")
        );
        assertEq(kernel.executionHeight(worldId), 0);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
    }

    function test_nonPoolManagerCannotCallHook() public {
        vm.expectRevert(abi.encodeWithSelector(SwapVMHook.OnlyPoolManager.selector, address(this)));
        hook.afterSwap(
            address(this),
            key,
            SwapParams({zeroForOne: false, amountSpecified: -1, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            toBalanceDelta(0, 0),
            bytes("")
        );
    }

    function test_nonBoundHookCannotCallKernel() public {
        SwapVMKernel.BuyReceipt memory receipt;
        vm.expectRevert(abi.encodeWithSelector(SwapVMKernel.OnlyBoundHook.selector, address(this)));
        kernel.executeNOP(receipt);
    }

    function test_boundaryRejectsExactInputAboveUint128() public {
        uint256 tooLarge = uint256(type(uint128).max) + 1;
        vm.prank(address(manager));
        vm.expectRevert(abi.encodeWithSelector(SwapVMHook.ExactEthInputOutOfRange.selector, tooLarge));
        hook.afterSwap(
            address(swapRouter),
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(tooLarge), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            toBalanceDelta(-1, int128(BYTE_GAS_PRICE + 1)),
            bytes("")
        );
    }

    function test_boundaryRejectsInt256MinimumExactInput() public {
        vm.prank(address(manager));
        vm.expectRevert(
            abi.encodeWithSelector(SwapVMHook.ExactEthInputOutOfRange.selector, uint256(type(int256).max) + 1)
        );
        hook.afterSwap(
            address(swapRouter),
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: type(int256).min, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            toBalanceDelta(-1, int128(BYTE_GAS_PRICE + 1)),
            bytes("")
        );
    }

    function test_gasTokenBurnEmitsTransferAndReducesSupply() public {
        uint256 amount = 17;
        uint256 supplyBefore = token.totalSupply();
        vm.expectEmit(true, true, false, true, address(token));
        emit SwapVMGasToken.Transfer(address(this), address(0), amount);
        token.burn(amount);
        assertEq(token.totalSupply(), supplyBefore - amount);
    }

    function testFuzz_exactInputBuyPreservesGrossMinusBurn(uint96 rawAmount) public {
        uint256 amount = bound(uint256(rawAmount), uint256(BYTE_GAS_PRICE) * 2, 10 ether);
        uint256 buyerBefore = token.balanceOf(address(this));
        uint256 supplyBefore = token.totalSupply();

        vm.recordLogs();
        BalanceDelta delta = _buyExactInput(amount);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint128 gross = _grossTokenOut(logs);
        assertLt(delta.amount0(), 0);
        assertGt(delta.amount1(), 0);
        assertEq(uint128(delta.amount1()), gross - BYTE_GAS_PRICE);
        assertEq(token.balanceOf(address(this)) - buyerBefore, uint128(delta.amount1()));
        assertEq(supplyBefore - token.totalSupply(), BYTE_GAS_PRICE);
        assertEq(kernel.executedBytes(worldId), 1);
        _assertDeltasSettled();
    }

    function testFuzz_sellDirectionAndDeltaSignsNeverExecute(bool exactInput, uint96 rawAmount) public {
        _buyExactInput(20 ether);
        uint64 heightBefore = kernel.executionHeight(worldId);
        uint256 supplyBefore = token.totalSupply();
        uint32 bytesBefore = kernel.executedBytes(worldId);
        uint256 amount = bound(uint256(rawAmount), 1e12, 0.5 ether);

        if (!exactInput) {
            vm.expectRevert();
            _sellExactOutput(amount / 2);
            assertEq(kernel.executionHeight(worldId), heightBefore);
            assertEq(kernel.executedBytes(worldId), bytesBefore);
            assertEq(token.totalSupply(), supplyBefore);
            return;
        }

        vm.recordLogs();
        BalanceDelta delta = _sellExactInput(amount);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertLt(delta.amount1(), 0);
        assertGt(delta.amount0(), 0);
        _assertSellDidNotExecute(heightBefore, bytesBefore, supplyBefore, logs);
    }

    function testFuzz_buyRejectsNonPositiveOutputDelta(int128 outputDelta) public {
        outputDelta = int128(bound(outputDelta, type(int128).min, 0));
        vm.prank(address(manager));
        vm.expectRevert(abi.encodeWithSelector(SwapVMHook.InvalidGrossTokenOut.selector, outputDelta));
        hook.afterSwap(
            address(swapRouter),
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            toBalanceDelta(-1, outputDelta),
            bytes("")
        );
    }

    function testFuzz_sellCallbackReturnsZeroForEitherSwapMode(bool exactInput, int128 amount0, int128 amount1) public {
        int256 amountSpecified = exactInput ? -int256(1) : int256(1);
        vm.prank(address(manager));
        (bytes4 selector, int128 hookDelta) = hook.afterSwap(
            address(swapRouter),
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: amountSpecified, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            toBalanceDelta(amount0, amount1),
            bytes("")
        );
        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(hookDelta, 0);
        assertEq(kernel.executionHeight(worldId), 0);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
    }

    function testFuzz_boundaryRejectsInputPastUint128(uint256 raw) public {
        uint256 tooLarge = bound(raw, uint256(type(uint128).max) + 1, uint256(type(int256).max));
        vm.prank(address(manager));
        vm.expectRevert(abi.encodeWithSelector(SwapVMHook.ExactEthInputOutOfRange.selector, tooLarge));
        hook.afterSwap(
            address(swapRouter),
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(tooLarge), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            toBalanceDelta(-1, int128(BYTE_GAS_PRICE + 1)),
            bytes("")
        );
    }

    function _buyExactInput(uint256 amountIn) internal returns (BalanceDelta) {
        return swapRouter.swap{value: amountIn}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            _settings(),
            bytes("")
        );
    }

    function _sellExactInput(uint256 tokenIn) internal returns (BalanceDelta) {
        return swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: -int256(tokenIn), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            _settings(),
            bytes("")
        );
    }

    function _sellExactOutput(uint256 ethOut) internal returns (BalanceDelta) {
        return swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: int256(ethOut), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            _settings(),
            bytes("")
        );
    }

    function _settings() internal pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
    }

    function _grossTokenOut(Vm.Log[] memory logs) internal returns (uint128 gross) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_TOPIC) {
                (, int128 amount1,,,,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                assertGt(amount1, 0, "gross TOKEN output sign");
                return uint128(amount1);
            }
        }
        fail();
    }

    function _findEventPayload(Vm.Log[] memory logs) internal view returns (bytes memory payload, uint256 count) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(kernel) && logs[i].topics[0] == EVENTS_TOPIC) {
                ++count;
                assertEq(logs[i].topics[1], worldId);
                assertEq(uint256(logs[i].topics[2]), kernel.executionHeight(worldId));
                payload = abi.decode(logs[i].data, (bytes));
            }
        }
    }

    function _assertReceipt(bytes memory payload, uint128 grossTokenOut) internal view {
        assertEq(payload.length, 269, "canonical Stage 1 receipt length");
        assertEq(uint8(payload[0]), 1, "version");
        assertEq(uint8(payload[1]), 0, "flags");
        assertEq(_u16(payload, 2), 1, "recordCount");
        assertEq(_u32(payload, 4), 261, "recordLength");
        assertEq(uint256(_u32(payload, 4)) + 8, payload.length, "record consumes payload");
        assertEq(_word(payload, 8), kernel.KERNEL_EMITTER_ID(), "Kernel emitter");
        assertEq(uint8(payload[40]), 1, "topicCount");
        assertEq(_word(payload, 41), kernel.WORLD_EXECUTION_SELECTOR(), "execution selector");
        assertEq(_u32(payload, 73), 192, "execution summary data length");

        assertEq(_word(payload, 77), bytes32(0), "unsigned NOP actor");
        assertEq(_word(payload, 109), bytes32(0), "NOP root target");
        assertEq(uint256(_word(payload, 141)), 1, "executedBytes summary");
        assertEq(uint256(_word(payload, 173)), BYTE_GAS_PRICE, "tokenBurned summary");
        assertEq(uint256(_word(payload, 205)), grossTokenOut, "gross summary");
        assertEq(uint256(_word(payload, 237)), grossTokenOut - BYTE_GAS_PRICE, "net summary");
    }

    function _assertOneBurnTransfer(Vm.Log[] memory logs) internal view {
        uint256 burnLogs;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(token) && logs[i].topics[0] == TRANSFER_TOPIC
                    && address(uint160(uint256(logs[i].topics[1]))) == address(hook)
                    && address(uint160(uint256(logs[i].topics[2]))) == address(0)
            ) {
                ++burnLogs;
                assertEq(abi.decode(logs[i].data, (uint256)), BYTE_GAS_PRICE);
            }
        }
        assertEq(burnLogs, 1, "one conventional burn Transfer");
    }

    function _assertSellDidNotExecute(
        uint64 heightBefore,
        uint32 bytesBefore,
        uint256 supplyBefore,
        Vm.Log[] memory logs
    ) internal view {
        assertEq(kernel.executionHeight(worldId), heightBefore);
        assertEq(kernel.executedBytes(worldId), bytesBefore);
        assertEq(token.totalSupply(), supplyBefore);
        (, uint256 eventCount) = _findEventPayload(logs);
        assertEq(eventCount, 0);
        _assertDeltasSettled();
    }

    function _assertDeltasSettled() internal view {
        IPoolManager poolManager = IPoolManager(address(manager));
        assertEq(poolManager.getNonzeroDeltaCount(), 0, "PoolManager nonzero delta count");
        assertEq(poolManager.currencyDelta(address(swapRouter), key.currency0), 0, "router ETH delta");
        assertEq(poolManager.currencyDelta(address(swapRouter), key.currency1), 0, "router TOKEN delta");
        assertEq(poolManager.currencyDelta(address(hook), key.currency0), 0, "hook ETH delta");
        assertEq(poolManager.currencyDelta(address(hook), key.currency1), 0, "hook TOKEN delta");
    }

    function _u16(bytes memory data, uint256 offset) internal pure returns (uint16 value) {
        value = uint16(uint8(data[offset])) << 8 | uint16(uint8(data[offset + 1]));
    }

    function _u32(bytes memory data, uint256 offset) internal pure returns (uint32 value) {
        value = uint32(uint8(data[offset])) << 24 | uint32(uint8(data[offset + 1])) << 16
            | uint32(uint8(data[offset + 2])) << 8 | uint32(uint8(data[offset + 3]));
    }

    function _word(bytes memory data, uint256 offset) internal pure returns (bytes32 value) {
        assembly ("memory-safe") {
            value := mload(add(add(data, 0x20), offset))
        }
    }

    receive() external payable {}
}
