// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {ISwaputerWorldFactory} from "./interfaces/ISwaputerWorldFactory.sol";
import {SwaputerToken} from "./SwaputerToken.sol";
import {SwaputerKernel} from "./SwaputerKernel.sol";

interface ISwaputerHookResult {
    function consumeVMResult() external returns (bytes32 word, uint32 length);
}

/// @notice Immutable canonical settlement Router for one Factory-bound PoolManager.
contract SwaputerAppRouter is IUnlockCallback {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using TransientStateLibrary for IPoolManager;

    bytes32 private constant ACTIVE_CALLBACK_SLOT = keccak256("SwaputerAppRouter.activeCallback.v1");
    IPoolManager public immutable poolManager;
    ISwaputerWorldFactory public immutable factory;

    enum RouteKind {
        BuyNOPExactInput,
        BuyVMExactInput,
        SellExactInput
    }

    struct UnlockData {
        RouteKind kind;
        bytes32 worldId;
        address payer;
        address recipient;
        uint128 exactAmount;
        uint128 minimumAmountOut;
        uint160 sqrtPriceLimitX96;
        bytes hookData;
    }

    error InvalidPoolManager();
    error InvalidFactory();
    error OnlyPoolManager(address caller);
    error CallbackNotActive();
    error CallbackDataMismatch();
    error ReentrantUnlock();
    error WorldNotSealed(bytes32 worldId);
    error WorldPoolKeyMismatch(bytes32 worldId);
    error FactoryRouterMismatch(address expected, address actual);
    error InvalidRecipient(address recipient);
    error InvalidExactInput(uint256 amount);
    error EnvelopeWorldMismatch(bytes32 expected, bytes32 supplied);
    error SignedNOPForbidden();
    error InvalidVMOperation(SwaputerKernel.RootOp op);
    error UnauthorizedExecutor(address expected, address actual);
    error ExactOutputBuyUnsupported();
    error SellInstructionsForbidden();
    error InvalidRouteData();
    error UnexpectedCurrencyDelta(int256 delta0, int256 delta1);
    error MinimumOutputNotMet(uint256 actual, uint256 minimum);
    error SettlementNotCleared(int256 delta0, int256 delta1);
    error TokenTransferFailed();
    error NativeTransferFailed(address recipient, uint256 amount);
    error RefundAccountingMismatch(uint256 spent, uint256 budget);

    constructor(IPoolManager manager, ISwaputerWorldFactory worldFactory) {
        if (address(manager) == address(0)) revert InvalidPoolManager();
        if (address(worldFactory) == address(0)) revert InvalidFactory();
        poolManager = manager;
        factory = worldFactory;
    }

    function buyNOPExactInput(bytes32 worldId, uint128 minTokenOut, uint160 sqrtPriceLimitX96, address recipient)
        external
        payable
        returns (BalanceDelta delta)
    {
        uint128 exactAmount = _validateNativeInputAndRecipient(recipient);
        UnlockData memory data = UnlockData({
            kind: RouteKind.BuyNOPExactInput,
            worldId: worldId,
            payer: msg.sender,
            recipient: recipient,
            exactAmount: exactAmount,
            minimumAmountOut: minTokenOut,
            sqrtPriceLimitX96: sqrtPriceLimitX96,
            hookData: bytes("")
        });
        uint256 spent;
        (delta, spent,,) = _unlock(data);
        _refundNative(msg.sender, uint256(exactAmount), spent);
    }

    function buyVMExactInput(bytes32 worldId, uint160 sqrtPriceLimitX96, SwaputerKernel.VMEnvelope calldata envelope)
        external
        payable
        returns (BalanceDelta delta)
    {
        (delta,,) = _buyVMExactInput(worldId, sqrtPriceLimitX96, envelope);
    }

    function buyVMExactInputWithResult(
        bytes32 worldId,
        uint160 sqrtPriceLimitX96,
        SwaputerKernel.VMEnvelope calldata envelope
    ) external payable returns (BalanceDelta delta, bytes32 vmResult, uint32 vmResultLength) {
        return _buyVMExactInput(worldId, sqrtPriceLimitX96, envelope);
    }

    function _buyVMExactInput(bytes32 worldId, uint160 sqrtPriceLimitX96, SwaputerKernel.VMEnvelope calldata envelope)
        private
        returns (BalanceDelta delta, bytes32 vmResult, uint32 vmResultLength)
    {
        if (envelope.worldId != worldId) revert EnvelopeWorldMismatch(worldId, envelope.worldId);
        if (envelope.op == SwaputerKernel.RootOp.NOP) revert SignedNOPForbidden();
        if (envelope.op != SwaputerKernel.RootOp.CALL && envelope.op != SwaputerKernel.RootOp.DEPLOY) {
            revert InvalidVMOperation(envelope.op);
        }
        if (envelope.actor == address(0)) revert SwaputerKernel.InvalidActor();
        if (envelope.recipient == address(0)) revert InvalidRecipient(envelope.recipient);
        if (envelope.authorizedExecutor != address(0) && envelope.authorizedExecutor != msg.sender) {
            revert UnauthorizedExecutor(envelope.authorizedExecutor, msg.sender);
        }
        uint128 exactAmount = _validateNativeInputAndRecipient(envelope.recipient);
        UnlockData memory data = UnlockData({
            kind: RouteKind.BuyVMExactInput,
            worldId: worldId,
            payer: msg.sender,
            recipient: envelope.recipient,
            exactAmount: exactAmount,
            minimumAmountOut: envelope.minNetTokenOut,
            sqrtPriceLimitX96: sqrtPriceLimitX96,
            hookData: abi.encode(envelope)
        });
        uint256 spent;
        (delta, spent, vmResult, vmResultLength) = _unlock(data);
        _refundNative(msg.sender, uint256(exactAmount), spent);
    }

    function sellExactInput(
        bytes32 worldId,
        uint128 exactTokenAmountIn,
        uint128 minEthAmountOut,
        uint160 sqrtPriceLimitX96,
        address recipient
    ) external returns (BalanceDelta delta) {
        if (exactTokenAmountIn == 0) revert InvalidExactInput(0);
        if (recipient == address(0)) revert InvalidRecipient(recipient);
        UnlockData memory data = UnlockData({
            kind: RouteKind.SellExactInput,
            worldId: worldId,
            payer: msg.sender,
            recipient: recipient,
            exactAmount: exactTokenAmountIn,
            minimumAmountOut: minEthAmountOut,
            sqrtPriceLimitX96: sqrtPriceLimitX96,
            hookData: bytes("")
        });
        (delta,,,) = _unlock(data);
    }

    function unlockCallback(bytes calldata callbackData) external returns (bytes memory result) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager(msg.sender);
        bytes32 active = _activeCallback();
        if (active == bytes32(0)) revert CallbackNotActive();
        if (active != _callbackCommitment(callbackData)) revert CallbackDataMismatch();

        UnlockData memory data = abi.decode(callbackData, (UnlockData));
        (PoolKey memory key, bool isSealed) = factory.getPoolKey(data.worldId);
        if (!isSealed) revert WorldNotSealed(data.worldId);
        if (PoolId.unwrap(key.toId()) != data.worldId) revert WorldPoolKeyMismatch(data.worldId);

        bool isBuy = data.kind == RouteKind.BuyNOPExactInput || data.kind == RouteKind.BuyVMExactInput;
        if (data.exactAmount == 0 || data.recipient == address(0)) revert InvalidRouteData();
        if (isBuy) {
            if (data.kind == RouteKind.BuyNOPExactInput && data.hookData.length != 0) revert InvalidRouteData();
            if (data.kind == RouteKind.BuyVMExactInput && data.hookData.length == 0) revert InvalidRouteData();
        } else if (data.kind == RouteKind.SellExactInput) {
            if (data.hookData.length != 0) revert InvalidRouteData();
        } else {
            revert InvalidRouteData();
        }

        SwapParams memory params = SwapParams({
            zeroForOne: isBuy,
            amountSpecified: -int256(uint256(data.exactAmount)),
            sqrtPriceLimitX96: data.sqrtPriceLimitX96
        });
        BalanceDelta delta = poolManager.swap(key, params, data.hookData);
        bytes32 vmResult;
        uint32 vmResultLength;
        if (data.kind == RouteKind.BuyVMExactInput) {
            (vmResult, vmResultLength) = ISwaputerHookResult(address(key.hooks)).consumeVMResult();
        }
        int256 delta0 = poolManager.currencyDelta(address(this), key.currency0);
        int256 delta1 = poolManager.currencyDelta(address(this), key.currency1);
        uint256 spent;

        if (isBuy) {
            if (delta0 >= 0 || delta1 <= 0) revert UnexpectedCurrencyDelta(delta0, delta1);
            spent = uint256(-delta0);
            uint256 tokenOut = uint256(delta1);
            if (spent > data.exactAmount) revert RefundAccountingMismatch(spent, data.exactAmount);
            if (tokenOut < data.minimumAmountOut) revert MinimumOutputNotMet(tokenOut, data.minimumAmountOut);
            poolManager.settle{value: spent}();
            poolManager.take(key.currency1, data.recipient, tokenOut);
        } else {
            if (delta0 <= 0 || delta1 >= 0) revert UnexpectedCurrencyDelta(delta0, delta1);
            uint256 ethOut = uint256(delta0);
            spent = uint256(-delta1);
            if (spent > data.exactAmount) revert RefundAccountingMismatch(spent, data.exactAmount);
            if (ethOut < data.minimumAmountOut) revert MinimumOutputNotMet(ethOut, data.minimumAmountOut);
            poolManager.sync(key.currency1);
            if (!SwaputerToken(Currency.unwrap(key.currency1)).transferFrom(data.payer, address(poolManager), spent)) {
                revert TokenTransferFailed();
            }
            poolManager.settle();
            poolManager.take(key.currency0, data.recipient, ethOut);
        }

        delta0 = poolManager.currencyDelta(address(this), key.currency0);
        delta1 = poolManager.currencyDelta(address(this), key.currency1);
        if (delta0 != 0 || delta1 != 0 || poolManager.getNonzeroDeltaCount() != 0) {
            revert SettlementNotCleared(delta0, delta1);
        }
        result = abi.encode(delta, spent, vmResult, vmResultLength);
    }

    function _unlock(UnlockData memory data)
        private
        returns (BalanceDelta delta, uint256 spent, bytes32 vmResult, uint32 vmResultLength)
    {
        if (factory.router() != address(this)) revert FactoryRouterMismatch(factory.router(), address(this));
        if (_activeCallback() != bytes32(0)) revert ReentrantUnlock();
        bytes memory callbackData = abi.encode(data);
        _setActiveCallback(_callbackCommitment(callbackData));
        bytes memory result = poolManager.unlock(callbackData);
        _setActiveCallback(bytes32(0));
        (delta, spent, vmResult, vmResultLength) = abi.decode(result, (BalanceDelta, uint256, bytes32, uint32));
    }

    function _validateNativeInputAndRecipient(address recipient) private view returns (uint128 exactAmount) {
        if (recipient == address(0)) revert InvalidRecipient(recipient);
        if (msg.value == 0 || msg.value > type(uint128).max) revert InvalidExactInput(msg.value);
        exactAmount = uint128(msg.value);
    }

    function _refundNative(address payer, uint256 budget, uint256 spent) private {
        if (spent > budget) revert RefundAccountingMismatch(spent, budget);
        uint256 refund = budget - spent;
        if (refund == 0) return;
        _payNative(payer, refund);
    }

    function _payNative(address recipient, uint256 amount) private {
        if (amount == 0) return;
        (bool success,) = recipient.call{value: amount}("");
        if (!success) revert NativeTransferFailed(recipient, amount);
    }

    function _callbackCommitment(bytes memory callbackData) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(bytes1(0xa7), callbackData));
    }

    function _activeCallback() private view returns (bytes32 active) {
        bytes32 slot = ACTIVE_CALLBACK_SLOT;
        assembly ("memory-safe") {
            active := tload(slot)
        }
    }

    function _setActiveCallback(bytes32 active) private {
        bytes32 slot = ACTIVE_CALLBACK_SLOT;
        assembly ("memory-safe") {
            tstore(slot, active)
        }
    }

    receive() external payable {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager(msg.sender);
    }
}
