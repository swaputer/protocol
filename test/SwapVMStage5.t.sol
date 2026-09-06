// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
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

import {SwapVMGasToken} from "../src/SwapVMGasToken.sol";
import {SwapVMHook} from "../src/SwapVMHook.sol";
import {SwapVMKernel} from "../src/SwapVMKernel.sol";
import {SwapVMReferenceRegistry} from "../src/SwapVMReferenceRegistry.sol";
import {SwapVMKernelStage2Harness, SwapVMStage2Router} from "./SwapVMStage2.t.sol";
import {ReceiptFixture} from "./utils/ReceiptFixture.sol";

contract SwapVMStage5Test is Test {
    using stdJson for string;
    using TransientStateLibrary for IPoolManager;

    uint256 private constant INITIAL_SUPPLY = 1e36;
    uint128 private constant BYTE_GAS_PRICE = 1e12;
    uint24 private constant POOL_FEE = 3000;
    int24 private constant TICK_SPACING = 60;
    uint256 private constant ACTOR_KEY = 0xA11CE;
    uint32 private constant ACTION_LIMIT = 10_000;
    uint256 private constant FEE_DENOMINATOR = 1_000_000;
    bytes32 private constant EVENTS_TOPIC = keccak256("Events(bytes32,uint64,bytes)");
    bytes32 private constant TRANSFER_TOPIC = keccak256("Transfer(bytes32,bytes32,uint256)");
    bytes32 private constant ADD_TOPIC = keccak256("LiquidityAdded(bytes32,uint256,uint256,uint256)");
    bytes32 private constant REMOVE_TOPIC = keccak256("LiquidityRemoved(bytes32,uint256,uint256,uint256)");
    bytes32 private constant SWAP_TOPIC = keccak256("Swap(bytes32,bytes32,uint256,uint256)");

    PoolManager private manager;
    SwapVMGasToken private gasToken;
    SwapVMKernelStage2Harness private kernel;
    SwapVMHook private hook;
    SwapVMStage2Router private router;
    PoolKey private key;
    bytes32 private worldId;
    address private actor;

    function setUp() public {
        actor = vm.addr(ACTOR_KEY);
        vm.deal(address(this), 1e30);
        vm.deal(actor, 100 ether);

        manager = new PoolManager(address(this));
        gasToken = new SwapVMGasToken(INITIAL_SUPPLY, address(this));
        PoolModifyLiquidityTest liquidityRouter = new PoolModifyLiquidityTest(manager);
        router = new SwapVMStage2Router(manager);

        uint64 nextNonce = vm.getNonce(address(this));
        address predictedKernel = vm.computeCreateAddress(address(this), nextNonce);
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        bytes memory args = abi.encode(
            manager,
            SwapVMKernel(predictedKernel),
            gasToken,
            address(this),
            address(this),
            uint16(0),
            BYTE_GAS_PRICE,
            POOL_FEE,
            TICK_SPACING
        );
        (address expectedHook, bytes32 salt) = HookMiner.find(address(this), flags, type(SwapVMHook).creationCode, args);
        kernel = new SwapVMKernelStage2Harness(expectedHook, BYTE_GAS_PRICE);
        hook = new SwapVMHook{salt: salt}(
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
    }

    function test_referenceRegistryPinsExactAmmPackage() public {
        SwapVMReferenceRegistry registry = new SwapVMReferenceRegistry();
        bytes memory packageBytes = _package("CPAMM-v1");
        assertTrue(registry.verifyPackage(registry.CPAMM_INTERFACE_ID(), packageBytes));
        assertEq(keccak256(packageBytes), registry.CPAMM_CODE_HASH());
        packageBytes[packageBytes.length - 1] ^= bytes1(uint8(1));
        assertFalse(registry.verifyPackage(registry.CPAMM_INTERFACE_ID(), packageBytes));
    }

    function test_stage6A_fixture_cpammSwap() public {
        (bytes32 token0, bytes32 token1, bytes32 amm,) = _deploySystem();
        _call(amm, "createPair(bytes32,bytes32,uint256)", abi.encode(token0, token1, uint256(3000)), 3);
        _call(token0, "approve(bytes32,uint256)", abi.encode(amm, type(uint128).max), 4);
        _call(token1, "approve(bytes32,uint256)", abi.encode(amm, type(uint128).max), 5);
        _call(amm, "addLiquidity(uint256,uint256,uint256)", abi.encode(100_000, 200_000, 100_000), 6);
        uint256 adjusted = uint256(10_000) * 997_000 / FEE_DENOMINATOR;
        uint256 expectedOut = uint256(200_000) * adjusted / (100_000 + adjusted);
        vm.recordLogs();
        _call(amm, "swapExactIn(bytes32,uint256,uint256)", abi.encode(token0, uint256(10_000), expectedOut), 7);
        ReceiptFixture.assertOrWrite(vm, "cpamm-swap", address(kernel), vm.getRecordedLogs());
    }

    function test_cpammCreateAddSwapRemoveThroughSrc20Calls() public {
        (bytes32 token0, bytes32 token1, bytes32 amm, bytes32 actorId) = _deploySystem();

        _call(amm, "createPair(bytes32,bytes32,uint256)", abi.encode(token0, token1, uint256(3000)), 3);
        _call(token0, "approve(bytes32,uint256)", abi.encode(amm, uint256(800_000)), 4);
        _call(token1, "approve(bytes32,uint256)", abi.encode(amm, uint256(1_600_000)), 5);

        vm.recordLogs();
        _call(amm, "addLiquidity(uint256,uint256,uint256)", abi.encode(100_000, 200_000, 100_000), 6);
        bytes memory addReceipt = _eventPayload(vm.getRecordedLogs());
        _assertNestedReceipt(addReceipt, token0, token1, amm, ADD_TOPIC);
        (uint256 reserve0, uint256 reserve1) = _reserves(amm);
        assertEq(reserve0, 100_000);
        assertEq(reserve1, 200_000);
        assertEq(_wordQuery(amm, "totalShares()", bytes("")), 100_000);
        assertEq(_wordQuery(amm, "sharesOf(bytes32)", abi.encode(actorId)), 100_000);
        _assertReservesBacked(token0, token1, amm);

        uint256 amountIn = 10_000;
        uint256 adjusted = amountIn * (FEE_DENOMINATOR - 3000) / FEE_DENOMINATOR;
        uint256 expectedOut = reserve1 * adjusted / (reserve0 + adjusted);
        uint256 kBefore = reserve0 * reserve1;
        vm.recordLogs();
        _call(amm, "swapExactIn(bytes32,uint256,uint256)", abi.encode(token0, amountIn, expectedOut), 7);
        bytes memory swapReceipt = _eventPayload(vm.getRecordedLogs());
        _assertNestedReceipt(swapReceipt, token0, token1, amm, SWAP_TOPIC);
        (reserve0, reserve1) = _reserves(amm);
        assertEq(reserve0, 110_000);
        assertEq(reserve1, 200_000 - expectedOut);
        assertGe(reserve0 * reserve1, kBefore);
        _assertReservesBacked(token0, token1, amm);

        uint256 shares = 50_000;
        uint256 expected0 = shares * reserve0 / 100_000;
        uint256 expected1 = shares * reserve1 / 100_000;
        vm.recordLogs();
        _call(amm, "removeLiquidity(uint256,uint256,uint256)", abi.encode(shares, expected0, expected1), 8);
        bytes memory removeReceipt = _eventPayload(vm.getRecordedLogs());
        _assertNestedReceipt(removeReceipt, token0, token1, amm, REMOVE_TOPIC);
        (reserve0, reserve1) = _reserves(amm);
        assertEq(reserve0, 110_000 - expected0);
        assertEq(reserve1, 200_000 - expectedOut - expected1);
        assertEq(_wordQuery(amm, "totalShares()", bytes("")), 50_000);
        assertEq(_wordQuery(amm, "sharesOf(bytes32)", abi.encode(actorId)), 50_000);
        _assertReservesBacked(token0, token1, amm);
        _assertSettled();
    }

    function test_cpammFailedSlippageAndInvalidTokenRollbackEverything() public {
        (bytes32 token0, bytes32 token1, bytes32 amm, bytes32 actorId) = _deploySystem();
        _call(amm, "createPair(bytes32,bytes32,uint256)", abi.encode(token0, token1, uint256(3000)), 3);
        _call(token0, "approve(bytes32,uint256)", abi.encode(amm, type(uint128).max), 4);
        _call(token1, "approve(bytes32,uint256)", abi.encode(amm, type(uint128).max), 5);
        _call(amm, "addLiquidity(uint256,uint256,uint256)", abi.encode(100_000, 200_000, 100_000), 6);

        (uint256 reserve0Before, uint256 reserve1Before) = _reserves(amm);
        uint256 actor0Before = _balance(token0, actorId);
        uint256 actor1Before = _balance(token1, actorId);
        uint64 heightBefore = kernel.executionHeight(worldId);
        uint256 supplyBefore = gasToken.totalSupply();
        vm.recordLogs();
        _callReverts(
            amm, "swapExactIn(bytes32,uint256,uint256)", abi.encode(token0, uint256(10_000), type(uint128).max), 7
        );
        assertEq(_countEvents(vm.getRecordedLogs()), 0);
        assertEq(kernel.executionHeight(worldId), heightBefore);
        assertEq(kernel.nonces(worldId, actorId), 7);
        assertEq(gasToken.totalSupply(), supplyBefore);
        assertEq(_balance(token0, actorId), actor0Before);
        assertEq(_balance(token1, actorId), actor1Before);
        (uint256 reserve0After, uint256 reserve1After) = _reserves(amm);
        assertEq(reserve0After, reserve0Before);
        assertEq(reserve1After, reserve1Before);

        _callReverts(
            amm, "swapExactIn(bytes32,uint256,uint256)", abi.encode(bytes32(uint256(0xdead)), uint256(1), uint256(0)), 7
        );
        assertEq(kernel.nonces(worldId, actorId), 7);
        _assertReservesBacked(token0, token1, amm);
        _assertSettled();
    }

    function test_cpammStaticMutationRejectedButQueriesWork() public {
        (bytes32 token0, bytes32 token1, bytes32 amm,) = _deploySystem();
        _call(amm, "createPair(bytes32,bytes32,uint256)", abi.encode(token0, token1, uint256(3000)), 3);
        (uint256 reserve0, uint256 reserve1) = _reserves(amm);
        assertEq(reserve0, 0);
        assertEq(reserve1, 0);

        vm.prank(actor);
        vm.expectRevert();
        kernel.staticCall(
            worldId,
            amm,
            abi.encodePacked(
                bytes4(keccak256("addLiquidity(uint256,uint256,uint256)")),
                abi.encode(uint256(1), uint256(1), uint256(1))
            ),
            ACTION_LIMIT
        );
    }

    function testFuzz_cpammExactInputFormulaAndInvariant(uint32 rawAmount) public {
        (bytes32 token0, bytes32 token1, bytes32 amm,) = _deploySystem();
        _call(amm, "createPair(bytes32,bytes32,uint256)", abi.encode(token0, token1, uint256(3000)), 3);
        _call(token0, "approve(bytes32,uint256)", abi.encode(amm, type(uint128).max), 4);
        _call(token1, "approve(bytes32,uint256)", abi.encode(amm, type(uint128).max), 5);
        _call(amm, "addLiquidity(uint256,uint256,uint256)", abi.encode(1_000_000, 2_000_000, 1_000_000), 6);
        uint256 amountIn = bound(uint256(rawAmount), 2, 100_000);
        uint256 adjusted = amountIn * 997_000 / FEE_DENOMINATOR;
        uint256 expectedOut = 2_000_000 * adjusted / (1_000_000 + adjusted);
        _call(amm, "swapExactIn(bytes32,uint256,uint256)", abi.encode(token0, amountIn, expectedOut), 7);
        (uint256 reserve0, uint256 reserve1) = _reserves(amm);
        assertEq(reserve0, 1_000_000 + amountIn);
        assertEq(reserve1, 2_000_000 - expectedOut);
        assertGe(reserve0 * reserve1, uint256(1_000_000) * 2_000_000);
        _assertReservesBacked(token0, token1, amm);
    }

    function _deploySystem() private returns (bytes32 token0, bytes32 token1, bytes32 amm, bytes32 actorId) {
        actorId = kernel.eoaAccountId(actor);
        token0 = _deploy(
            _package("SRC20-v1"),
            abi.encode(bytes32("Token Zero"), bytes32("TK0"), uint256(18), uint256(2_000_000), actorId),
            0
        );
        token1 = _deploy(
            _package("SRC20-v1"),
            abi.encode(bytes32("Token One"), bytes32("TK1"), uint256(18), uint256(4_000_000), actorId),
            1
        );
        amm = _deploy(_package("CPAMM-v1"), bytes(""), 2);
    }

    function _deploy(bytes memory packageBytes, bytes memory constructorInput, uint64 nonce)
        private
        returns (bytes32 contractId)
    {
        bytes32 actorId = kernel.eoaAccountId(actor);
        bytes32 codeHash = keccak256(packageBytes);
        contractId = kernel.contractAccountId(worldId, actorId, kernel.creatorNonce(worldId, actorId), codeHash);
        bytes memory payload = abi.encodePacked(bytes4(uint32(packageBytes.length)), packageBytes, constructorInput);
        SwapVMKernel.VMEnvelope memory action = _signedAction(SwapVMKernel.RootOp.DEPLOY, codeHash, payload, nonce);
        vm.prank(actor);
        router.swap{value: 1 ether}(key, _buyParams(), actor, abi.encode(action));
    }

    function _call(bytes32 target, string memory signature, bytes memory arguments, uint64 nonce) private {
        bytes memory payload = abi.encodePacked(bytes4(keccak256(bytes(signature))), arguments);
        SwapVMKernel.VMEnvelope memory action = _signedAction(SwapVMKernel.RootOp.CALL, target, payload, nonce);
        vm.prank(actor);
        router.swap{value: 1 ether}(key, _buyParams(), actor, abi.encode(action));
    }

    function _callReverts(bytes32 target, string memory signature, bytes memory arguments, uint64 nonce) private {
        bytes memory payload = abi.encodePacked(bytes4(keccak256(bytes(signature))), arguments);
        SwapVMKernel.VMEnvelope memory action = _signedAction(SwapVMKernel.RootOp.CALL, target, payload, nonce);
        vm.prank(actor);
        vm.expectRevert();
        router.swap{value: 1 ether}(key, _buyParams(), actor, abi.encode(action));
    }

    function _signedAction(SwapVMKernel.RootOp op, bytes32 target, bytes memory payload, uint64 nonce)
        private
        view
        returns (SwapVMKernel.VMEnvelope memory action)
    {
        action = SwapVMKernel.VMEnvelope({
            op: op,
            worldId: worldId,
            actor: vm.addr(ACTOR_KEY),
            targetOrCodeHash: target,
            payload: payload,
            byteGasLimit: ACTION_LIMIT,
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
    }

    function _wordQuery(bytes32 target, string memory signature, bytes memory arguments)
        private
        view
        returns (uint256 result)
    {
        bytes memory input = abi.encodePacked(bytes4(keccak256(bytes(signature))), arguments);
        (bytes memory output,) = kernel.staticCall(worldId, target, input, ACTION_LIMIT);
        assertEq(output.length, 32);
        result = abi.decode(output, (uint256));
    }

    function _reserves(bytes32 amm) private view returns (uint256 reserve0, uint256 reserve1) {
        bytes memory input = abi.encodePacked(bytes4(keccak256("getReserves()")));
        (bytes memory output,) = kernel.staticCall(worldId, amm, input, ACTION_LIMIT);
        assertEq(output.length, 64);
        (reserve0, reserve1) = abi.decode(output, (uint256, uint256));
    }

    function _balance(bytes32 token, bytes32 owner) private view returns (uint256) {
        return _wordQuery(token, "balanceOf(bytes32)", abi.encode(owner));
    }

    function _assertReservesBacked(bytes32 token0, bytes32 token1, bytes32 amm) private view {
        (uint256 reserve0, uint256 reserve1) = _reserves(amm);
        assertEq(_balance(token0, amm), reserve0);
        assertEq(_balance(token1, amm), reserve1);
    }

    function _assertNestedReceipt(
        bytes memory payload,
        bytes32 token0,
        bytes32 token1,
        bytes32 amm,
        bytes32 applicationTopic
    ) private pure {
        assertEq(uint8(payload[0]), 1);
        assertEq(uint8(payload[3]), 4);
        uint256 offset = 8;
        (bytes32 emitter, bytes32 topic, uint256 next) = _record(payload, offset);
        assertEq(emitter, token0);
        assertEq(topic, TRANSFER_TOPIC);
        (emitter, topic, next) = _record(payload, next);
        assertEq(emitter, token1);
        assertEq(topic, TRANSFER_TOPIC);
        (emitter, topic,) = _record(payload, next);
        assertEq(emitter, amm);
        assertEq(topic, applicationTopic);
    }

    function _record(bytes memory payload, uint256 offset)
        private
        pure
        returns (bytes32 emitter, bytes32 firstTopic, uint256 next)
    {
        emitter = _word(payload, offset);
        uint256 topicCount = uint8(payload[offset + 32]);
        assertGt(topicCount, 0);
        firstTopic = _word(payload, offset + 33);
        uint256 lengthOffset = offset + 33 + 32 * topicCount;
        uint256 dataLength = uint32(bytes4(_word(payload, lengthOffset)));
        next = lengthOffset + 4 + dataLength + 4;
    }

    function _eventPayload(Vm.Log[] memory logs) private view returns (bytes memory payload) {
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(kernel) && logs[i].topics[0] == EVENTS_TOPIC) {
                payload = abi.decode(logs[i].data, (bytes));
                ++count;
            }
        }
        assertEq(count, 1);
    }

    function _countEvents(Vm.Log[] memory logs) private view returns (uint256 count) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(kernel) && logs[i].topics[0] == EVENTS_TOPIC) ++count;
        }
    }

    function _package(string memory name) private view returns (bytes memory) {
        string memory json = vm.readFile(string.concat("reference/", name, ".json"));
        return json.readBytes(".package");
    }

    function _buyParams() private pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
    }

    function _word(bytes memory data, uint256 offset) private pure returns (bytes32 value) {
        assembly ("memory-safe") {
            value := mload(add(add(data, 0x20), offset))
        }
    }

    function _assertSettled() private view {
        IPoolManager poolManager = IPoolManager(address(manager));
        assertEq(poolManager.getNonzeroDeltaCount(), 0);
        assertEq(poolManager.currencyDelta(address(router), key.currency0), 0);
        assertEq(poolManager.currencyDelta(address(router), key.currency1), 0);
        assertEq(poolManager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(poolManager.currencyDelta(address(hook), key.currency1), 0);
    }

    receive() external payable {}
}
