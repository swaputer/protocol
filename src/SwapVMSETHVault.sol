// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SwapVMKernel} from "./SwapVMKernel.sol";
import {SwapVMRouter} from "./SwapVMRouter.sol";
import {SwapVMWorldFactory} from "./SwapVMWorldFactory.sol";

/// @notice Experimental atomic native ETH <-> MiniVM sETH bridge for one immutable SwapVM World.
/// @dev One sETH wei is backed by one native ETH wei counted in `lockedEth`. VM execution input is
///      always supplied separately and any unused Router budget is returned to the transaction payer.
///      This contract intentionally has no owner, proxy, pause, upgrade, sweep, or arbitrary withdrawal.
contract SwapVMSETHVault {
    bytes4 public constant BRIDGE_MINT_SELECTOR = bytes4(keccak256("bridgeMint(bytes32,uint256)"));
    bytes4 public constant BRIDGE_BURN_SELECTOR = bytes4(keccak256("bridgeBurn(uint256)"));
    bytes4 public constant TOTAL_SUPPLY_SELECTOR = bytes4(keccak256("totalSupply()"));
    bytes4 public constant VAULT_SELECTOR = bytes4(keccak256("vault()"));

    SwapVMRouter public immutable router;
    SwapVMKernel public immutable kernel;
    bytes32 public immutable worldId;
    bytes32 public immutable seth;
    bytes32 public immutable sethCodeHash;

    uint256 public lockedEth;
    bytes32 private constant REENTRANCY_SLOT = keccak256("swaputer.seth-vault.reentrancy");

    error ZeroAddress();
    error InvalidRouter();
    error InvalidWorld();
    error InvalidSETH();
    error InvalidAmount();
    error InvalidVMInput();
    error IncorrectValue(uint256 expected, uint256 actual);
    error InvalidEnvelope();
    error InvalidBridgePayload();
    error InvalidProgramRead(bytes4 selector, bytes32 seth, uint256 outputLength);
    error InsufficientBacking(uint256 locked, uint256 requested);
    error NativeTransferFailed(address recipient, uint256 amount);
    error OnlyRouterRefund(address caller);
    error Reentrancy();
    error BackingInvariant(uint256 balance, uint256 liability);
    error SupplyInvariant(uint256 supply, uint256 liability);
    error InvalidVMResult(uint32 length);
    error UnsupportedContractRecipient(address recipient);

    event Deposited(address indexed payer, address indexed recipient, uint128 amount, uint256 vmEthSpent);
    event Redeemed(address indexed owner, address indexed recipient, uint128 amount, uint256 vmEthSpent);

    modifier nonReentrant() {
        bytes32 slot = REENTRANCY_SLOT;
        uint256 entered;
        assembly ("memory-safe") {
            entered := tload(slot)
        }
        if (entered != 0) revert Reentrancy();
        assembly ("memory-safe") {
            tstore(slot, 1)
        }
        _;
        assembly ("memory-safe") {
            tstore(slot, 0)
        }
    }

    constructor(SwapVMRouter boundRouter, bytes32 boundWorldId, bytes32 boundSETH, bytes32 expectedSETHCodeHash) {
        if (address(boundRouter) == address(0)) revert ZeroAddress();
        if (boundWorldId == bytes32(0)) revert InvalidWorld();
        if (boundSETH == bytes32(0) || expectedSETHCodeHash == bytes32(0)) revert InvalidSETH();

        SwapVMWorldFactory boundFactory = SwapVMWorldFactory(address(boundRouter.factory()));
        if (boundFactory.router() != address(boundRouter)) revert InvalidRouter();
        SwapVMWorldFactory.WorldConfig memory config = boundFactory.getWorldConfig(boundWorldId);
        if (!config.isSealed) revert InvalidWorld();
        SwapVMKernel boundKernel = SwapVMKernel(config.kernel);
        if (
            address(boundKernel) == address(0)
                || boundKernel.programCodeHash(boundWorldId, boundSETH) != expectedSETHCodeHash
        ) revert InvalidSETH();

        router = boundRouter;
        kernel = boundKernel;
        worldId = boundWorldId;
        seth = boundSETH;
        sethCodeHash = expectedSETHCodeHash;

        if (_programVault() != address(this) || _supply() != 0) revert InvalidSETH();
    }

    function deposit(
        uint128 amount,
        uint128 vmEthAmount,
        SwapVMKernel.VMEnvelope calldata envelope,
        uint160 sqrtPriceLimitX96
    ) external payable nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (vmEthAmount == 0) revert InvalidVMInput();
        uint256 expected = uint256(amount) + uint256(vmEthAmount);
        if (msg.value != expected) revert IncorrectValue(expected, msg.value);
        if (envelope.recipient.code.length != 0) revert UnsupportedContractRecipient(envelope.recipient);
        _validateMintEnvelope(envelope, msg.sender, amount);

        lockedEth += uint256(amount);
        (uint256 vmEthSpent, uint256 vmSupply) = _runVM(envelope, vmEthAmount, sqrtPriceLimitX96, msg.sender);
        if (vmSupply != lockedEth) revert SupplyInvariant(vmSupply, lockedEth);
        _assertBacking();
        emit Deposited(msg.sender, envelope.recipient, amount, vmEthSpent);
    }

    function redeem(
        uint128 amount,
        uint128 vmEthAmount,
        address recipient,
        SwapVMKernel.VMEnvelope calldata envelope,
        uint160 sqrtPriceLimitX96
    ) external payable nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (vmEthAmount == 0) revert InvalidVMInput();
        if (recipient == address(0)) revert ZeroAddress();
        if (msg.value != uint256(vmEthAmount)) revert IncorrectValue(vmEthAmount, msg.value);
        if (uint256(amount) > lockedEth) revert InsufficientBacking(lockedEth, amount);
        _validateBurnEnvelope(envelope, msg.sender, recipient, amount);

        lockedEth -= uint256(amount);
        (uint256 vmEthSpent, uint256 vmSupply) = _runVM(envelope, vmEthAmount, sqrtPriceLimitX96, msg.sender);
        if (vmSupply != lockedEth) revert SupplyInvariant(vmSupply, lockedEth);
        _pay(recipient, amount);
        _assertBacking();
        emit Redeemed(msg.sender, recipient, amount, vmEthSpent);
    }

    function totalSupply() external view returns (uint256) {
        return _supply();
    }

    function backingSurplus() external view returns (uint256) {
        uint256 balance = address(this).balance;
        if (balance < lockedEth) revert BackingInvariant(balance, lockedEth);
        return balance - lockedEth;
    }

    function isSolvent() external view returns (bool) {
        return address(this).balance >= lockedEth && _supply() == lockedEth;
    }

    function _runVM(
        SwapVMKernel.VMEnvelope calldata envelope,
        uint256 vmEthAmount,
        uint160 sqrtPriceLimitX96,
        address refundRecipient
    ) private returns (uint256 vmEthSpent, uint256 vmSupply) {
        uint256 balanceBefore = address(this).balance;
        (, bytes32 result, uint32 resultLength) =
            router.buyVMExactInputWithResult{value: vmEthAmount}(worldId, sqrtPriceLimitX96, envelope);
        if (resultLength != 32) revert InvalidVMResult(resultLength);
        vmSupply = uint256(result);
        uint256 balanceAfter = address(this).balance;
        if (balanceAfter > balanceBefore) revert BackingInvariant(balanceAfter, lockedEth);
        vmEthSpent = balanceBefore - balanceAfter;
        if (vmEthSpent > vmEthAmount) revert BackingInvariant(balanceAfter, lockedEth);
        uint256 refund = vmEthAmount - vmEthSpent;
        if (refund != 0) _pay(refundRecipient, refund);
    }

    function _validateMintEnvelope(SwapVMKernel.VMEnvelope calldata envelope, address payer, uint128 amount)
        private
        view
    {
        if (
            envelope.op != SwapVMKernel.RootOp.CALL || envelope.worldId != worldId || envelope.actor != payer
                || envelope.targetOrCodeHash != seth || envelope.recipient == address(0)
                || envelope.authorizedExecutor != address(this)
        ) revert InvalidEnvelope();
        _validateMintPayload(envelope.payload, kernel.eoaAccountId(envelope.recipient), amount);
    }

    function _validateBurnEnvelope(
        SwapVMKernel.VMEnvelope calldata envelope,
        address owner,
        address recipient,
        uint128 amount
    ) private view {
        if (
            envelope.op != SwapVMKernel.RootOp.CALL || envelope.worldId != worldId || envelope.actor != owner
                || envelope.targetOrCodeHash != seth || envelope.recipient != recipient
                || envelope.authorizedExecutor != address(this)
        ) revert InvalidEnvelope();
        _validateBurnPayload(envelope.payload, amount);
    }

    function _validateMintPayload(bytes calldata payload, bytes32 expectedAccount, uint128 amount) private pure {
        if (payload.length != 68) revert InvalidBridgePayload();
        bytes4 selector;
        bytes32 account;
        uint256 encodedAmount;
        assembly ("memory-safe") {
            selector := calldataload(payload.offset)
            account := calldataload(add(payload.offset, 4))
            encodedAmount := calldataload(add(payload.offset, 36))
        }
        if (selector != BRIDGE_MINT_SELECTOR || account != expectedAccount || encodedAmount != uint256(amount)) {
            revert InvalidBridgePayload();
        }
    }

    function _validateBurnPayload(bytes calldata payload, uint128 amount) private pure {
        if (payload.length != 36) revert InvalidBridgePayload();
        bytes4 selector;
        uint256 encodedAmount;
        assembly ("memory-safe") {
            selector := calldataload(payload.offset)
            encodedAmount := calldataload(add(payload.offset, 4))
        }
        if (selector != BRIDGE_BURN_SELECTOR || encodedAmount != uint256(amount)) revert InvalidBridgePayload();
    }

    function _supply() private view returns (uint256 supply) {
        (bytes memory output,) = kernel.staticCall(worldId, seth, abi.encodePacked(TOTAL_SUPPLY_SELECTOR), 2_000);
        if (output.length != 32) revert InvalidProgramRead(TOTAL_SUPPLY_SELECTOR, seth, output.length);
        supply = abi.decode(output, (uint256));
    }

    function _programVault() private view returns (address boundVault) {
        (bytes memory output,) = kernel.staticCall(worldId, seth, abi.encodePacked(VAULT_SELECTOR), 2_000);
        if (output.length != 32) revert InvalidProgramRead(VAULT_SELECTOR, seth, output.length);
        boundVault = address(uint160(abi.decode(output, (uint256))));
    }

    function _assertBacking() private view {
        uint256 balance = address(this).balance;
        if (balance < lockedEth) revert BackingInvariant(balance, lockedEth);
    }

    function _pay(address recipient, uint256 amount) private {
        (bool success,) = recipient.call{value: amount}("");
        if (!success) revert NativeTransferFailed(recipient, amount);
    }

    receive() external payable {
        if (msg.sender != address(router)) revert OnlyRouterRefund(msg.sender);
    }
}
