// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {SwaputerToken} from "./SwaputerToken.sol";
import {SwaputerKernel} from "./SwaputerKernel.sol";

/// @notice SVM execution and protocol-fee Hook permanently scoped to one native ETH / Gas Token v4 pool.
contract SwaputerHook is IHooks, IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeCast for int128;
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;

    IPoolManager public immutable poolManager;
    SwaputerKernel public immutable kernel;
    SwaputerToken public immutable gasToken;
    address public immutable owner;
    address public immutable feeController;
    uint128 public immutable byteGasPrice;
    uint24 public immutable poolFee;
    int24 public immutable poolTickSpacing;
    address public feeAdmin;
    uint16 public protocolFeeBps;
    uint256 public accruedProtocolFees;
    bytes32 public boundPoolId;
    bool public poolBound;
    bool public tradingLive;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint16 public constant MAX_PROTOCOL_FEE_BPS = 1_000;
    uint32 public constant MAX_BYTE_GAS_LIMIT = 1_000_000;
    bytes32 private constant VM_RESULT_CONSUMER_SLOT = keccak256("SwaputerHook.vmResult.consumer.v1");
    bytes32 private constant VM_RESULT_WORD_SLOT = keccak256("SwaputerHook.vmResult.word.v1");
    bytes32 private constant VM_RESULT_LENGTH_SLOT = keccak256("SwaputerHook.vmResult.length.v1");

    error OnlyPoolManager(address caller);
    error OnlyOwner(address caller);
    error HookNotImplemented();
    error InvalidWorld();
    error ExactOutputUnsupported();
    error InvalidGrossTokenOut(int128 delta);
    error InvalidGrossNativeOut(int128 delta);
    error GrossOutputDoesNotCoverFee(uint128 grossTokenOut, uint128 fee);
    error ExactEthInputOutOfRange(uint256 amount);
    error ChainContextOutOfRange(uint256 blockNumber, uint256 timestamp);
    error ByteGasPriceOutOfRange(uint128 price);
    error KernelByteCountMismatch(uint32 actual);
    error InvalidBinding();
    error InvalidEnvelopeWorld(bytes32 expected, bytes32 supplied);
    error InvalidByteGasLimit(uint32 limit);
    error MaximumExposureOutOfRange(uint256 exposure);
    error GrossOutputBelowMaximumExposure(uint128 gross, uint256 required);
    error BurnMismatch(uint256 expected, uint256 actual);
    error VMResultUnavailable(address caller);
    error InvalidFeeController();
    error InvalidFeeAdmin();
    error UnauthorizedFeeController(address expected, address actual);
    error ProtocolFeeTooHigh(uint256 supplied, uint256 maximum);
    error OnlyFeeAdmin(address caller);
    error HookAlreadyBound(bytes32 poolId);
    error HookNotBound();
    error NoProtocolFees();
    error TradingNotLive();
    error TradingAlreadyLive();

    event HookBound(bytes32 indexed poolId, address indexed gasToken);
    event ProtocolFeeAccrued(address indexed router, bool indexed isBuy, uint256 grossNativeAmount, uint256 feeAmount);
    event ProtocolFeeBpsUpdated(uint16 previousFeeBps, uint16 newFeeBps);
    event ProtocolFeesClaimed(address indexed admin, uint256 amount);
    event FeeAdminTransferred(address indexed previousAdmin, address indexed newAdmin);
    event TradingLive(address indexed owner);

    constructor(
        IPoolManager manager,
        SwaputerKernel boundKernel,
        SwaputerToken token,
        address initialFeeAdmin,
        address controller,
        uint16 initialFeeBps,
        uint128 price,
        uint24 fee,
        int24 tickSpacing
    ) {
        if (
            address(manager) == address(0) || address(boundKernel) == address(0) || address(token) == address(0)
                || boundKernel.hook() != address(this) || boundKernel.byteGasPrice() != price
        ) revert InvalidBinding();
        if (initialFeeAdmin == address(0)) revert InvalidFeeAdmin();
        if (controller == address(0)) revert InvalidFeeController();
        if (initialFeeBps > MAX_PROTOCOL_FEE_BPS) {
            revert ProtocolFeeTooHigh(initialFeeBps, MAX_PROTOCOL_FEE_BPS);
        }
        if (price == 0 || price > uint128(type(int128).max)) revert ByteGasPriceOutOfRange(price);
        poolManager = manager;
        kernel = boundKernel;
        gasToken = token;
        owner = initialFeeAdmin;
        feeAdmin = initialFeeAdmin;
        feeController = controller;
        protocolFeeBps = initialFeeBps;
        byteGasPrice = price;
        poolFee = fee;
        poolTickSpacing = tickSpacing;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager(msg.sender);
        _;
    }

    modifier onlyFeeAdmin() {
        if (msg.sender != feeAdmin) revert OnlyFeeAdmin(msg.sender);
        _;
    }

    /// @notice Permanently enables swaps for this World. Trading cannot be disabled again.
    function live() external {
        if (msg.sender != owner) revert OnlyOwner(msg.sender);
        if (tradingLive) revert TradingAlreadyLive();
        tradingLive = true;
        emit TradingLive(msg.sender);
    }

    function setProtocolFeeBps(uint16 newFeeBps) external {
        if (msg.sender != feeController) revert UnauthorizedFeeController(feeController, msg.sender);
        if (newFeeBps > MAX_PROTOCOL_FEE_BPS) {
            revert ProtocolFeeTooHigh(newFeeBps, MAX_PROTOCOL_FEE_BPS);
        }
        uint16 previousFeeBps = protocolFeeBps;
        protocolFeeBps = newFeeBps;
        emit ProtocolFeeBpsUpdated(previousFeeBps, newFeeBps);
    }

    function protocolFee(uint256 grossNativeAmount) public view returns (uint256) {
        return grossNativeAmount * protocolFeeBps / BPS_DENOMINATOR;
    }

    function netNativeAfterFee(uint256 grossNativeAmount) public view returns (uint256) {
        return grossNativeAmount - protocolFee(grossNativeAmount);
    }

    /// @notice Claims all accounted protocol fees to the current administrator.
    function claimProtocolFees() external onlyFeeAdmin returns (uint256 amount) {
        amount = accruedProtocolFees;
        if (amount == 0) revert NoProtocolFees();
        accruedProtocolFees = 0;
        poolManager.unlock(abi.encode(msg.sender, amount));
        emit ProtocolFeesClaimed(msg.sender, amount);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (address recipient, uint256 amount) = abi.decode(data, (address, uint256));
        Currency nativeCurrency = Currency.wrap(address(0));
        poolManager.burn(address(this), nativeCurrency.toId(), amount);
        poolManager.take(nativeCurrency, recipient, amount);
        return bytes("");
    }

    /// @notice Immediately transfers fee administration to a new nonzero address.
    function transferAdmin(address newAdmin) external onlyFeeAdmin {
        if (newAdmin == address(0)) revert InvalidFeeAdmin();
        address previousAdmin = feeAdmin;
        feeAdmin = newAdmin;
        emit FeeAdminTransferred(previousAdmin, newAdmin);
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory permissions) {
        permissions.beforeInitialize = true;
        permissions.beforeSwap = true;
        permissions.beforeSwapReturnDelta = true;
        permissions.afterSwap = true;
        permissions.afterSwapReturnDelta = true;
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, int128) {
        _validateWorld(key);

        // Native ETH is currency0, so every one-for-zero swap is a TOKEN -> ETH sell.
        if (!params.zeroForOne) {
            if (protocolFeeBps == 0) return (IHooks.afterSwap.selector, 0);
            int128 nativeOutputDelta = delta.amount0();
            if (nativeOutputDelta <= 0) revert InvalidGrossNativeOut(nativeOutputDelta);
            uint256 grossNativeOut = nativeOutputDelta.toUint128();
            uint256 sellFee = protocolFee(grossNativeOut);
            _collectProtocolFee(sender, false, grossNativeOut, sellFee, key.currency0);
            return (IHooks.afterSwap.selector, sellFee.toInt128());
        }

        int128 outputDelta = delta.amount1();
        if (outputDelta <= 0) revert InvalidGrossTokenOut(outputDelta);
        uint128 grossTokenOut = outputDelta.toUint128();
        uint256 ethAmountIn256 = _absoluteExactInput(params.amountSpecified);
        if (ethAmountIn256 > type(uint128).max) revert ExactEthInputOutOfRange(ethAmountIn256);
        if (block.number > type(uint64).max || block.timestamp > type(uint64).max) {
            revert ChainContextOutOfRange(block.number, block.timestamp);
        }

        uint256 nativeFee = protocolFee(ethAmountIn256);
        _collectProtocolFee(sender, true, ethAmountIn256, nativeFee, key.currency0);

        PoolId world = key.toId();
        (, int24 tickAfter,,) = poolManager.getSlot0(world);
        uint128 liquidityAfter = poolManager.getLiquidity(world);
        bytes32 worldId = PoolId.unwrap(world);
        uint64 currentHeight = kernel.executionHeight(worldId);
        if (currentHeight == type(uint64).max) revert SwaputerKernel.HeightOverflow();

        SwaputerKernel.BuyReceipt memory receipt = SwaputerKernel.BuyReceipt({
            worldId: worldId,
            executionHeight: currentHeight + 1,
            actor: bytes32(0),
            ethAmountIn: ethAmountIn256.toUint128(),
            grossTokenOut: grossTokenOut,
            tokenGasBurned: 0,
            tickAfter: tickAfter,
            liquidityAfter: liquidityAfter,
            chainBlockNumber: uint64(block.number),
            chainTimestamp: uint64(block.timestamp)
        });

        uint32 bytesUsed;
        uint128 fee;
        if (hookData.length == 0) {
            fee = byteGasPrice;
            if (grossTokenOut <= fee) revert GrossOutputDoesNotCoverFee(grossTokenOut, fee);
            receipt.tokenGasBurned = fee;
            bytesUsed = kernel.executeNOP(receipt);
            if (bytesUsed != 1) revert KernelByteCountMismatch(bytesUsed);
        } else {
            SwaputerKernel.VMEnvelope memory action = abi.decode(hookData, (SwaputerKernel.VMEnvelope));
            if (action.worldId != worldId) revert InvalidEnvelopeWorld(worldId, action.worldId);
            if (action.byteGasLimit == 0 || action.byteGasLimit > MAX_BYTE_GAS_LIMIT) {
                revert InvalidByteGasLimit(action.byteGasLimit);
            }
            uint256 maxExposure = uint256(action.byteGasLimit) * byteGasPrice;
            if (maxExposure > uint256(uint128(type(int128).max))) revert MaximumExposureOutOfRange(maxExposure);
            uint256 required = maxExposure + action.minNetTokenOut;
            if (required > grossTokenOut) revert GrossOutputBelowMaximumExposure(grossTokenOut, required);

            uint128 kernelBurn;
            bytes memory output;
            (bytesUsed, kernelBurn, output,) = kernel.executeCall(
                receipt,
                action,
                SwaputerKernel.ActionBinding({sqrtPriceLimitX96: params.sqrtPriceLimitX96, router: sender})
            );
            _storeVMResult(sender, output);
            uint256 expectedBurn = uint256(bytesUsed) * byteGasPrice;
            if (kernelBurn != expectedBurn) revert BurnMismatch(expectedBurn, kernelBurn);
            fee = kernelBurn;
        }

        poolManager.take(key.currency1, address(this), uint256(fee));
        gasToken.burn(uint256(fee));

        return (IHooks.afterSwap.selector, uint256(fee).toInt128());
    }

    function consumeVMResult() external returns (bytes32 word, uint32 length) {
        bytes32 consumerSlot = VM_RESULT_CONSUMER_SLOT;
        bytes32 wordSlot = VM_RESULT_WORD_SLOT;
        bytes32 lengthSlot = VM_RESULT_LENGTH_SLOT;
        address consumer;
        assembly ("memory-safe") {
            consumer := tload(consumerSlot)
            word := tload(wordSlot)
            length := tload(lengthSlot)
        }
        if (consumer != msg.sender) revert VMResultUnavailable(msg.sender);
        assembly ("memory-safe") {
            tstore(consumerSlot, 0)
            tstore(wordSlot, 0)
            tstore(lengthSlot, 0)
        }
    }

    function _storeVMResult(address consumer, bytes memory output) private {
        uint256 outputLength = output.length;
        bytes32 word;
        if (outputLength <= 32) {
            assembly ("memory-safe") {
                word := mload(add(output, 0x20))
            }
        } else {
            word = keccak256(output);
        }
        bytes32 consumerSlot = VM_RESULT_CONSUMER_SLOT;
        bytes32 wordSlot = VM_RESULT_WORD_SLOT;
        bytes32 lengthSlot = VM_RESULT_LENGTH_SLOT;
        assembly ("memory-safe") {
            tstore(consumerSlot, consumer)
            tstore(wordSlot, word)
            tstore(lengthSlot, outputLength)
        }
    }

    function _validateWorld(PoolKey calldata key) private view {
        if (!poolBound) revert HookNotBound();
        _validatePoolKey(key);
        if (PoolId.unwrap(key.toId()) != boundPoolId) revert InvalidWorld();
    }

    function _validatePoolKey(PoolKey calldata key) private view {
        if (
            !key.currency0.isAddressZero() || Currency.unwrap(key.currency1) != address(gasToken)
                || address(key.hooks) != address(this) || key.fee != poolFee || key.tickSpacing != poolTickSpacing
        ) revert InvalidWorld();
    }

    function _collectProtocolFee(
        address router,
        bool isBuy,
        uint256 grossNativeAmount,
        uint256 feeAmount,
        Currency nativeCurrency
    ) private {
        if (feeAmount == 0) return;
        // During afterSwap the router has not settled its native input yet. Mint a
        // PoolManager claim instead of transferring ETH immediately; the claim is
        // redeemed only when the administrator calls claimProtocolFees().
        poolManager.mint(address(this), nativeCurrency.toId(), feeAmount);
        accruedProtocolFees += feeAmount;
        emit ProtocolFeeAccrued(router, isBuy, grossNativeAmount, feeAmount);
    }

    function _absoluteExactInput(int256 amountSpecified) private pure returns (uint256 absoluteAmount) {
        assembly ("memory-safe") {
            absoluteAmount := sub(0, amountSpecified)
        }
    }

    function beforeInitialize(address, PoolKey calldata key, uint160) external onlyPoolManager returns (bytes4) {
        _validatePoolKey(key);
        if (poolBound) revert HookAlreadyBound(boundPoolId);
        bytes32 poolId = PoolId.unwrap(key.toId());
        boundPoolId = poolId;
        poolBound = true;
        emit HookBound(poolId, address(gasToken));
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external view onlyPoolManager returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _validateWorld(key);
        if (!tradingLive) revert TradingNotLive();
        if (params.amountSpecified >= 0) revert ExactOutputUnsupported();
        if (!params.zeroForOne || protocolFeeBps == 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        uint256 grossNativeAmount = _absoluteExactInput(params.amountSpecified);
        uint256 feeAmount = protocolFee(grossNativeAmount);
        if (feeAmount > uint256(uint128(type(int128).max))) revert ExactEthInputOutOfRange(grossNativeAmount);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(feeAmount.toInt128(), 0), 0);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    receive() external payable {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager(msg.sender);
    }
}
