// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

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
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {SwapVMGasToken} from "../src/SwapVMGasToken.sol";
import {SwapVMHook} from "../src/SwapVMHook.sol";
import {SwapVMKernel} from "../src/SwapVMKernel.sol";
import {SwapVMReferenceRegistry} from "../src/SwapVMReferenceRegistry.sol";

/// @dev Local-only canonical settlement route used by the Stage 6 release-candidate test.
contract Stage6ERouter is IUnlockCallback {
    using CurrencySettler for Currency;
    using CurrencyLibrary for Currency;
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

    function nonzeroDeltaCount() external view returns (uint256) {
        return manager.getNonzeroDeltaCount();
    }

    receive() external payable {}
}

/// @dev Stores a signed failing action so the orchestrator can submit a top-level status-0 transaction.
contract Stage6EFailureExecutor {
    address public immutable owner;
    Stage6ERouter public immutable router;
    PoolKey private _key;
    bytes private _hookData;

    error OnlyOwner();

    constructor(address initialOwner, Stage6ERouter targetRouter, PoolKey memory key) payable {
        owner = initialOwner;
        router = targetRouter;
        _key = key;
    }

    function configure(bytes calldata hookData) external {
        if (msg.sender != owner) revert OnlyOwner();
        _hookData = hookData;
    }

    function execute() external {
        if (msg.sender != owner) revert OnlyOwner();
        router.swap{value: 1 ether}(
            _key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            owner,
            _hookData
        );
    }

    receive() external payable {}
}

