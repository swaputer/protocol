// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {SwapVMGasToken} from "../src/SwapVMGasToken.sol";
import {SwapVMHook} from "../src/SwapVMHook.sol";
import {SwapVMKernel} from "../src/SwapVMKernel.sol";
import {SwapVMMiniVM} from "../src/SwapVMMiniVM.sol";
import {ReceiptFixture} from "./utils/ReceiptFixture.sol";

contract SwapVMKernelStage2Harness is SwapVMKernel {
    constructor(address boundHook, uint128 price) SwapVMKernel(boundHook, price) {}

    function install(bytes32 worldId, bytes32 target, bytes calldata code) external {
        _registerProgram(worldId, target, code);
    }
}

contract SwapVMStage2Router is IUnlockCallback {
    using CurrencySettler for Currency;
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;

    struct CallbackData {
        address payer;
        address recipient;
        PoolKey key;
        SwapParams params;
        bytes hookData;
    }

    error OnlyPoolManager();
    error InvalidRecipient();
    error ExecutorNotAuthorized(address expected, address actual);

    constructor(IPoolManager poolManager) {
        manager = poolManager;
    }

    function swap(PoolKey calldata key, SwapParams calldata params, address recipient, bytes calldata hookData)
        external
        payable
        returns (BalanceDelta delta)
    {
        if (recipient == address(0)) revert InvalidRecipient();
        if (hookData.length != 0) {
            SwapVMKernel.VMEnvelope memory action = abi.decode(hookData, (SwapVMKernel.VMEnvelope));
            if (action.recipient != recipient) revert InvalidRecipient();
            if (action.authorizedExecutor != address(0) && action.authorizedExecutor != msg.sender) {
                revert ExecutorNotAuthorized(action.authorizedExecutor, msg.sender);
            }
        }
        delta = abi.decode(
            manager.unlock(abi.encode(CallbackData(msg.sender, recipient, key, params, hookData))), (BalanceDelta)
        );
        uint256 refund = address(this).balance;
        if (refund != 0) CurrencyLibrary.ADDRESS_ZERO.transfer(msg.sender, refund);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert OnlyPoolManager();
        CallbackData memory callback = abi.decode(data, (CallbackData));
        BalanceDelta delta = manager.swap(callback.key, callback.params, callback.hookData);

        int256 delta0 = manager.currencyDelta(address(this), callback.key.currency0);
        int256 delta1 = manager.currencyDelta(address(this), callback.key.currency1);
        if (delta0 < 0) callback.key.currency0.settle(manager, callback.payer, uint256(-delta0), false);
        if (delta1 < 0) callback.key.currency1.settle(manager, callback.payer, uint256(-delta1), false);
        if (delta0 > 0) callback.key.currency0.take(manager, callback.recipient, uint256(delta0), false);
        if (delta1 > 0) callback.key.currency1.take(manager, callback.recipient, uint256(delta1), false);
        return abi.encode(delta);
    }

    receive() external payable {}
}

