// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

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

contract SwapVMStage5Handler is Test {
    uint256 private constant ACTOR_KEY = 0xA55E75;
    uint128 private constant ETH_IN = 0.1 ether;
    uint32 private constant LIMIT = 10_000;
    uint256 private constant FEE_DENOMINATOR = 1_000_000;
    uint256 private constant FEE = 3_000;

    SwapVMStage2Router private immutable _router;
    SwaputerKernel private immutable _kernel;
    PoolKey private _key;
    bytes32 private immutable _worldId;
    bytes32 private immutable _token0;
    bytes32 private immutable _token1;
    bytes32 private immutable _amm;

    uint256 public reserve0 = 1_000_000;
    uint256 public reserve1 = 2_000_000;
    uint256 public actor0 = 1_000_000;
    uint256 public actor1 = 2_000_000;
    uint64 public calls;
    uint64 public failedCalls;
    uint64 public unexpectedSuccessfulFailures;
    uint256 public totalExecutedBytes;

    constructor(
        SwapVMStage2Router router,
        SwaputerKernel kernel,
        PoolKey memory key_,
        bytes32 worldId_,
        bytes32 token0,
        bytes32 token1,
        bytes32 amm
    ) {
        _router = router;
        _kernel = kernel;
        _key = key_;
        _worldId = worldId_;
        _token0 = token0;
        _token1 = token1;
        _amm = amm;
    }

    function swap(bool zeroForOne, uint32 rawAmount) external {
        uint256 available = zeroForOne ? actor0 : actor1;
        if (available < 2) return;
        uint256 amountIn = bound(uint256(rawAmount), 2, available < 1_000 ? available : 1_000);
        uint256 reserveIn = zeroForOne ? reserve0 : reserve1;
        uint256 reserveOut = zeroForOne ? reserve1 : reserve0;
        uint256 adjusted = amountIn * (FEE_DENOMINATOR - FEE) / FEE_DENOMINATOR;
        uint256 amountOut = reserveOut * adjusted / (reserveIn + adjusted);
        if (amountOut == 0) return;

        bytes32 tokenIn = zeroForOne ? _token0 : _token1;
        bytes memory payload = abi.encodePacked(
            bytes4(keccak256("swapExactIn(bytes32,uint256,uint256)")), abi.encode(tokenIn, amountIn, amountOut)
        );
        SwaputerKernel.VMEnvelope memory action = _signedAction(payload, LIMIT);

        if (!_execute(action)) return;
        if (zeroForOne) {
            reserve0 += amountIn;
            reserve1 -= amountOut;
            actor0 -= amountIn;
            actor1 += amountOut;
        } else {
            reserve1 += amountIn;
            reserve0 -= amountOut;
            actor1 -= amountIn;
            actor0 += amountOut;
        }
        ++calls;
        totalExecutedBytes += _kernel.executedBytes(_worldId);
    }

    function failedSwap(bool zeroForOne, uint32 rawAmount, uint8 rawFailureMode) external {
        uint256 available = zeroForOne ? actor0 : actor1;
        if (available < 2) return;
        uint256 amountIn = bound(uint256(rawAmount), 2, available < 1_000 ? available : 1_000);
        bytes32 tokenIn = zeroForOne ? _token0 : _token1;
        uint8 failureMode = rawFailureMode % 4;
        bytes memory payload;
        uint32 byteGasLimit = LIMIT;
        if (failureMode == 0) {
            payload = abi.encodePacked(
                bytes4(keccak256("swapExactIn(bytes32,uint256,uint256)")),
                abi.encode(tokenIn, amountIn, type(uint128).max)
            );
        } else if (failureMode == 1) {
            payload = abi.encodePacked(
                bytes4(keccak256("swapExactIn(bytes32,uint256,uint256)")),
                abi.encode(bytes32(uint256(0xdead)), amountIn, uint256(0))
            );
        } else if (failureMode == 2) {
            payload = abi.encodePacked(bytes4(keccak256("unknown(bytes32,uint256)")), abi.encode(tokenIn, amountIn));
        } else {
            payload = abi.encodePacked(
                bytes4(keccak256("swapExactIn(bytes32,uint256,uint256)")), abi.encode(tokenIn, amountIn, uint256(0))
            );
            byteGasLimit = 1;
        }

        if (_execute(_signedAction(payload, byteGasLimit))) {
            ++unexpectedSuccessfulFailures;
        } else {
            ++failedCalls;
        }
    }

    function _signedAction(bytes memory payload, uint32 byteGasLimit)
        private
        view
        returns (SwaputerKernel.VMEnvelope memory action)
    {
        action = SwaputerKernel.VMEnvelope({
            op: SwaputerKernel.RootOp.CALL,
            worldId: _worldId,
            actor: vm.addr(ACTOR_KEY),
            targetOrCodeHash: _amm,
            payload: payload,
            byteGasLimit: byteGasLimit,
            minNetTokenOut: 0,
            nonce: 7 + calls,
            deadline: uint64(block.timestamp + 1 days),
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
                ETH_IN,
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
    }

    function _execute(SwaputerKernel.VMEnvelope memory action) private returns (bool success) {
        try _router.swap{value: ETH_IN}(
            _key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(uint256(ETH_IN)),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            address(this),
            abi.encode(action)
        ) {
            return true;
        } catch {
            return false;
        }
    }

    receive() external payable {}
}

contract SwapVMStage5InvariantTest is StdInvariant, Test {
    using stdJson for string;
    using TransientStateLibrary for IPoolManager;

    uint256 private constant INITIAL_SUPPLY = 1e36;
    uint128 private constant BYTE_GAS_PRICE = 1e12;
    uint24 private constant POOL_FEE = 3000;
    int24 private constant TICK_SPACING = 60;
    uint256 private constant ACTOR_KEY = 0xA55E75;
    uint32 private constant LIMIT = 10_000;

    PoolManager private manager;
    SwaputerToken private gasToken;
    SwapVMKernelStage2Harness private kernel;
    SwaputerHook private hook;
    SwapVMStage2Router private router;
    PoolKey private key;
    bytes32 private worldId;
    bytes32 private actorId;
    bytes32 private token0;
    bytes32 private token1;
    bytes32 private amm;
    uint256 private supplyAfterInitialization;
    SwapVMStage5Handler private handler;

    function setUp() public {
        vm.deal(address(this), 1e30);
        address actor = vm.addr(ACTOR_KEY);
        vm.deal(actor, 100 ether);
        manager = new PoolManager(address(this));
        gasToken = new SwaputerToken(INITIAL_SUPPLY, address(this));
        PoolModifyLiquidityTest liquidityRouter = new PoolModifyLiquidityTest(manager);
        router = new SwapVMStage2Router(manager);
        uint64 nextNonce = vm.getNonce(address(this));
        address predictedKernel = vm.computeCreateAddress(address(this), nextNonce);
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        bytes memory args = abi.encode(
            manager,
            SwaputerKernel(predictedKernel),
            gasToken,
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
            manager, kernel, gasToken, address(this), address(this), 0, BYTE_GAS_PRICE, POOL_FEE, TICK_SPACING
        );
        key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(gasToken)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        worldId = PoolId.unwrap(key.toId());
        manager.initialize(key, 1 << 96);
        gasToken.approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity{value: 1e25}(
            key,
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e24, salt: bytes32(0)}),
            bytes("")
        );
        hook.live();

        actorId = kernel.eoaAccountId(actor);
        bytes memory src20Package = _package("SRC20-v1");
        bytes memory ammPackage = _package("CPAMM-v1");
        token0 = _deploy(
            actor,
            src20Package,
            abi.encode(bytes32("Invariant 0"), bytes32("IV0"), uint256(18), uint256(2_000_000), actorId),
            0
        );
        token1 = _deploy(
            actor,
            src20Package,
            abi.encode(bytes32("Invariant 1"), bytes32("IV1"), uint256(18), uint256(4_000_000), actorId),
            1
        );
        amm = _deploy(actor, ammPackage, bytes(""), 2);
        _call(actor, amm, "createPair(bytes32,bytes32,uint256)", abi.encode(token0, token1, uint256(3000)), 3);
        _call(actor, token0, "approve(bytes32,uint256)", abi.encode(amm, type(uint128).max), 4);
        _call(actor, token1, "approve(bytes32,uint256)", abi.encode(amm, type(uint128).max), 5);
        _call(
            actor,
            amm,
            "addLiquidity(uint256,uint256,uint256)",
            abi.encode(uint256(1_000_000), uint256(2_000_000), uint256(1_000_000)),
            6
        );
        supplyAfterInitialization = gasToken.totalSupply();

        handler = new SwapVMStage5Handler(router, kernel, key, worldId, token0, token1, amm);
        vm.deal(address(handler), 1e28);
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = SwapVMStage5Handler.swap.selector;
        selectors[1] = SwapVMStage5Handler.failedSwap.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_reservesAreExactlyBackedAndConserveTokens() public view {
        (uint256 reserve0, uint256 reserve1) = _reserves();
        assertEq(reserve0, handler.reserve0());
        assertEq(reserve1, handler.reserve1());
        assertEq(_balance(token0, amm), reserve0);
        assertEq(_balance(token1, amm), reserve1);
        assertEq(_balance(token0, actorId), handler.actor0());
        assertEq(_balance(token1, actorId), handler.actor1());
        assertEq(reserve0 + handler.actor0(), 2_000_000);
        assertEq(reserve1 + handler.actor1(), 4_000_000);
        assertGe(reserve0 * reserve1, uint256(1_000_000) * 2_000_000);
    }

    function invariant_nonceHeightBurnAndSettlementReconcile() public view {
        uint256 calls = handler.calls();
        assertEq(handler.unexpectedSuccessfulFailures(), 0);
        assertEq(kernel.executionHeight(worldId), 7 + calls);
        assertEq(kernel.nonces(worldId, actorId), 7 + calls);
        assertEq(gasToken.totalSupply(), supplyAfterInitialization - handler.totalExecutedBytes() * BYTE_GAS_PRICE);
        assertEq(gasToken.balanceOf(address(hook)), 0);
        IPoolManager poolManager = IPoolManager(address(manager));
        assertEq(poolManager.getNonzeroDeltaCount(), 0);
        assertEq(poolManager.currencyDelta(address(router), key.currency0), 0);
        assertEq(poolManager.currencyDelta(address(router), key.currency1), 0);
        assertEq(poolManager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(poolManager.currencyDelta(address(hook), key.currency1), 0);
    }

    function _deploy(address actor, bytes memory packageBytes, bytes memory constructorInput, uint64 nonce)
        private
        returns (bytes32 contractId)
    {
        bytes32 codeHash = keccak256(packageBytes);
        contractId = kernel.contractAccountId(worldId, actorId, kernel.creatorNonce(worldId, actorId), codeHash);
        bytes memory payload = abi.encodePacked(bytes4(uint32(packageBytes.length)), packageBytes, constructorInput);
        _execute(actor, SwaputerKernel.RootOp.DEPLOY, codeHash, payload, nonce);
    }

    function _call(address actor, bytes32 target, string memory signature, bytes memory arguments, uint64 nonce)
        private
    {
        _execute(
            actor,
            SwaputerKernel.RootOp.CALL,
            target,
            abi.encodePacked(bytes4(keccak256(bytes(signature))), arguments),
            nonce
        );
    }

    function _execute(address actor, SwaputerKernel.RootOp op, bytes32 target, bytes memory payload, uint64 nonce)
        private
    {
        SwaputerKernel.VMEnvelope memory action = SwaputerKernel.VMEnvelope({
            op: op,
            worldId: worldId,
            actor: actor,
            targetOrCodeHash: target,
            payload: payload,
            byteGasLimit: LIMIT,
            minNetTokenOut: 0,
            nonce: nonce,
            deadline: uint64(block.timestamp + 1 days),
            recipient: actor,
            authorizedExecutor: actor,
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
                uint128(1 ether),
                TickMath.MIN_SQRT_PRICE + 1,
                action.recipient,
                address(router),
                action.authorizedExecutor,
                action.nonce,
                action.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", kernel.domainSeparator(worldId), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ACTOR_KEY, digest);
        action.signature = abi.encodePacked(r, s, v);
        vm.prank(actor);
        router.swap{value: 1 ether}(key, _buyParams(), actor, abi.encode(action));
    }

    function _package(string memory name) private view returns (bytes memory) {
        string memory json = vm.readFile(string.concat("reference/", name, ".json"));
        return json.readBytes(".package");
    }

    function _reserves() private view returns (uint256 reserve0, uint256 reserve1) {
        (bytes memory output,) =
            kernel.staticCall(worldId, amm, abi.encodePacked(bytes4(keccak256("getReserves()"))), LIMIT);
        (reserve0, reserve1) = abi.decode(output, (uint256, uint256));
    }

    function _balance(bytes32 tokenId, bytes32 owner) private view returns (uint256) {
        (bytes memory output,) = kernel.staticCall(
            worldId, tokenId, abi.encodePacked(bytes4(keccak256("balanceOf(bytes32)")), abi.encode(owner)), LIMIT
        );
        return abi.decode(output, (uint256));
    }

    function _buyParams() private pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
    }

    receive() external payable {}
}