/// @notice Real-v4, local-Anvil-only Stage 6 release-candidate producer.
contract Stage6EE2EScript is Script {
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;
    using stdJson for string;

    uint256 private constant INITIAL_SUPPLY = 1e36;
    uint128 private constant BYTE_GAS_PRICE = 1e12;
    uint24 private constant POOL_FEE = 3000;
    int24 private constant TICK_SPACING = 60;
    uint160 private constant SQRT_PRICE_1_1 = 1 << 96;
    uint32 private constant ACTION_LIMIT = 5_000;
    uint128 private constant MIN_NET = 1;
    address private constant FOUNDRY_CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint256 private actorKey;
    address private actor;
    PoolManager private manager;
    SwapVMGasToken private token;
    SwapVMKernel private kernel;
    SwapVMHook private hook;
    Stage6ERouter private router;
    Stage6EFailureExecutor private failureExecutor;
    PoolKey private key;
    bytes32 private worldId;
    bytes32 private src20;
    bytes32 private miniToken;

    function setup() external {
        actorKey = vm.envUint("STAGE6E_PRIVATE_KEY");
        actor = vm.addr(actorKey);

        vm.startBroadcast(actorKey);
        manager = new PoolManager(actor);
        token = new SwapVMGasToken(INITIAL_SUPPLY, actor);
        PoolModifyLiquidityTest liquidityRouter = new PoolModifyLiquidityTest(manager);
        router = new Stage6ERouter(manager);
        SwapVMReferenceRegistry registry = new SwapVMReferenceRegistry();
        vm.stopBroadcast();

        uint64 nextNonce = vm.getNonce(actor);
        address predictedKernel = vm.computeCreateAddress(actor, nextNonce);
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
            HookMiner.find(FOUNDRY_CREATE2_DEPLOYER, flags, type(SwapVMHook).creationCode, hookArgs);

        vm.startBroadcast(actorKey);
        kernel = new SwapVMKernel(expectedHook, BYTE_GAS_PRICE);
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
        failureExecutor = new Stage6EFailureExecutor{value: 10 ether}(actor, router, key);
        manager.initialize(key, SQRT_PRICE_1_1);
        token.approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity{value: 1e25}(
            key,
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e24, salt: bytes32(0)}),
            bytes("")
        );
        vm.stopBroadcast();

        console2.log("STAGE6E_MANAGER", address(manager));
        console2.log("STAGE6E_TOKEN", address(token));
        console2.log("STAGE6E_KERNEL", address(kernel));
        console2.log("STAGE6E_HOOK", address(hook));
        console2.log("STAGE6E_ROUTER", address(router));
        console2.log("STAGE6E_REGISTRY", address(registry));
        console2.log("STAGE6E_FAILURE_EXECUTOR", address(failureExecutor));
        console2.logBytes32(worldId);
    }

    function deployReferenceBuy() external {
        _load();
        bytes memory packageBytes = _fixturePackage("reference/SRC20-v1.json");
        bytes32 actorId = kernel.eoaAccountId(actor);
        bytes memory constructorInput =
            abi.encode(bytes32("Stage6E Token"), bytes32("S6E"), uint256(18), uint256(1_000), actorId);
        src20 = _nextContract(packageBytes);
        BalanceDelta delta = _executeBuy(
            SwapVMKernel.RootOp.DEPLOY,
            keccak256(packageBytes),
            _deployPayload(packageBytes, constructorInput),
            ACTION_LIMIT,
            actor
        );
        console2.log("STAGE6E_REFERENCE", vm.toString(src20));
        _printLast("STAGE6E_DEPLOY", delta);
    }

    function quoteReferenceCall() external {
        _load();
        BalanceDelta delta = _referenceCall();
        _printLast("STAGE6E_QUOTE", delta);
    }

    function referenceCallBuy() external {
        _load();
        BalanceDelta delta = _referenceCall();
        _printLast("STAGE6E_CALL", delta);
    }

    function deployCustomBuy() external {
        _load();
        bytes memory packageBytes = _fixturePackage("tooling/tinysol/fixtures/compiler/MiniToken.json");
        bytes32 actorId = kernel.eoaAccountId(actor);
        miniToken = _nextContract(packageBytes);
        BalanceDelta delta = _executeBuy(
            SwapVMKernel.RootOp.DEPLOY,
            keccak256(packageBytes),
            _deployPayload(packageBytes, abi.encode(uint256(1_000), actorId)),
            ACTION_LIMIT,
            actor
        );
        console2.log("STAGE6E_CUSTOM", vm.toString(miniToken));
        _printLast("STAGE6E_CUSTOM_DEPLOY", delta);
    }

    function customCallBuy() external {
        _load();
        bytes32 recipient = kernel.eoaAccountId(address(0xcafe));
        bytes memory payload =
            abi.encodePacked(bytes4(keccak256("transfer(bytes32,uint256)")), abi.encode(recipient, uint256(7)));
        BalanceDelta delta = _executeBuy(SwapVMKernel.RootOp.CALL, miniToken, payload, ACTION_LIMIT, actor);
        _printLast("STAGE6E_CUSTOM_CALL", delta);
    }

    function sell() external {
        _load();
        vm.startBroadcast(actorKey);
        token.approve(address(router), type(uint256).max);
        uint256 supplyBefore = token.totalSupply();
        uint64 heightBefore = kernel.executionHeight(worldId);
        router.swap(
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: -int256(1e15), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            actor,
            bytes("")
        );
        vm.stopBroadcast();
        console2.log("STAGE6E_SELL_HEIGHT_BEFORE", heightBefore);
        console2.log("STAGE6E_SELL_HEIGHT_AFTER", kernel.executionHeight(worldId));
        console2.log("STAGE6E_SELL_BURN", supplyBefore - token.totalSupply());
    }

    function configureRevert() external {
        _load();
        bytes32 recipient = kernel.eoaAccountId(address(0xdead));
        bytes memory payload =
            abi.encodePacked(bytes4(keccak256("transfer(bytes32,uint256)")), abi.encode(recipient, type(uint128).max));
        _configureFailure(payload, ACTION_LIMIT);
    }

    function configureOutOfByteGas() external {
        _load();
        bytes32 recipient = kernel.eoaAccountId(address(0xdead));
        bytes memory payload =
            abi.encodePacked(bytes4(keccak256("transfer(bytes32,uint256)")), abi.encode(recipient, uint256(1)));
        _configureFailure(payload, 10);
    }

    function branchB() external {
        _load();
        vm.startBroadcast(actorKey);
        for (uint256 i; i < 4; ++i) {
            router.swap{value: 1 ether}(
                key,
                SwapParams({
                    zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                actor,
                bytes("")
            );
        }
        vm.stopBroadcast();
    }

    function _referenceCall() private returns (BalanceDelta delta) {
        bytes32 recipient = kernel.eoaAccountId(address(0xbeef));
        bytes memory payload =
            abi.encodePacked(bytes4(keccak256("transfer(bytes32,uint256)")), abi.encode(recipient, uint256(125)));
        delta = _executeBuy(SwapVMKernel.RootOp.CALL, src20, payload, ACTION_LIMIT, actor);
    }

    function _executeBuy(SwapVMKernel.RootOp op, bytes32 target, bytes memory payload, uint32 limit, address executor)
        private
        returns (BalanceDelta delta)
    {
        SwapVMKernel.VMEnvelope memory action = _signed(op, target, payload, limit, executor);
        vm.startBroadcast(actorKey);
        delta = router.swap{value: 1 ether}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            actor,
            abi.encode(action)
        );
        vm.stopBroadcast();
    }

    function _configureFailure(bytes memory payload, uint32 limit) private {
        SwapVMKernel.VMEnvelope memory action =
            _signed(SwapVMKernel.RootOp.CALL, src20, payload, limit, address(failureExecutor));
        vm.startBroadcast(actorKey);
        failureExecutor.configure(abi.encode(action));
        vm.stopBroadcast();
    }

    function _signed(SwapVMKernel.RootOp op, bytes32 target, bytes memory payload, uint32 limit, address executor)
        private
        view
        returns (SwapVMKernel.VMEnvelope memory action)
    {
        bytes32 actorId = kernel.eoaAccountId(actor);
        action = SwapVMKernel.VMEnvelope({
            op: op,
            worldId: worldId,
            actor: actor,
            targetOrCodeHash: target,
            payload: payload,
            byteGasLimit: limit,
            minNetTokenOut: MIN_NET,
            nonce: kernel.nonces(worldId, actorId),
            deadline: uint64(block.timestamp + 1 days),
            recipient: actor,
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
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(actorKey, digest);
        action.signature = abi.encodePacked(r, s, v);
    }

    function _printLast(string memory prefix, BalanceDelta delta) private view {
        uint32 used = kernel.executedBytes(worldId);
        int128 netDelta = delta.amount1();
        require(netDelta > 0, "non-positive buy output");
        uint256 burn = uint256(used) * BYTE_GAS_PRICE;
        uint256 net = uint128(netDelta);
        (, int24 tick,,) = IPoolManager(address(manager)).getSlot0(PoolId.wrap(worldId));
        console2.log(string.concat(prefix, "_EXECUTED"), used);
        console2.log(string.concat(prefix, "_BURN"), burn);
        console2.log(string.concat(prefix, "_GROSS"), net + burn);
        console2.log(string.concat(prefix, "_NET"), net);
        console2.log(string.concat(prefix, "_HEIGHT"), kernel.executionHeight(worldId));
        console2.log(string.concat(prefix, "_TICK"), int256(tick));
        console2.log(
            string.concat(prefix, "_LIQUIDITY"), IPoolManager(address(manager)).getLiquidity(PoolId.wrap(worldId))
        );
    }

    function _nextContract(bytes memory packageBytes) private view returns (bytes32) {
        bytes32 actorId = kernel.eoaAccountId(actor);
        return
            kernel.contractAccountId(worldId, actorId, kernel.creatorNonce(worldId, actorId), keccak256(packageBytes));
    }

    function _deployPayload(bytes memory packageBytes, bytes memory constructorInput)
        private
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(bytes4(uint32(packageBytes.length)), packageBytes, constructorInput);
    }

    function _fixturePackage(string memory path) private view returns (bytes memory) {
        return vm.readFile(path).readBytes(".package");
    }

    function _load() private {
        actorKey = vm.envUint("STAGE6E_PRIVATE_KEY");
        actor = vm.addr(actorKey);
        manager = PoolManager(vm.envAddress("STAGE6E_MANAGER"));
        token = SwapVMGasToken(vm.envAddress("STAGE6E_TOKEN"));
        kernel = SwapVMKernel(vm.envAddress("STAGE6E_KERNEL"));
        hook = SwapVMHook(payable(vm.envAddress("STAGE6E_HOOK")));
        router = Stage6ERouter(payable(vm.envAddress("STAGE6E_ROUTER")));
        failureExecutor = Stage6EFailureExecutor(payable(vm.envAddress("STAGE6E_FAILURE_EXECUTOR")));
        key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        worldId = PoolId.unwrap(key.toId());
        src20 = vm.envBytes32("STAGE6E_REFERENCE");
        miniToken = vm.envOr("STAGE6E_CUSTOM", bytes32(0));
    }
}