contract SwapVMStage2Test is Test {
    using BalanceDeltaLibrary for BalanceDelta;
    using TransientStateLibrary for IPoolManager;

    uint256 internal constant INITIAL_SUPPLY = 1e36;
    uint128 internal constant BYTE_GAS_PRICE = 1e12;
    uint24 internal constant POOL_FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    uint160 internal constant SQRT_PRICE_1_1 = 1 << 96;
    uint256 internal constant ACTOR_KEY = 0xA11CE;
    uint256 internal constant OTHER_KEY = 0xB0B;
    uint256 internal constant SECP256K1N = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;

    bytes32 internal constant EVENTS_TOPIC = keccak256("Events(bytes32,uint64,bytes)");

    PoolManager internal manager;
    SwapVMGasToken internal token;
    SwapVMKernelStage2Harness internal kernel;
    SwapVMHook internal hook;
    SwapVMStage2Router internal router;
    PoolKey internal key;
    bytes32 internal worldId;
    address internal actor;

    bytes32 internal constant STATE_TARGET = 0x0100000000000000000000000000000000000000000000000000000000001001;
    bytes32 internal constant VIEW_TARGET = 0x0100000000000000000000000000000000000000000000000000000000001002;
    bytes32 internal constant LOOP_TARGET = 0x0100000000000000000000000000000000000000000000000000000000001003;
    bytes32 internal constant TX_CONTEXT_TARGET = 0x0100000000000000000000000000000000000000000000000000000000001004;

    // Empty calldata writes slot[1] = 42; non-empty calldata takes a read-only branch.
    bytes internal constant STATE_PROGRAM = hex"36601457602a60015560015460005260206000f35b60015460005260206000f3";
    // Return slot[1]. Executed length is 11 bytes.
    bytes internal constant VIEW_PROGRAM = hex"60015460005260206000f3";
    // Three loop iterations followed by STOP. Executed byte count is 28.
    bytes internal constant LOOP_PROGRAM = hex"60035b600103806002575000";
    // Store TXROUTER, TXEXECUTOR and TXRECIPIENT into slots 0, 1 and 2.
    bytes internal constant TX_CONTEXT_PROGRAM = hex"ba5f55bb600155bc60025500";

    function setUp() public virtual {
        actor = vm.addr(ACTOR_KEY);
        vm.deal(address(this), 1e30);
        vm.deal(actor, 100 ether);

        manager = new PoolManager(address(this));
        token = new SwapVMGasToken(INITIAL_SUPPLY, address(this));
        PoolModifyLiquidityTest liquidityRouter = new PoolModifyLiquidityTest(manager);
        router = new SwapVMStage2Router(manager);

        uint64 nextNonce = vm.getNonce(address(this));
        address predictedKernel = vm.computeCreateAddress(address(this), nextNonce);
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        bytes memory hookArgs = abi.encode(
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
            HookMiner.find(address(this), flags, type(SwapVMHook).creationCode, hookArgs);

        kernel = new SwapVMKernelStage2Harness(expectedHook, BYTE_GAS_PRICE);
        hook = new SwapVMHook{salt: salt}(
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
        manager.initialize(key, SQRT_PRICE_1_1);

        token.approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity{value: 1e25}(
            key,
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e24, salt: bytes32(0)}),
            bytes("")
        );
        kernel.install(worldId, STATE_TARGET, STATE_PROGRAM);
        kernel.install(worldId, VIEW_TARGET, VIEW_PROGRAM);
        kernel.install(worldId, LOOP_TARGET, LOOP_PROGRAM);
        kernel.install(worldId, TX_CONTEXT_TARGET, TX_CONTEXT_PROGRAM);
    }

    function test_authenticatedCallExecutesMetersStoresBurnsAndAdvancesNonce() public {
        uint256 supplyBefore = token.totalSupply();
        uint256 actorBalanceBefore = token.balanceOf(actor);
        SwapVMKernel.VMEnvelope memory action = _signedAction(
            ACTOR_KEY,
            STATE_TARGET,
            bytes(""),
            100,
            0,
            0,
            uint64(block.timestamp + 1 days),
            actor,
            actor,
            1 ether,
            TickMath.MIN_SQRT_PRICE + 1,
            address(router)
        );

        vm.recordLogs();
        vm.prank(actor);
        BalanceDelta delta = router.swap{value: 1 ether}(
            key, _buyParams(1 ether, TickMath.MIN_SQRT_PRICE + 1), actor, abi.encode(action)
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 burned = 20 * uint256(BYTE_GAS_PRICE);
        bytes32 actorId = kernel.eoaAccountId(actor);
        assertEq(kernel.executionHeight(worldId), 1);
        assertEq(kernel.executedBytes(worldId), 20);
        assertEq(kernel.nonces(worldId, actorId), 1);
        assertEq(kernel.programStorageAt(worldId, STATE_TARGET, bytes32(uint256(1))), bytes32(uint256(42)));
        assertEq(supplyBefore - token.totalSupply(), burned);
        assertEq(token.balanceOf(actor) - actorBalanceBefore, uint128(delta.amount1()));
        _assertStage2Receipt(logs, actorId, STATE_TARGET, 20, burned);
        ReceiptFixture.assertOrWrite(vm, "authenticated-call", address(kernel), logs);
        _assertSettled();
    }

    function test_stage3DeployValidatesPackageRunsConstructorAndEmitsTwoRecords() public {
        bytes memory code = hex"5f355f5500";
        bytes memory packageBytes = _package(0, 4, keccak256("Stage3.ConstructorStorage"), code);
        bytes32 codeHash = keccak256(packageBytes);
        bytes memory constructorInput = abi.encode(uint256(42));
        bytes memory deployPayload =
            abi.encodePacked(bytes4(uint32(packageBytes.length)), packageBytes, constructorInput);
        SwapVMKernel.VMEnvelope memory action = _signedActionForOp(
            SwapVMKernel.RootOp.DEPLOY,
            ACTOR_KEY,
            codeHash,
            deployPayload,
            5,
            0,
            0,
            uint64(block.timestamp + 1 days),
            actor,
            actor,
            1 ether,
            TickMath.MIN_SQRT_PRICE + 1,
            address(router)
        );
        bytes32 actorId = kernel.eoaAccountId(actor);
        bytes32 contractId = kernel.contractAccountId(worldId, actorId, 0, codeHash);
        uint256 supplyBefore = token.totalSupply();

        vm.recordLogs();
        vm.prank(actor);
        router.swap{value: 1 ether}(key, _buyParams(1 ether, TickMath.MIN_SQRT_PRICE + 1), actor, abi.encode(action));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(kernel.packageRegistered(worldId, codeHash));
        assertEq(kernel.programCodeHash(worldId, contractId), codeHash);
        assertEq(kernel.programCodeLength(worldId, contractId), code.length);
        (address packageBlob, uint16 packageLength, uint16 blobCodeLength, bytes32 blobCodeHash) =
            kernel.packageBlob(worldId, codeHash);
        assertNotEq(packageBlob, address(0));
        assertEq(packageLength, packageBytes.length);
        assertEq(blobCodeLength, code.length);
        assertEq(packageBlob.codehash, blobCodeHash);
        assertEq(packageBlob.code.length, 1 + packageBytes.length + ((code.length + 7) / 8));
        (uint16 constructorEntry, uint16 runtimeEntry) = kernel.programEntries(worldId, contractId);
        assertEq(constructorEntry, 0);
        assertEq(runtimeEntry, 4);
        assertEq(kernel.creatorNonce(worldId, actorId), 1);
        assertEq(kernel.nonces(worldId, actorId), 1);
        assertEq(kernel.programStorageAt(worldId, contractId, bytes32(0)), bytes32(uint256(42)));
        assertEq(kernel.executedBytes(worldId), 5);
        assertEq(supplyBefore - token.totalSupply(), 5 * uint256(BYTE_GAS_PRICE));
        _assertDeployReceipt(logs, contractId, actorId, codeHash, 5);
        ReceiptFixture.assertOrWrite(vm, "deploy", address(kernel), logs);

        (bytes memory output, uint32 used) = kernel.staticCall(worldId, contractId, bytes(""), 1);
        assertEq(output.length, 0);
        assertEq(used, 1);
        _assertSettled();
    }

    function testFuzz_stage3DeployConstructorCalldataAndContractId(uint256 value) public {
        bytes memory packageBytes = _package(0, 4, keccak256("Stage3.FuzzConstructor"), hex"5f355f5500");
        bytes32 codeHash = keccak256(packageBytes);
        bytes32 actorId = kernel.eoaAccountId(actor);
        bytes32 contractId = kernel.contractAccountId(worldId, actorId, 0, codeHash);
        uint256 supplyBefore = token.totalSupply();

        _executeDeploy(packageBytes, codeHash, abi.encode(value), 5, 0);

        assertEq(kernel.programCodeHash(worldId, contractId), codeHash);
        assertEq(kernel.programStorageAt(worldId, contractId, bytes32(0)), bytes32(value));
        assertEq(kernel.creatorNonce(worldId, actorId), 1);
        assertEq(kernel.executedBytes(worldId), 5);
        assertEq(supplyBefore - token.totalSupply(), 5 * uint256(BYTE_GAS_PRICE));
        _assertSettled();
    }

    function test_stage3FailedConstructorRollsBackPackageInstanceCreatorNonceAndBurn() public {
        bytes memory code = hex"5f5ffd00";
        bytes memory packageBytes = _package(0, 3, keccak256("Stage3.RevertingConstructor"), code);
        bytes32 codeHash = keccak256(packageBytes);
        bytes memory deployPayload = abi.encodePacked(bytes4(uint32(packageBytes.length)), packageBytes);
        SwapVMKernel.VMEnvelope memory action = _signedActionForOp(
            SwapVMKernel.RootOp.DEPLOY,
            ACTOR_KEY,
            codeHash,
            deployPayload,
            3,
            0,
            0,
            uint64(block.timestamp + 1 days),
            actor,
            actor,
            1 ether,
            TickMath.MIN_SQRT_PRICE + 1,
            address(router)
        );
        bytes32 actorId = kernel.eoaAccountId(actor);
        bytes32 contractId = kernel.contractAccountId(worldId, actorId, 0, codeHash);
        uint256 supplyBefore = token.totalSupply();

        vm.recordLogs();
        vm.prank(actor);
        vm.expectRevert();
        router.swap{value: 1 ether}(key, _buyParams(1 ether, TickMath.MIN_SQRT_PRICE + 1), actor, abi.encode(action));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertFalse(kernel.packageRegistered(worldId, codeHash));
        assertEq(kernel.programCodeLength(worldId, contractId), 0);
        assertEq(kernel.creatorNonce(worldId, actorId), 0);
        assertEq(kernel.nonces(worldId, actorId), 0);
        assertEq(kernel.executionHeight(worldId), 0);
        assertEq(token.totalSupply(), supplyBefore);
        assertEq(_countEvents(logs), 0);
    }

    function test_stage3NestedCallSharesMeterStorageJournalAndReturnData() public {
        bytes32 callee = 0x0100000000000000000000000000000000000000000000000000000000003001;
        bytes32 caller = 0x0100000000000000000000000000000000000000000000000000000000003002;
        bytes memory calleeCode = hex"5f355f555f545f5260205ff3";
        bytes memory callerCode =
            abi.encodePacked(hex"602a5f52", bytes1(0x7f), callee, hex"60205f60206020f1503d60206020f3");
        kernel.install(worldId, callee, calleeCode);
        kernel.install(worldId, caller, callerCode);

        SwapVMKernel.VMEnvelope memory action = _signedAction(
            ACTOR_KEY,
            caller,
            bytes(""),
            64,
            0,
            0,
            uint64(block.timestamp + 1 days),
            actor,
            actor,
            1 ether,
            TickMath.MIN_SQRT_PRICE + 1,
            address(router)
        );
        uint256 supplyBefore = token.totalSupply();
        vm.prank(actor);
        router.swap{value: 1 ether}(key, _buyParams(1 ether, TickMath.MIN_SQRT_PRICE + 1), actor, abi.encode(action));

        assertEq(kernel.executedBytes(worldId), 64);
        assertEq(kernel.programStorageAt(worldId, callee, bytes32(0)), bytes32(uint256(42)));
        assertEq(kernel.programStorageAt(worldId, caller, bytes32(0)), bytes32(0));
        assertEq(supplyBefore - token.totalSupply(), 64 * uint256(BYTE_GAS_PRICE));

        vm.prank(actor);
        vm.expectRevert(abi.encodeWithSelector(SwapVMMiniVM.StaticViolation.selector, uint8(0x55)));
        kernel.staticCall(worldId, caller, bytes(""), 64);
    }

    function test_stage3NestedMeterLimitAndChildFailureRollbackRoot() public {
        bytes32 callee = 0x0100000000000000000000000000000000000000000000000000000000003011;
        bytes32 caller = 0x0100000000000000000000000000000000000000000000000000000000003012;
        kernel.install(worldId, callee, hex"5f355f555f545f5260205ff3");
        kernel.install(
            worldId, caller, abi.encodePacked(hex"602a5f52", bytes1(0x7f), callee, hex"60205f60206020f1503d60206020f3")
        );
        SwapVMKernel.VMEnvelope memory action = _signedAction(
            ACTOR_KEY,
            caller,
            bytes(""),
            63,
            0,
            0,
            uint64(block.timestamp + 1 days),
            actor,
            actor,
            1 ether,
            TickMath.MIN_SQRT_PRICE + 1,
            address(router)
        );
        uint256 supplyBefore = token.totalSupply();

        vm.prank(actor);
        vm.expectRevert();
        router.swap{value: 1 ether}(key, _buyParams(1 ether, TickMath.MIN_SQRT_PRICE + 1), actor, abi.encode(action));
        assertEq(kernel.programStorageAt(worldId, callee, bytes32(0)), bytes32(0));
        assertEq(kernel.executionHeight(worldId), 0);
        assertEq(kernel.nonces(worldId, kernel.eoaAccountId(actor)), 0);
        assertEq(token.totalSupply(), supplyBefore);
    }

    function test_stage3CallDepthAndTotalActiveMemoryLimits() public {
        bytes32 recursive = 0x0100000000000000000000000000000000000000000000000000000000003021;
        bytes memory recurseCode = abi.encodePacked(bytes1(0x7f), recursive, hex"5f5f5f5ff100");
        kernel.install(worldId, recursive, recurseCode);
        vm.expectRevert(abi.encodeWithSelector(SwapVMMiniVM.CallDepthExceeded.selector, uint16(33)));
        kernel.staticCall(worldId, recursive, bytes(""), 2_000);

        bytes32 memoryRecursive = 0x0100000000000000000000000000000000000000000000000000000000003022;
        bytes memory memoryCode = abi.encodePacked(hex"5f61ffe052", bytes1(0x7f), memoryRecursive, hex"5f5f5f5ff100");
        kernel.install(worldId, memoryRecursive, memoryCode);
        vm.expectRevert(abi.encodeWithSelector(SwapVMMiniVM.TotalMemoryOutOfBounds.selector, uint256(327_680)));
        kernel.staticCall(worldId, memoryRecursive, bytes(""), 2_000);
    }

    function test_stage3CreateUsesRegisteredHashConstructorNamespaceAndCreatorNonce() public {
        bytes memory childPackage = _package(0, 4, keccak256("Stage3.Child"), hex"5f355f5500");
        bytes32 childHash = keccak256(childPackage);
        bytes32 actorId = kernel.eoaAccountId(actor);
        _executeDeploy(childPackage, childHash, abi.encode(uint256(0)), 5, 0);

        bytes memory factoryCode =
            abi.encodePacked(bytes1(0x00), hex"602a5f52", bytes1(0x7f), childHash, hex"60205ff05f5500");
        bytes memory factoryPackage = _package(0, 1, keccak256("Stage3.Factory"), factoryCode);
        bytes32 factoryHash = keccak256(factoryPackage);
        bytes32 factoryId = kernel.contractAccountId(worldId, actorId, 1, factoryHash);
        _executeDeploy(factoryPackage, factoryHash, bytes(""), 1, 1);

        SwapVMKernel.VMEnvelope memory callAction = _signedAction(
            ACTOR_KEY,
            factoryId,
            bytes(""),
            49,
            0,
            2,
            uint64(block.timestamp + 1 days),
            actor,
            actor,
            1 ether,
            TickMath.MIN_SQRT_PRICE + 1,
            address(router)
        );
        uint256 supplyBefore = token.totalSupply();
        vm.recordLogs();
        vm.prank(actor);
        router.swap{value: 1 ether}(
            key, _buyParams(1 ether, TickMath.MIN_SQRT_PRICE + 1), actor, abi.encode(callAction)
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 createdId = kernel.contractAccountId(worldId, factoryId, 0, childHash);
        assertEq(kernel.executedBytes(worldId), 49);
        assertEq(kernel.creatorNonce(worldId, factoryId), 1);
        assertEq(kernel.programCodeHash(worldId, createdId), childHash);
        assertEq(kernel.programStorageAt(worldId, createdId, bytes32(0)), bytes32(uint256(42)));
        assertEq(kernel.programStorageAt(worldId, factoryId, bytes32(0)), createdId);
        assertEq(supplyBefore - token.totalSupply(), 49 * uint256(BYTE_GAS_PRICE));
        assertEq(kernel.nonces(worldId, actorId), 3);
        _assertInternalDeployReceipt(logs, createdId, factoryId, childHash, actorId, 49);
    }

    function test_staticCallReturnsStateWithoutMutationNonceBurnHeightOrLog() public {
        _executeStateProgram();
        uint256 supplyBefore = token.totalSupply();
        uint64 heightBefore = kernel.executionHeight(worldId);
        uint64 nonceBefore = kernel.nonces(worldId, kernel.eoaAccountId(actor));

        vm.recordLogs();
        vm.prank(actor);
        (bytes memory output, uint32 used) = kernel.staticCall(worldId, STATE_TARGET, hex"01", 16);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(abi.decode(output, (uint256)), 42);
        assertEq(used, 16);
        assertEq(kernel.executionHeight(worldId), heightBefore);
        assertEq(kernel.nonces(worldId, kernel.eoaAccountId(actor)), nonceBefore);
        assertEq(token.totalSupply(), supplyBefore);
        assertEq(_countEvents(logs), 0);
    }

    function test_staticCallRejectsStateMutation() public {
        vm.expectRevert(abi.encodeWithSelector(SwapVMMiniVM.StaticViolation.selector, uint8(0x55)));
        kernel.staticCall(worldId, STATE_TARGET, bytes(""), 100);
    }

    function test_loopMetersRepeatedBytesExactly() public {
        vm.prank(actor);
        (, uint32 used) = kernel.staticCall(worldId, LOOP_TARGET, bytes(""), 28);
        assertEq(used, 28);

        vm.expectRevert(abi.encodeWithSelector(SwapVMMiniVM.OutOfByteGas.selector, uint32(28), uint32(27)));
        kernel.staticCall(worldId, LOOP_TARGET, bytes(""), 27);
    }

    function test_replayRevertsAndRollsBackSwapVmAndSupply() public {
        SwapVMKernel.VMEnvelope memory action = _signedAction(
            ACTOR_KEY,
            STATE_TARGET,
            bytes(""),
            100,
            0,
            0,
            uint64(block.timestamp + 1 days),
            actor,
            actor,
            1 ether,
            TickMath.MIN_SQRT_PRICE + 1,
            address(router)
        );
        vm.prank(actor);
        router.swap{value: 1 ether}(key, _buyParams(1 ether, TickMath.MIN_SQRT_PRICE + 1), actor, abi.encode(action));

        uint256 supplyBefore = token.totalSupply();
        uint256 storageBefore = uint256(kernel.programStorageAt(worldId, STATE_TARGET, bytes32(uint256(1))));
        vm.recordLogs();
        vm.prank(actor);
        vm.expectRevert();
        router.swap{value: 1 ether}(key, _buyParams(1 ether, TickMath.MIN_SQRT_PRICE + 1), actor, abi.encode(action));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(kernel.executionHeight(worldId), 1);
        assertEq(kernel.nonces(worldId, kernel.eoaAccountId(actor)), 1);
        assertEq(token.totalSupply(), supplyBefore);
        assertEq(uint256(kernel.programStorageAt(worldId, STATE_TARGET, bytes32(uint256(1)))), storageBefore);
        assertEq(_countEvents(logs), 0);
    }

    function test_validatorRejectsUnknownAndTruncatedInstructions() public {
        vm.expectRevert(abi.encodeWithSelector(SwapVMMiniVM.UnknownOpcode.selector, uint8(0xfe), uint256(0)));
        kernel.validateProgram(hex"fe");

        vm.expectRevert(abi.encodeWithSelector(SwapVMMiniVM.TruncatedImmediate.selector, uint256(0), uint8(2)));
        kernel.validateProgram(hex"61ff");
    }

    function test_runtimeRejectsInvalidJumpBoundary() public {
        bytes memory code = hex"60015600";
        bytes32 target = _targetFor(code);
        kernel.install(worldId, target, code);
        vm.expectRevert(abi.encodeWithSelector(SwapVMMiniVM.InvalidJumpDestination.selector, uint256(1)));
        kernel.staticCall(worldId, target, bytes(""), 4);
    }

    function test_buyOutOfByteGasRollsBackAllSwapVmEffects() public {
        SwapVMKernel.VMEnvelope memory action = _signedAction(
            ACTOR_KEY,
            STATE_TARGET,
            bytes(""),
            19,
            0,
            0,
            uint64(block.timestamp + 1 days),
            actor,
            actor,
            1 ether,
            TickMath.MIN_SQRT_PRICE + 1,
            address(router)
        );
        uint256 supplyBefore = token.totalSupply();
        uint256 actorBalanceBefore = token.balanceOf(actor);

        vm.recordLogs();
        vm.prank(actor);
        // PoolManager wraps callback errors; state assertions below prove the underlying exceptional halt is atomic.
        vm.expectRevert();
        router.swap{value: 1 ether}(key, _buyParams(1 ether, TickMath.MIN_SQRT_PRICE + 1), actor, abi.encode(action));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(kernel.executionHeight(worldId), 0);
        assertEq(kernel.executedBytes(worldId), 0);
        assertEq(kernel.nonces(worldId, kernel.eoaAccountId(actor)), 0);
        assertEq(kernel.programStorageAt(worldId, STATE_TARGET, bytes32(uint256(1))), bytes32(0));
        assertEq(token.totalSupply(), supplyBefore);
        assertEq(token.balanceOf(actor), actorBalanceBefore);
        assertEq(_countEvents(logs), 0);
        _assertSettled();
    }

    function test_explicitRevertDiscardsJournalNonceHeightBurnAndLog() public {
        bytes memory code = hex"602a6001555f5ffd";
        bytes32 target = _targetFor(code);
        kernel.install(worldId, target, code);
        SwapVMKernel.VMEnvelope memory action = _signedAction(
            ACTOR_KEY,
            target,
            bytes(""),
            8,
            0,
            0,
            uint64(block.timestamp + 1 days),
            actor,
            actor,
            1 ether,
            TickMath.MIN_SQRT_PRICE + 1,
            address(router)
        );
        uint256 supplyBefore = token.totalSupply();

        vm.recordLogs();
        vm.prank(actor);
        // PoolManager wraps callback errors; direct interpreter tests assert the precise VM error selectors.
        vm.expectRevert();
        router.swap{value: 1 ether}(key, _buyParams(1 ether, TickMath.MIN_SQRT_PRICE + 1), actor, abi.encode(action));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(kernel.executionHeight(worldId), 0);
        assertEq(kernel.nonces(worldId, kernel.eoaAccountId(actor)), 0);
        assertEq(kernel.programStorageAt(worldId, target, bytes32(uint256(1))), bytes32(0));
        assertEq(token.totalSupply(), supplyBefore);
        assertEq(_countEvents(logs), 0);
    }

    function test_mutatedFirstEnvelopeCannotRecoverFreshActor() public {
        uint160 priceLimit = TickMath.MIN_SQRT_PRICE + 1;
        uint64 deadline = uint64(block.timestamp + 1 days);
        SwapVMKernel.VMEnvelope memory valid = _signedAction(
            ACTOR_KEY, STATE_TARGET, bytes(""), 100, 0, 0, deadline, actor, actor, 1 ether, priceLimit, address(router)
        );
        SwapVMKernel.VMEnvelope memory changed = valid;
        changed.targetOrCodeHash = VIEW_TARGET;

        _assertRejectedAction(changed, actor, 1 ether, priceLimit, router);
        assertEq(kernel.executionHeight(worldId), 0);
        assertEq(kernel.nonces(worldId, kernel.eoaAccountId(actor)), 0);
    }

    function test_explicitActorMustMatchRecoveredSigner() public {
        uint160 priceLimit = TickMath.MIN_SQRT_PRICE + 1;
        SwapVMKernel.VMEnvelope memory action = _signedAction(
            ACTOR_KEY,
            STATE_TARGET,
            bytes(""),
            100,
            0,
            0,
            uint64(block.timestamp + 1 days),
            actor,
            actor,
            1 ether,
            priceLimit,
            address(router)
        );
        action.actor = vm.addr(OTHER_KEY);
        _assertRejectedAction(action, actor, 1 ether, priceLimit, router);
        assertEq(kernel.nonces(worldId, kernel.eoaAccountId(actor)), 0);
        assertEq(kernel.nonces(worldId, kernel.eoaAccountId(action.actor)), 0);
    }

    function test_v12DomainUsesSwaputerName() public view {
        bytes32 expected = keccak256(
            abi.encode(
                kernel.EIP712_DOMAIN_TYPEHASH(),
                keccak256("Swaputer"),
                keccak256("1.2"),
                block.chainid,
                address(kernel),
                worldId
            )
        );

        assertEq(kernel.domainSeparator(worldId), expected);
    }

    function test_legacyVersionsAndSwapVMDomainNameAreRejectedByV12() public {
        uint160 priceLimit = TickMath.MIN_SQRT_PRICE + 1;
        SwapVMKernel.VMEnvelope memory action = _signedAction(
            ACTOR_KEY,
            STATE_TARGET,
            bytes(""),
            100,
            0,
            0,
            uint64(block.timestamp + 1 days),
            actor,
            actor,
            1 ether,
            priceLimit,
            address(router)
        );
        bytes32 oldTypeHash = keccak256(
            "VMAction(uint8 op,bytes32 worldId,bytes32 targetOrCodeHash,bytes32 payloadHash,uint32 byteGasLimit,uint128 minNetTokenOut,uint128 exactEthAmountIn,uint160 sqrtPriceLimitX96,address recipient,address router,address authorizedExecutor,uint64 nonce,uint64 deadline)"
        );
        bytes32 oldStructHash = keccak256(
            abi.encode(
                oldTypeHash,
                uint8(action.op),
                action.worldId,
                action.targetOrCodeHash,
                keccak256(action.payload),
                action.byteGasLimit,
                action.minNetTokenOut,
                uint128(1 ether),
                priceLimit,
                action.recipient,
                address(router),
                action.authorizedExecutor,
                action.nonce,
                action.deadline
            )
        );
        bytes32 oldDomain = keccak256(
            abi.encode(
                kernel.EIP712_DOMAIN_TYPEHASH(),
                keccak256("SwapVM"),
                keccak256("1"),
                block.chainid,
                address(kernel),
                worldId
            )
        );
        bytes32 oldDigest = keccak256(abi.encodePacked(hex"1901", oldDomain, oldStructHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ACTOR_KEY, oldDigest);
        action.signature = abi.encodePacked(r, s, v);

        _assertRejectedAction(action, actor, 1 ether, priceLimit, router);

        bytes32 v11StructHash = keccak256(
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
                priceLimit,
                action.recipient,
                address(router),
                action.authorizedExecutor,
                action.nonce,
                action.deadline
            )
        );
        bytes32 v11Domain = keccak256(
            abi.encode(
                kernel.EIP712_DOMAIN_TYPEHASH(),
                keccak256("SwapVM"),
                keccak256("1.1"),
                block.chainid,
                address(kernel),
                worldId
            )
        );
        bytes32 v11Digest = keccak256(abi.encodePacked(hex"1901", v11Domain, v11StructHash));
        (v, r, s) = vm.sign(ACTOR_KEY, v11Digest);
        action.signature = abi.encodePacked(r, s, v);

        _assertRejectedAction(action, actor, 1 ether, priceLimit, router);

        bytes32 oldNameCurrentVersionDomain = keccak256(
            abi.encode(
                kernel.EIP712_DOMAIN_TYPEHASH(),
                keccak256("SwapVM"),
                keccak256("1.2"),
                block.chainid,
                address(kernel),
                worldId
            )
        );
        bytes32 oldNameCurrentVersionDigest =
            keccak256(abi.encodePacked(hex"1901", oldNameCurrentVersionDomain, v11StructHash));
        (v, r, s) = vm.sign(ACTOR_KEY, oldNameCurrentVersionDigest);
        action.signature = abi.encodePacked(r, s, v);

        _assertRejectedAction(action, actor, 1 ether, priceLimit, router);
    }

    function test_v12TxContextOpcodesExposeRouterExecutorAndRecipient() public {
        address relayer = vm.addr(OTHER_KEY);
        address recipient = address(0xCAFE);
        uint160 priceLimit = TickMath.MIN_SQRT_PRICE + 1;
        vm.deal(relayer, 2 ether);
        SwapVMKernel.VMEnvelope memory action = _signedAction(
            ACTOR_KEY,
            TX_CONTEXT_TARGET,
            bytes(""),
            100,
            0,
            0,
            uint64(block.timestamp + 1 days),
            recipient,
            relayer,
            1 ether,
            priceLimit,
            address(router)
        );

        vm.prank(relayer);
        router.swap{value: 1 ether}(key, _buyParams(1 ether, priceLimit), recipient, abi.encode(action));

        assertEq(
            kernel.programStorageAt(worldId, TX_CONTEXT_TARGET, bytes32(0)), bytes32(uint256(uint160(address(router))))
        );
        assertEq(
            kernel.programStorageAt(worldId, TX_CONTEXT_TARGET, bytes32(uint256(1))), bytes32(uint256(uint160(relayer)))
        );
        assertEq(
            kernel.programStorageAt(worldId, TX_CONTEXT_TARGET, bytes32(uint256(2))),
            bytes32(uint256(uint160(recipient)))
        );
        assertEq(kernel.nonces(worldId, kernel.eoaAccountId(actor)), 1);
    }

    function test_permissionlessRelayPreservesRecoveredActor() public {
        address relayer = vm.addr(OTHER_KEY);
        vm.deal(relayer, 2 ether);
        SwapVMKernel.VMEnvelope memory action = _signedAction(
            ACTOR_KEY,
            STATE_TARGET,
            bytes(""),
            100,
            0,
            0,
            uint64(block.timestamp + 1 days),
            actor,
            address(0),
            1 ether,
            TickMath.MIN_SQRT_PRICE + 1,
            address(router)
        );

        vm.prank(relayer);
        router.swap{value: 1 ether}(key, _buyParams(1 ether, TickMath.MIN_SQRT_PRICE + 1), actor, abi.encode(action));

        assertEq(kernel.executionHeight(worldId), 1);
        assertEq(kernel.nonces(worldId, kernel.eoaAccountId(actor)), 1);
        assertEq(kernel.nonces(worldId, kernel.eoaAccountId(relayer)), 0);
        assertGt(token.balanceOf(actor), 0);
        assertEq(token.balanceOf(relayer), 0);
    }

    function test_actorCanAuthorizeDifferentRecipient() public {
        address relayer = vm.addr(OTHER_KEY);
        vm.deal(relayer, 2 ether);
        SwapVMKernel.VMEnvelope memory action = _signedAction(
            ACTOR_KEY,
            STATE_TARGET,
            bytes(""),
            100,
            0,
            0,
            uint64(block.timestamp + 1 days),
            relayer,
            address(0),
            1 ether,
            TickMath.MIN_SQRT_PRICE + 1,
            address(router)
        );

        vm.prank(relayer);
        router.swap{value: 1 ether}(key, _buyParams(1 ether, TickMath.MIN_SQRT_PRICE + 1), relayer, abi.encode(action));

        assertEq(kernel.executionHeight(worldId), 1);
        assertEq(kernel.nonces(worldId, kernel.eoaAccountId(actor)), 1);
        assertEq(kernel.nonces(worldId, kernel.eoaAccountId(relayer)), 0);
        assertEq(token.balanceOf(actor), 0);
        assertGt(token.balanceOf(relayer), 0);
    }

    function test_zeroActorIsRejected() public {
        uint160 priceLimit = TickMath.MIN_SQRT_PRICE + 1;
        SwapVMKernel.VMEnvelope memory action = _signedAction(
            ACTOR_KEY,
            STATE_TARGET,
            bytes(""),
            100,
            0,
            0,
            uint64(block.timestamp + 1 days),
            actor,
            address(0),
            1 ether,
            priceLimit,
            address(router)
        );
        action.actor = address(0);

        _assertRejectedAction(action, actor, 1 ether, priceLimit, router);
        assertEq(kernel.executionHeight(worldId), 0);
        assertEq(kernel.nonces(worldId, kernel.eoaAccountId(actor)), 0);
    }

    function test_rejectsExpiredHighSBadVAndWrongLengthSignatures() public {
        uint160 priceLimit = TickMath.MIN_SQRT_PRICE + 1;
        SwapVMKernel.VMEnvelope memory action = _signedAction(
            ACTOR_KEY, STATE_TARGET, bytes(""), 100, 0, 0, 0, actor, actor, 1 ether, priceLimit, address(router)
        );
        _assertRejectedAction(action, actor, 1 ether, priceLimit, router);

        action = _signedAction(
            ACTOR_KEY,
            STATE_TARGET,
            bytes(""),
            100,
            0,
            0,
            uint64(block.timestamp + 1 days),
            actor,
            actor,
            1 ether,
            priceLimit,
            address(router)
        );
        (bytes32 r, bytes32 s, uint8 v) = _signatureParts(action.signature);
        action.signature = abi.encodePacked(r, bytes32(SECP256K1N - uint256(s)), v == 27 ? bytes1(0x1c) : bytes1(0x1b));
        _assertRejectedAction(action, actor, 1 ether, priceLimit, router);

        action.signature = abi.encodePacked(r, s, bytes1(0x01));
        _assertRejectedAction(action, actor, 1 ether, priceLimit, router);
        action.signature = abi.encodePacked(r, s);
        _assertRejectedAction(action, actor, 1 ether, priceLimit, router);
    }

    function test_signedNopAndMalformedDeployAreRejected() public {
        SwapVMKernel.VMEnvelope memory action = _signedAction(
            ACTOR_KEY,
            STATE_TARGET,
            bytes(""),
            100,
            0,
            0,
            uint64(block.timestamp + 1 days),
            actor,
            actor,
            1 ether,
            TickMath.MIN_SQRT_PRICE + 1,
            address(router)
        );
        action.op = SwapVMKernel.RootOp.NOP;
        _assertRejectedAction(action, actor, 1 ether, TickMath.MIN_SQRT_PRICE + 1, router);
        action.op = SwapVMKernel.RootOp.DEPLOY;
        _assertRejectedAction(action, actor, 1 ether, TickMath.MIN_SQRT_PRICE + 1, router);
    }

    function test_stage3MalformedPackagesAndEntrypointsRollback() public {
        bytes memory invalidMagic = _package(0, 0, bytes32(0), hex"00");
        invalidMagic[0] = bytes1(0x00);
        _assertMalformedDeploy(invalidMagic);

        bytes memory invalidEntry = _package(1, 3, bytes32(0), hex"61abcd00");
        _assertMalformedDeploy(invalidEntry);

        bytes memory trailing = bytes.concat(_package(0, 0, bytes32(0), hex"00"), hex"00");
        _assertMalformedDeploy(trailing);

        assertEq(kernel.executionHeight(worldId), 0);
        assertEq(kernel.nonces(worldId, kernel.eoaAccountId(actor)), 0);
        assertEq(kernel.creatorNonce(worldId, kernel.eoaAccountId(actor)), 0);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
    }

    function test_preflightMaximumExposureAndMinimumNetRollback() public {
        SwapVMKernel.VMEnvelope memory action = _signedAction(
            ACTOR_KEY,
            STATE_TARGET,
            bytes(""),
            1_000_000,
            0,
            0,
            uint64(block.timestamp + 1 days),
            actor,
            actor,
            1 ether,
            TickMath.MIN_SQRT_PRICE + 1,
            address(router)
        );
        _assertRejectedAction(action, actor, 1 ether, TickMath.MIN_SQRT_PRICE + 1, router);

        action = _signedAction(
            ACTOR_KEY,
            STATE_TARGET,
            bytes(""),
            100,
            type(uint128).max,
            0,
            uint64(block.timestamp + 1 days),
            actor,
            actor,
            1 ether,
            TickMath.MIN_SQRT_PRICE + 1,
            address(router)
        );
        _assertRejectedAction(action, actor, 1 ether, TickMath.MIN_SQRT_PRICE + 1, router);
        assertEq(kernel.executionHeight(worldId), 0);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
    }

    function test_stackMemoryAndHaltFailuresAreExceptional() public {
        bytes memory underflow = hex"5000";
        bytes32 target = _targetFor(underflow);
        kernel.install(worldId, target, underflow);
        vm.expectRevert(SwapVMMiniVM.StackUnderflow.selector);
        kernel.staticCall(worldId, target, bytes(""), 2);

        bytes memory overflow = new bytes(1026);
        for (uint256 i; i < 1025; ++i) {
            overflow[i] = bytes1(0x5f);
        }
        overflow[1025] = bytes1(0x00);
        target = _targetFor(overflow);
        kernel.install(worldId, target, overflow);
        vm.expectRevert(SwapVMMiniVM.StackOverflow.selector);
        kernel.staticCall(worldId, target, bytes(""), 1026);

        bytes memory memoryOob = hex"6001620100015200";
        target = _targetFor(memoryOob);
        kernel.install(worldId, target, memoryOob);
        vm.expectRevert(abi.encodeWithSelector(SwapVMMiniVM.MemoryOutOfBounds.selector, uint256(65_537), uint256(32)));
        kernel.staticCall(worldId, target, bytes(""), 8);

        bytes memory missingHalt = hex"5f";
        target = _targetFor(missingHalt);
        kernel.install(worldId, target, missingHalt);
        vm.expectRevert(SwapVMMiniVM.MissingHalt.selector);
        kernel.staticCall(worldId, target, bytes(""), 1);
    }

    function test_contextOpcodesAndMeterAreDeterministic() public {
        bytes memory code =
            hex"b05f52b1602052b2604052b3606052b4608052b560a052b660c052b760e052b861010052b9610120526101405ff3";
        bytes32 target = _targetFor(code);
        kernel.install(worldId, target, code);

        vm.prank(actor);
        (bytes memory output, uint32 used) = kernel.staticCall(worldId, target, bytes(""), 46);
        assertEq(used, 46);
        assertEq(_word(output, 0), kernel.eoaAccountId(actor));
        assertEq(_word(output, 32), worldId);
        assertEq(uint256(_word(output, 64)), 0);
        assertEq(uint256(_word(output, 96)), 0);
        assertEq(uint256(_word(output, 128)), 0);
        assertEq(uint256(_word(output, 160)), 0);
        assertEq(uint256(_word(output, 192)), 0);
        assertEq(uint256(_word(output, 224)), BYTE_GAS_PRICE);
        assertEq(uint256(_word(output, 256)), 32);
        assertEq(uint256(_word(output, 288)), 9);
    }

    function test_accountIdsAreCanonicallyTaggedAndDisjoint() public view {
        bytes32 eoa = kernel.eoaAccountId(actor);
        bytes32 contractId = kernel.contractAccountId(worldId, eoa, 0, keccak256(STATE_PROGRAM));
        assertEq(uint8(eoa[0]), 0x00);
        assertEq(address(uint160(uint256(eoa))), actor);
        assertEq(uint8(contractId[0]), 0x01);
        assertEq(uint8(kernel.KERNEL_EMITTER_ID()[0]), 0xff);
        assertTrue(eoa != contractId && contractId != kernel.KERNEL_EMITTER_ID() && eoa != bytes32(0));
    }

    function testFuzz_binaryInstructionDifferential(uint256 a, uint256 b, uint8 selector) public {
        bytes memory opcodes = hex"01020304060a1011141617181a1b1c";
        uint8 opcode = uint8(opcodes[selector % uint8(opcodes.length)]);
        bytes memory code =
            abi.encodePacked(bytes1(0x7f), bytes32(a), bytes1(0x7f), bytes32(b), bytes1(opcode), hex"60005260206000f3");
        bytes32 target = _targetFor(code);
        kernel.install(worldId, target, code);
        (, uint8 immediate) = _expectedOpcodeInfo(0x7f);
        assertEq(immediate, 32);

        (bytes memory output, uint32 used) = kernel.staticCall(worldId, target, bytes(""), 75);
        assertEq(abi.decode(output, (uint256)), _referenceBinary(opcode, a, b));
        assertEq(used, 75);
    }

    function test_addmodMulmodUnaryStackMemoryHashAndReturnDataFamilies() public {
        bytes memory addmodCode = hex"600d60056007085f5260205ff3";
        bytes32 target = _targetFor(addmodCode);
        kernel.install(worldId, target, addmodCode);
        (bytes memory output,) = kernel.staticCall(worldId, target, bytes(""), 13);
        assertEq(abi.decode(output, (uint256)), addmod(13, 5, 7));

        bytes memory mulmodCode = hex"600d60056007095f5260205ff3";
        target = _targetFor(mulmodCode);
        kernel.install(worldId, target, mulmodCode);
        (output,) = kernel.staticCall(worldId, target, bytes(""), 13);
        assertEq(abi.decode(output, (uint256)), mulmod(13, 5, 7));

        // DUP2 + SWAP1, then ISZERO twice, leaves the deterministic word 4.
        bytes memory stackCode = hex"600160028190010119195f5260205ff3";
        target = _targetFor(stackCode);
        kernel.install(worldId, target, stackCode);
        (output,) = kernel.staticCall(worldId, target, bytes(""), 16);
        assertEq(abi.decode(output, (uint256)), 4);

        bytes memory memoryCode = hex"60ab601f53595f5260205ff3";
        target = _targetFor(memoryCode);
        kernel.install(worldId, target, memoryCode);
        (output,) = kernel.staticCall(worldId, target, bytes(""), 13);
        assertEq(abi.decode(output, (uint256)), 32);

        bytes32 value = keccak256("SwapVM.Stage2.KECCAK.input");
        bytes memory hashCode = abi.encodePacked(bytes1(0x7f), value, hex"5f5260205f205f5260205ff3");
        target = _targetFor(hashCode);
        kernel.install(worldId, target, hashCode);
        (output,) = kernel.staticCall(worldId, target, bytes(""), 45);
        assertEq(abi.decode(output, (bytes32)), keccak256(abi.encode(value)));

        bytes memory returnDataCode = hex"3d5f526000600060003e60205ff3";
        target = _targetFor(returnDataCode);
        kernel.install(worldId, target, returnDataCode);
        (output,) = kernel.staticCall(worldId, target, bytes(""), 14);
        assertEq(abi.decode(output, (uint256)), 0);
    }

    function test_ecrecoverReturnsTaggedEoaAndRejectsHighS() public {
        bytes32 digest = keccak256("SwapVM.Stage2.ECRECOVER");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ACTOR_KEY, digest);
        bytes memory code = abi.encodePacked(
            bytes1(0x7f), digest, bytes1(0x60), bytes1(v), bytes1(0x7f), r, bytes1(0x7f), s, hex"215f5260205ff3"
        );
        bytes32 target = _targetFor(code);
        kernel.install(worldId, target, code);
        (bytes memory output, uint32 used) = kernel.staticCall(worldId, target, bytes(""), 108);
        assertEq(abi.decode(output, (bytes32)), kernel.eoaAccountId(actor));
        assertEq(used, 108);

        bytes32 highS = bytes32(SECP256K1N - uint256(s));
        code = abi.encodePacked(
            bytes1(0x7f), digest, bytes1(0x60), bytes1(v), bytes1(0x7f), r, bytes1(0x7f), highS, hex"215f5260205ff3"
        );
        target = _targetFor(code);
        kernel.install(worldId, target, code);
        (output,) = kernel.staticCall(worldId, target, bytes(""), 108);
        assertEq(abi.decode(output, (bytes32)), bytes32(0));
    }

    function testFuzz_calldataLoadAndCopyAreZeroPadded(bytes32 value, uint8 shortLength) public {
        shortLength = uint8(bound(shortLength, 0, 32));
        bytes memory input = new bytes(shortLength);
        for (uint256 i; i < shortLength; ++i) {
            input[i] = value[i];
        }
        // PUSH0; CALLDATALOAD; PUSH0; MSTORE; PUSH1 32; PUSH0; RETURN
        bytes memory code = hex"5f355f5260205ff3";
        bytes32 target = _targetFor(abi.encodePacked(code, shortLength));
        kernel.install(worldId, target, code);
        (bytes memory output, uint32 used) = kernel.staticCall(worldId, target, input, 8);

        bytes32 expected;
        for (uint256 i; i < shortLength; ++i) {
            expected |= bytes32(uint256(uint8(input[i])) << (248 - (i * 8)));
        }
        assertEq(abi.decode(output, (bytes32)), expected);
        assertEq(used, 8);
    }

    function _executeStateProgram() internal {
        SwapVMKernel.VMEnvelope memory action = _signedAction(
            ACTOR_KEY,
            STATE_TARGET,
            bytes(""),
            100,
            0,
            0,
            uint64(block.timestamp + 1 days),
            actor,
            actor,
            1 ether,
            TickMath.MIN_SQRT_PRICE + 1,
            address(router)
        );
        vm.prank(actor);
        router.swap{value: 1 ether}(key, _buyParams(1 ether, TickMath.MIN_SQRT_PRICE + 1), actor, abi.encode(action));
    }

    function _executeDeploy(
        bytes memory packageBytes,
        bytes32 codeHash,
        bytes memory constructorInput,
        uint32 limit,
        uint64 nonce
    ) internal {
        bytes memory payload = abi.encodePacked(bytes4(uint32(packageBytes.length)), packageBytes, constructorInput);
        SwapVMKernel.VMEnvelope memory action = _signedActionForOp(
            SwapVMKernel.RootOp.DEPLOY,
            ACTOR_KEY,
            codeHash,
            payload,
            limit,
            0,
            nonce,
            uint64(block.timestamp + 1 days),
            actor,
            actor,
            1 ether,
            TickMath.MIN_SQRT_PRICE + 1,
            address(router)
        );
        vm.prank(actor);
        router.swap{value: 1 ether}(key, _buyParams(1 ether, TickMath.MIN_SQRT_PRICE + 1), actor, abi.encode(action));
    }

    function _assertMalformedDeploy(bytes memory packageBytes) internal {
        bytes memory payload = abi.encodePacked(bytes4(uint32(packageBytes.length)), packageBytes);
        SwapVMKernel.VMEnvelope memory action = _signedActionForOp(
            SwapVMKernel.RootOp.DEPLOY,
            ACTOR_KEY,
            keccak256(packageBytes),
            payload,
            1,
            0,
            0,
            uint64(block.timestamp + 1 days),
            actor,
            actor,
            1 ether,
            TickMath.MIN_SQRT_PRICE + 1,
            address(router)
        );
        _assertRejectedAction(action, actor, 1 ether, TickMath.MIN_SQRT_PRICE + 1, router);
    }

    function _assertRejectedAction(
        SwapVMKernel.VMEnvelope memory action,
        address recipient,
        uint256 ethIn,
        uint160 priceLimit,
        SwapVMStage2Router selectedRouter
    ) internal {
        uint256 supplyBefore = token.totalSupply();
        uint64 heightBefore = kernel.executionHeight(worldId);
        uint64 nonceBefore = kernel.nonces(worldId, kernel.eoaAccountId(actor));
        bytes32 storageBefore = kernel.programStorageAt(worldId, STATE_TARGET, bytes32(uint256(1)));
        vm.recordLogs();
        vm.prank(actor);
        vm.expectRevert();
        selectedRouter.swap{value: ethIn}(key, _buyParams(ethIn, priceLimit), recipient, abi.encode(action));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(token.totalSupply(), supplyBefore);
        assertEq(kernel.executionHeight(worldId), heightBefore);
        assertEq(kernel.nonces(worldId, kernel.eoaAccountId(actor)), nonceBefore);
        assertEq(kernel.programStorageAt(worldId, STATE_TARGET, bytes32(uint256(1))), storageBefore);
        assertEq(_countEvents(logs), 0);
    }

    function _signatureParts(bytes memory signature) internal pure returns (bytes32 r, bytes32 s, uint8 v) {
        assembly ("memory-safe") {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }
    }

    function _signedAction(
        uint256 privateKey,
        bytes32 target,
        bytes memory payload,
        uint32 limit,
        uint128 minNet,
        uint64 nonce,
        uint64 deadline,
        address recipient,
        address executor,
        uint128 ethIn,
        uint160 priceLimit,
        address routerAddress
    ) internal view returns (SwapVMKernel.VMEnvelope memory action) {
        return _signedActionForOp(
            SwapVMKernel.RootOp.CALL,
            privateKey,
            target,
            payload,
            limit,
            minNet,
            nonce,
            deadline,
            recipient,
            executor,
            ethIn,
            priceLimit,
            routerAddress
        );
    }

    function _signedActionForOp(
        SwapVMKernel.RootOp op,
        uint256 privateKey,
        bytes32 target,
        bytes memory payload,
        uint32 limit,
        uint128 minNet,
        uint64 nonce,
        uint64 deadline,
        address recipient,
        address executor,
        uint128 ethIn,
        uint160 priceLimit,
        address routerAddress
    ) internal view returns (SwapVMKernel.VMEnvelope memory action) {
        action = SwapVMKernel.VMEnvelope({
            op: op,
            worldId: worldId,
            actor: vm.addr(privateKey),
            targetOrCodeHash: target,
            payload: payload,
            byteGasLimit: limit,
            minNetTokenOut: minNet,
            nonce: nonce,
            deadline: deadline,
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
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
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

    function _buyParams(uint256 ethIn, uint160 priceLimit) internal pure returns (SwapParams memory) {
        return SwapParams({zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: priceLimit});
    }

    function _assertStage2Receipt(Vm.Log[] memory logs, bytes32 actorId, bytes32 target, uint32 used, uint256 burned)
        internal
        view
    {
        bytes memory payload;
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(kernel) && logs[i].topics[0] == EVENTS_TOPIC) {
                payload = abi.decode(logs[i].data, (bytes));
                ++count;
            }
        }
        assertEq(count, 1);
        assertEq(_word(payload, 77), actorId);
        assertEq(_word(payload, 109), target);
        assertEq(uint256(_word(payload, 141)), used);
        assertEq(uint256(_word(payload, 173)), burned);
    }

    function _assertDeployReceipt(
        Vm.Log[] memory logs,
        bytes32 contractId,
        bytes32 creator,
        bytes32 codeHash,
        uint32 used
    ) internal view {
        bytes memory payload;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(kernel) && logs[i].topics[0] == EVENTS_TOPIC) {
                payload = abi.decode(logs[i].data, (bytes));
            }
        }
        assertEq(payload.length, 438);
        assertEq(uint8(payload[0]), 1);
        assertEq(uint8(payload[2]), 0);
        assertEq(uint8(payload[3]), 2);
        assertEq(_word(payload, 41), kernel.MINI_CONTRACT_DEPLOYED_SELECTOR());
        assertEq(_word(payload, 77), contractId);
        assertEq(_word(payload, 109), creator);
        assertEq(_word(payload, 141), codeHash);
        assertEq(_word(payload, 210), kernel.WORLD_EXECUTION_SELECTOR());
        assertEq(_word(payload, 246), creator);
        assertEq(_word(payload, 278), contractId);
        assertEq(uint256(_word(payload, 310)), used);
    }

    function _assertInternalDeployReceipt(
        Vm.Log[] memory logs,
        bytes32 contractId,
        bytes32 creator,
        bytes32 codeHash,
        bytes32 actorId,
        uint32 used
    ) internal view {
        bytes memory payload;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(kernel) && logs[i].topics[0] == EVENTS_TOPIC) {
                payload = abi.decode(logs[i].data, (bytes));
            }
        }
        assertEq(payload.length, 438);
        assertEq(uint8(payload[3]), 2);
        assertEq(_word(payload, 41), kernel.MINI_CONTRACT_DEPLOYED_SELECTOR());
        assertEq(_word(payload, 77), contractId);
        assertEq(_word(payload, 109), creator);
        assertEq(_word(payload, 141), codeHash);
        assertEq(_word(payload, 246), actorId);
        assertEq(_word(payload, 278), creator);
        assertEq(uint256(_word(payload, 310)), used);
    }

    function _assertSettled() internal view {
        IPoolManager poolManager = IPoolManager(address(manager));
        assertEq(poolManager.getNonzeroDeltaCount(), 0);
        assertEq(poolManager.currencyDelta(address(router), key.currency0), 0);
        assertEq(poolManager.currencyDelta(address(router), key.currency1), 0);
        assertEq(poolManager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(poolManager.currencyDelta(address(hook), key.currency1), 0);
    }

    function _countEvents(Vm.Log[] memory logs) internal view returns (uint256 count) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(kernel) && logs[i].topics[0] == EVENTS_TOPIC) ++count;
        }
    }

    function _receiptActor(Vm.Log[] memory logs) internal view returns (bytes32 actorId) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(kernel) && logs[i].topics[0] == EVENTS_TOPIC) {
                return _word(abi.decode(logs[i].data, (bytes)), 77);
            }
        }
        revert("missing Events");
    }

    function _targetFor(bytes memory seed) internal pure returns (bytes32) {
        return bytes32((uint256(1) << 248) | (uint256(keccak256(seed)) >> 8));
    }

    function _word(bytes memory data, uint256 offset) internal pure returns (bytes32 value) {
        assembly ("memory-safe") {
            value := mload(add(add(data, 0x20), offset))
        }
    }

    function _expectedOpcodeInfo(uint8 opcode) internal pure returns (bool, uint8) {
        if (opcode >= 0x60 && opcode <= 0x7f) return (true, opcode - 0x5f);
        return (false, 0);
    }

    function _referenceBinary(uint8 opcode, uint256 a, uint256 b) internal pure returns (uint256 result) {
        assembly ("memory-safe") {
            switch opcode
            case 0x01 { result := add(a, b) }
            case 0x02 { result := mul(a, b) }
            case 0x03 { result := sub(a, b) }
            case 0x04 { result := div(a, b) }
            case 0x06 { result := mod(a, b) }
            case 0x0a { result := exp(a, b) }
            case 0x10 { result := lt(a, b) }
            case 0x11 { result := gt(a, b) }
            case 0x14 { result := eq(a, b) }
            case 0x16 { result := and(a, b) }
            case 0x17 { result := or(a, b) }
            case 0x18 { result := xor(a, b) }
            case 0x1a { result := byte(b, a) }
            case 0x1b { result := shl(b, a) }
            case 0x1c { result := shr(b, a) }
        }
    }

    receive() external payable {}
}
