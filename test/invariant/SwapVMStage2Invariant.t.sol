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
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {SwaputerToken} from "../../src/SwaputerToken.sol";
import {SwaputerHook} from "../../src/SwaputerHook.sol";
import {SwaputerKernel} from "../../src/SwaputerKernel.sol";
import {SwapVMKernelStage2Harness, SwapVMStage2Router} from "../SwapVMStage2.t.sol";

contract SwapVMStage2Handler is Test {
    uint256 private constant ACTOR_KEY = 0xC0DE;

    SwapVMStage2Router private immutable _router;
    SwaputerToken private immutable _token;
    SwaputerKernel private immutable _kernel;
    PoolKey private _key;
    bytes32 private immutable _worldId;
    bytes32 private immutable _stopTarget;
    bytes32 private immutable _loopTarget;

    uint256 public successfulNops;
    uint256 public successfulCalls;
    uint256 public successfulSells;
    uint256 public totalExecutedBytes;
    uint32 public lastExecutedBytes;

    constructor(
        SwapVMStage2Router router,
        SwaputerToken token,
        SwaputerKernel kernel,
        PoolKey memory key_,
        bytes32 worldId_,
        bytes32 stopTarget_,
        bytes32 loopTarget_
    ) {
        _router = router;
        _token = token;
        _kernel = kernel;
        _key = key_;
        _worldId = worldId_;
        _stopTarget = stopTarget_;
        _loopTarget = loopTarget_;
        token.approve(address(router), type(uint256).max);
    }

    function nopBuy(uint80 rawAmount) external {
        uint256 amount = bound(uint256(rawAmount), 2e12, 2 ether);
        try _router.swap{value: amount}(
            _key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            address(this),
            bytes("")
        ) {
            ++successfulNops;
            ++totalExecutedBytes;
            lastExecutedBytes = 1;
        } catch {}
    }

    function signedBuy(uint80 rawAmount, bool loop) external {
        uint256 amount = bound(uint256(rawAmount), 3e13, 2 ether);
        uint32 expectedBytes = loop ? 28 : 1;
        bytes32 target = loop ? _loopTarget : _stopTarget;
        uint64 nonce = uint64(successfulCalls);
        uint64 deadline = uint64(block.timestamp + 1 days);
        SwaputerKernel.VMEnvelope memory action = SwaputerKernel.VMEnvelope({
            op: SwaputerKernel.RootOp.CALL,
            worldId: _worldId,
            actor: vm.addr(ACTOR_KEY),
            targetOrCodeHash: target,
            payload: bytes(""),
            byteGasLimit: expectedBytes,
            minNetTokenOut: 0,
            nonce: nonce,
            deadline: deadline,
            recipient: address(this),
            authorizedExecutor: address(this),
            signature: bytes("")
        });
        bytes32 structHash = keccak256(
            abi.encode(
                _kernel.VM_ACTION_TYPEHASH(),
                uint8(action.op),
                action.worldId,
                action.actor,
                action.targetOrCodeHash,
                keccak256(action.payload),
                action.byteGasLimit,
                action.minNetTokenOut,
                uint128(amount),
                TickMath.MIN_SQRT_PRICE + 1,
                action.recipient,
                address(_router),
                action.authorizedExecutor,
                action.nonce,
                action.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", _kernel.domainSeparator(_worldId), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ACTOR_KEY, digest);
        action.signature = abi.encodePacked(r, s, v);

        try _router.swap{value: amount}(
            _key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            address(this),
            abi.encode(action)
        ) {
            ++successfulCalls;
            totalExecutedBytes += expectedBytes;
            lastExecutedBytes = expectedBytes;
        } catch {}
    }

    function sellExactInput(uint80 rawAmount) external {
        uint256 balance = _token.balanceOf(address(this));
        if (balance == 0) return;
        uint256 amount = bound(uint256(rawAmount), 1, balance > 2 ether ? 2 ether : balance);
        try _router.swap(
            _key,
            SwapParams({
                zeroForOne: false, amountSpecified: -int256(amount), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            address(this),
            bytes("")
        ) {
            ++successfulSells;
        } catch {}
    }

    receive() external payable {}
}

contract SwapVMStage2InvariantTest is StdInvariant, Test {
    using TransientStateLibrary for IPoolManager;

    uint256 internal constant INITIAL_SUPPLY = 1e36;
    uint128 internal constant BYTE_GAS_PRICE = 1e12;
    uint24 internal constant POOL_FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    bytes32 internal constant STOP_TARGET = 0x0100000000000000000000000000000000000000000000000000000000002001;
    bytes32 internal constant LOOP_TARGET = 0x0100000000000000000000000000000000000000000000000000000000002002;

    PoolManager internal manager;
    SwaputerToken internal token;
    SwapVMKernelStage2Harness internal kernel;
    SwaputerHook internal hook;
    SwapVMStage2Router internal router;
    PoolKey internal key;
    bytes32 internal worldId;
    SwapVMStage2Handler internal handler;

    function setUp() public {
        vm.deal(address(this), 1e30);
        manager = new PoolManager(address(this));
        token = new SwaputerToken(INITIAL_SUPPLY, address(this));
        PoolModifyLiquidityTest liquidityRouter = new PoolModifyLiquidityTest(manager);
        router = new SwapVMStage2Router(manager);

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
        kernel = new SwapVMKernelStage2Harness(expectedHook, BYTE_GAS_PRICE);
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
        kernel.install(worldId, STOP_TARGET, hex"00");
        kernel.install(worldId, LOOP_TARGET, hex"60035b600103806002575000");

        handler = new SwapVMStage2Handler(router, token, kernel, key, worldId, STOP_TARGET, LOOP_TARGET);
        vm.deal(address(handler), 1e28);
        token.transfer(address(handler), 1000 ether);
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = SwapVMStage2Handler.nopBuy.selector;
        selectors[1] = SwapVMStage2Handler.signedBuy.selector;
        selectors[2] = SwapVMStage2Handler.sellExactInput.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_heightNonceMeterAndSupplyReconcile() public view {
        uint256 calls = handler.successfulCalls();
        uint256 nops = handler.successfulNops();
        assertEq(kernel.executionHeight(worldId), calls + nops);
        assertEq(kernel.nonces(worldId, kernel.eoaAccountId(vm.addr(0xC0DE))), calls);
        assertEq(token.totalSupply(), INITIAL_SUPPLY - (handler.totalExecutedBytes() * BYTE_GAS_PRICE));
        assertEq(kernel.executedBytes(worldId), calls + nops == 0 ? 0 : handler.lastExecutedBytes());
        assertEq(token.balanceOf(address(hook)), 0);
    }

    function invariant_poolManagerTransientDeltasAlwaysSettle() public view {
        IPoolManager poolManager = IPoolManager(address(manager));
        assertEq(poolManager.getNonzeroDeltaCount(), 0);
        assertEq(poolManager.currencyDelta(address(router), key.currency0), 0);
        assertEq(poolManager.currencyDelta(address(router), key.currency1), 0);
        assertEq(poolManager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(poolManager.currencyDelta(address(hook), key.currency1), 0);
    }

    receive() external payable {}
}
