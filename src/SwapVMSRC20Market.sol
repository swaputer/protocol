// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SwapVMKernel} from "./SwapVMKernel.sol";
import {SwapVMRouter} from "./SwapVMRouter.sol";
import {SwapVMWorldFactory} from "./SwapVMWorldFactory.sol";

/// @notice Experimental zero-value SRC20/ETH escrow order settlement for one immutable SwapVM World.
/// @dev Buy orders escrow native ETH in this EVM contract. Sell orders escrow SRC20 inside the bound
///      MiniVM MarketEscrow program. All SRC movement still happens through signed SwapVM Router calls.
///      This contract intentionally has no owner, proxy, pause, upgrade, sweep, or arbitrary withdrawal.
contract SwapVMSRC20Market {
    uint256 public constant MAX_TOKEN_DECIMALS = 38;
    bytes4 public constant TRANSFER_SELECTOR = bytes4(keccak256("transfer(bytes32,uint256)"));
    bytes4 public constant DEPOSIT_SELECTOR = bytes4(keccak256("deposit(bytes32,uint256)"));
    bytes4 public constant RELEASE_SELECTOR = bytes4(keccak256("release(bytes32,uint256)"));
    bytes4 public constant BALANCE_OF_SELECTOR = bytes4(keccak256("balanceOf(bytes32)"));
    bytes4 public constant DECIMALS_SELECTOR = bytes4(keccak256("decimals()"));

    enum Side {
        Buy,
        Sell
    }

    enum Status {
        None,
        Open,
        Filled,
        Cancelled
    }

    struct Order {
        address maker;
        address taker;
        uint64 expiry;
        Side side;
        Status status;
        uint128 amount;
        uint128 unitPriceWei;
        uint128 priceWei;
        uint128 vmEthAmount;
    }

    SwapVMRouter public immutable router;
    SwapVMKernel public immutable kernel;
    bytes32 public immutable worldId;
    bytes32 public immutable token;
    bytes32 public immutable tokenCodeHash;
    bytes32 public immutable escrow;
    bytes32 public immutable escrowCodeHash;
    uint256 public immutable tokenScale;

    uint256 public orderCount;
    uint256 public lockedEth;
    uint256 public escrowedTokenAmount;
    mapping(uint256 orderId => Order order) public orders;
    mapping(address maker => uint256 amount) public activeSellAmount;

    bytes32 private constant REENTRANCY_SLOT = keccak256("swaputer.src20-market.reentrancy");

    error ZeroAddress();
    error InvalidWorld();
    error InvalidRouter();
    error InvalidToken();
    error InvalidEscrow();
    error InvalidAmount();
    error InvalidPrice();
    error InvalidVMInput();
    error InvalidExpiry(uint64 expiry);
    error IncorrectValue(uint256 expected, uint256 actual);
    error InvalidOrder(uint256 orderId);
    error InvalidStatus(uint256 orderId, Status expected, Status actual);
    error OrderExpired(uint256 orderId);
    error Unauthorized(address expected, address actual);
    error InvalidEnvelope();
    error InvalidTransferPayload();
    error InvalidBalanceRead(bytes32 token, uint256 outputLength);
    error SellEscrowReleaseRequired(uint256 orderId);
    error NativeTransferFailed(address recipient, uint256 amount);
    error OnlyRouterRefund(address caller);
    error Reentrancy();
    error LockedEthInvariant(uint256 balance, uint256 liability);
    error EscrowInvariant(uint256 balance, uint256 liability);
    error InvalidVMResult(uint32 length);
    error InvalidTokenDecimals(uint256 decimals);
    error UnsupportedContractRecipient(address recipient);

    event OrderCreated(
        uint256 indexed orderId,
        Side indexed side,
        address indexed maker,
        uint128 amount,
        uint128 unitPriceWei,
        uint128 priceWei,
        uint128 vmEthAmount,
        uint64 expiry
    );
    event OrderFilled(
        uint256 indexed orderId,
        address indexed seller,
        address indexed buyer,
        uint128 amount,
        uint128 priceWei,
        uint256 vmEthSpent
    );
    event OrderCancelled(uint256 indexed orderId, address indexed maker);
    event SellEscrowed(uint256 indexed orderId, address indexed seller, uint128 amount, uint256 vmEthSpent);
    event SellEscrowReleased(uint256 indexed orderId, address indexed seller, uint128 amount, uint256 vmEthSpent);

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

    constructor(
        SwapVMRouter boundRouter,
        bytes32 boundWorldId,
        bytes32 boundToken,
        bytes32 expectedTokenCodeHash,
        bytes32 boundEscrow,
        bytes32 expectedEscrowCodeHash
    ) {
        if (address(boundRouter) == address(0)) revert ZeroAddress();
        if (boundWorldId == bytes32(0)) revert InvalidWorld();
        if (boundToken == bytes32(0) || expectedTokenCodeHash == bytes32(0)) revert InvalidToken();
        if (boundEscrow == bytes32(0) || expectedEscrowCodeHash == bytes32(0)) revert InvalidEscrow();
        SwapVMWorldFactory boundFactory = SwapVMWorldFactory(address(boundRouter.factory()));
        if (boundFactory.router() != address(boundRouter)) revert InvalidRouter();
        SwapVMWorldFactory.WorldConfig memory config = boundFactory.getWorldConfig(boundWorldId);
        if (!config.isSealed) revert InvalidWorld();
        address kernelAddress = config.kernel;
        SwapVMKernel boundKernel = SwapVMKernel(kernelAddress);
        if (
            address(boundKernel) == address(0)
                || boundKernel.programCodeHash(boundWorldId, boundToken) != expectedTokenCodeHash
        ) {
            revert InvalidToken();
        }
        if (boundKernel.programCodeHash(boundWorldId, boundEscrow) != expectedEscrowCodeHash) {
            revert InvalidEscrow();
        }
        (bytes memory decimalsOutput,) =
            boundKernel.staticCall(boundWorldId, boundToken, abi.encodePacked(DECIMALS_SELECTOR), 2_000);
        if (decimalsOutput.length != 32) revert InvalidToken();
        uint256 decimals = abi.decode(decimalsOutput, (uint256));
        if (decimals > MAX_TOKEN_DECIMALS) revert InvalidTokenDecimals(decimals);
        router = boundRouter;
        kernel = boundKernel;
        worldId = boundWorldId;
        token = boundToken;
        tokenCodeHash = expectedTokenCodeHash;
        escrow = boundEscrow;
        escrowCodeHash = expectedEscrowCodeHash;
        tokenScale = 10 ** decimals;
    }

    function quotePrice(uint128 amount, uint128 unitPriceWei) public view returns (uint128 priceWei) {
        if (amount == 0) revert InvalidAmount();
        if (unitPriceWei == 0) revert InvalidPrice();
        uint256 quoted = uint256(amount) * uint256(unitPriceWei) / tokenScale;
        if (quoted == 0 || quoted > type(uint128).max) revert InvalidPrice();
        priceWei = uint128(quoted);
    }

    function getOrder(uint256 orderId) external view returns (Order memory order) {
        order = _order(orderId);
    }

    function isSellOrderSolvent(uint256 orderId) external view returns (bool solvent) {
        Order storage order = _order(orderId);
        if (order.side != Side.Sell || order.status != Status.Open) return true;
        return _src20BalanceOfId(escrow) >= escrowedTokenAmount;
    }

    function createBuyOrder(uint128 amount, uint128 unitPriceWei, uint128 vmEthAmount, uint64 expiry)
        external
        payable
        nonReentrant
        returns (uint256 orderId)
    {
        _rejectContractRecipient(msg.sender);
        uint128 priceWei = quotePrice(amount, unitPriceWei);
        _validateCreation(vmEthAmount, expiry);
        uint256 expected = uint256(priceWei) + uint256(vmEthAmount);
        if (msg.value != expected) revert IncorrectValue(expected, msg.value);

        orderId = ++orderCount;
        orders[orderId] = Order({
            side: Side.Buy,
            status: Status.Open,
            maker: msg.sender,
            taker: address(0),
            amount: amount,
            unitPriceWei: unitPriceWei,
            priceWei: priceWei,
            vmEthAmount: vmEthAmount,
            expiry: expiry
        });
        lockedEth += expected;
        _assertSolvent();
        emit OrderCreated(orderId, Side.Buy, msg.sender, amount, unitPriceWei, priceWei, vmEthAmount, expiry);
    }

    function createSellOrder(
        uint128 amount,
        uint128 unitPriceWei,
        uint128 vmEthAmount,
        uint64 expiry,
        SwapVMKernel.VMEnvelope calldata depositEnvelope,
        uint160 sqrtPriceLimitX96
    ) external payable nonReentrant returns (uint256 orderId) {
        uint128 priceWei = quotePrice(amount, unitPriceWei);
        _validateCreation(vmEthAmount, expiry);
        if (msg.value != uint256(vmEthAmount)) revert IncorrectValue(vmEthAmount, msg.value);
        _validateEscrowDepositEnvelope(depositEnvelope, msg.sender, amount);
        (uint256 vmEthSpent, uint256 vmEscrowBalance) =
            _runVM(depositEnvelope, msg.value, sqrtPriceLimitX96, msg.sender);
        uint256 nextEscrowedTokenAmount = escrowedTokenAmount + uint256(amount);
        if (vmEscrowBalance != nextEscrowedTokenAmount) {
            revert EscrowInvariant(vmEscrowBalance, nextEscrowedTokenAmount);
        }
        _assertEscrowSolvent(nextEscrowedTokenAmount);

        orderId = ++orderCount;
        orders[orderId] = Order({
            side: Side.Sell,
            status: Status.Open,
            maker: msg.sender,
            taker: address(0),
            amount: amount,
            unitPriceWei: unitPriceWei,
            priceWei: priceWei,
            vmEthAmount: vmEthAmount,
            expiry: expiry
        });
        escrowedTokenAmount = nextEscrowedTokenAmount;
        activeSellAmount[msg.sender] += uint256(amount);
        _assertSolvent();
        emit OrderCreated(orderId, Side.Sell, msg.sender, amount, unitPriceWei, priceWei, vmEthAmount, expiry);
        emit SellEscrowed(orderId, msg.sender, amount, vmEthSpent);
    }

    function fillBuyOrder(uint256 orderId, SwapVMKernel.VMEnvelope calldata envelope, uint160 sqrtPriceLimitX96)
        external
        nonReentrant
    {
        Order storage order = _openOrder(orderId, Side.Buy);
        address seller = msg.sender;
        address buyer = order.maker;
        _rejectContractRecipient(buyer);
        _validateTokenTransferEnvelope(envelope, seller, buyer, order.amount);
        order.status = Status.Filled;
        order.taker = seller;
        _settleBuyOrder(orderId, order, seller, buyer, envelope, sqrtPriceLimitX96);
    }

    function settleSellOrder(uint256 orderId, SwapVMKernel.VMEnvelope calldata envelope, uint160 sqrtPriceLimitX96)
        external
        payable
        nonReentrant
    {
        Order storage order = _openOrder(orderId, Side.Sell);
        address seller = order.maker;
        address buyer = msg.sender;
        _rejectContractRecipient(buyer);
        uint256 expected = uint256(order.priceWei) + uint256(order.vmEthAmount);
        if (msg.value != expected) revert IncorrectValue(expected, msg.value);
        _validateEscrowReleaseEnvelope(envelope, buyer, buyer, order.amount);
        _assertEscrowSolvent(escrowedTokenAmount);

        order.status = Status.Filled;
        order.taker = buyer;
        escrowedTokenAmount -= uint256(order.amount);
        activeSellAmount[seller] -= uint256(order.amount);
        (uint256 vmEthSpent, uint256 vmEscrowBalance) = _runVM(envelope, order.vmEthAmount, sqrtPriceLimitX96, buyer);
        if (vmEscrowBalance != escrowedTokenAmount) {
            revert EscrowInvariant(vmEscrowBalance, escrowedTokenAmount);
        }
        _assertEscrowSolvent(escrowedTokenAmount);
        _pay(seller, order.priceWei);
        _assertSolvent();
        emit OrderFilled(orderId, seller, buyer, order.amount, order.priceWei, vmEthSpent);
    }

    function cancelOrder(uint256 orderId) external nonReentrant {
        Order storage order = _order(orderId);
        if (msg.sender != order.maker) revert Unauthorized(order.maker, msg.sender);
        if (order.status != Status.Open) revert InvalidStatus(orderId, Status.Open, order.status);
        if (order.side == Side.Sell) revert SellEscrowReleaseRequired(orderId);
        order.status = Status.Cancelled;
        uint256 refund = uint256(order.priceWei) + uint256(order.vmEthAmount);
        lockedEth -= refund;
        _pay(order.maker, refund);
        _assertSolvent();
        emit OrderCancelled(orderId, order.maker);
    }

    function cancelSellOrder(uint256 orderId, SwapVMKernel.VMEnvelope calldata envelope, uint160 sqrtPriceLimitX96)
        external
        payable
        nonReentrant
    {
        Order storage order = _order(orderId);
        if (msg.sender != order.maker) revert Unauthorized(order.maker, msg.sender);
        if (order.status != Status.Open) revert InvalidStatus(orderId, Status.Open, order.status);
        if (order.side != Side.Sell) revert InvalidOrder(orderId);
        if (msg.value == 0 || msg.value > type(uint128).max) revert InvalidVMInput();
        _validateEscrowReleaseEnvelope(envelope, msg.sender, msg.sender, order.amount);
        _assertEscrowSolvent(escrowedTokenAmount);

        order.status = Status.Cancelled;
        escrowedTokenAmount -= uint256(order.amount);
        activeSellAmount[msg.sender] -= uint256(order.amount);
        (uint256 vmEthSpent, uint256 vmEscrowBalance) = _runVM(envelope, msg.value, sqrtPriceLimitX96, msg.sender);
        if (vmEscrowBalance != escrowedTokenAmount) {
            revert EscrowInvariant(vmEscrowBalance, escrowedTokenAmount);
        }
        _assertEscrowSolvent(escrowedTokenAmount);
        _assertSolvent();
        emit SellEscrowReleased(orderId, msg.sender, order.amount, vmEthSpent);
        emit OrderCancelled(orderId, order.maker);
    }

    function expireOrder(uint256 orderId) external nonReentrant {
        Order storage order = _order(orderId);
        if (order.status != Status.Open) revert InvalidStatus(orderId, Status.Open, order.status);
        if (block.timestamp <= order.expiry) revert OrderExpired(orderId);
        if (order.side == Side.Sell) revert SellEscrowReleaseRequired(orderId);
        order.status = Status.Cancelled;
        uint256 refund = uint256(order.priceWei) + uint256(order.vmEthAmount);
        lockedEth -= refund;
        _pay(order.maker, refund);
        _assertSolvent();
        emit OrderCancelled(orderId, order.maker);
    }

    function _settleBuyOrder(
        uint256 orderId,
        Order storage order,
        address seller,
        address buyer,
        SwapVMKernel.VMEnvelope calldata envelope,
        uint160 sqrtPriceLimitX96
    ) private {
        uint256 liability = uint256(order.priceWei) + uint256(order.vmEthAmount);
        lockedEth -= liability;
        (uint256 vmEthSpent,) = _runVM(envelope, order.vmEthAmount, sqrtPriceLimitX96, buyer);
        _pay(seller, order.priceWei);
        _assertSolvent();
        emit OrderFilled(orderId, seller, buyer, order.amount, order.priceWei, vmEthSpent);
    }

    function _runVM(
        SwapVMKernel.VMEnvelope calldata envelope,
        uint256 vmEthAmount,
        uint160 sqrtPriceLimitX96,
        address refundRecipient
    ) private returns (uint256 vmEthSpent, uint256 vmResult) {
        uint256 balanceBefore = address(this).balance;
        (, bytes32 result, uint32 resultLength) =
            router.buyVMExactInputWithResult{value: vmEthAmount}(worldId, sqrtPriceLimitX96, envelope);
        if (resultLength != 32) revert InvalidVMResult(resultLength);
        vmResult = uint256(result);
        uint256 balanceAfter = address(this).balance;
        if (balanceAfter > balanceBefore) revert LockedEthInvariant(balanceAfter, lockedEth);
        vmEthSpent = balanceBefore - balanceAfter;
        if (vmEthSpent > vmEthAmount) revert LockedEthInvariant(balanceAfter, lockedEth);
        uint256 refund = vmEthAmount - vmEthSpent;
        if (refund != 0) _pay(refundRecipient, refund);
    }

    function _validateTokenTransferEnvelope(
        SwapVMKernel.VMEnvelope calldata envelope,
        address seller,
        address buyer,
        uint128 amount
    ) private view {
        if (
            envelope.op != SwapVMKernel.RootOp.CALL || envelope.worldId != worldId || envelope.actor != seller
                || envelope.targetOrCodeHash != token || envelope.recipient != buyer
                || envelope.authorizedExecutor != address(this)
        ) revert InvalidEnvelope();
        _validatePayload(envelope.payload, TRANSFER_SELECTOR, kernel.eoaAccountId(buyer), amount);
    }

    function _validateEscrowDepositEnvelope(SwapVMKernel.VMEnvelope calldata envelope, address seller, uint128 amount)
        private
        view
    {
        if (
            envelope.op != SwapVMKernel.RootOp.CALL || envelope.worldId != worldId || envelope.actor != seller
                || envelope.targetOrCodeHash != escrow || envelope.recipient != seller
                || envelope.authorizedExecutor != address(this)
        ) revert InvalidEnvelope();
        _validatePayload(envelope.payload, DEPOSIT_SELECTOR, kernel.eoaAccountId(seller), amount);
    }

    function _validateEscrowReleaseEnvelope(
        SwapVMKernel.VMEnvelope calldata envelope,
        address actor,
        address recipient,
        uint128 amount
    ) private view {
        if (
            envelope.op != SwapVMKernel.RootOp.CALL || envelope.worldId != worldId || envelope.actor != actor
                || envelope.targetOrCodeHash != escrow || envelope.recipient != recipient
                || envelope.authorizedExecutor != address(this)
        ) revert InvalidEnvelope();
        _validatePayload(envelope.payload, RELEASE_SELECTOR, kernel.eoaAccountId(recipient), amount);
    }

    function _validatePayload(bytes calldata payload, bytes4 expectedSelector, bytes32 expectedAccount, uint128 amount)
        private
        pure
    {
        if (payload.length != 68) revert InvalidTransferPayload();
        bytes4 selector;
        bytes32 account;
        uint256 encodedAmount;
        assembly ("memory-safe") {
            selector := calldataload(payload.offset)
            account := calldataload(add(payload.offset, 4))
            encodedAmount := calldataload(add(payload.offset, 36))
        }
        if (selector != expectedSelector || account != expectedAccount || encodedAmount != uint256(amount)) {
            revert InvalidTransferPayload();
        }
    }

    function _validateCreation(uint128 vmEthAmount, uint64 expiry) private view {
        if (vmEthAmount == 0) revert InvalidVMInput();
        if (expiry <= block.timestamp) revert InvalidExpiry(expiry);
    }

    function _src20BalanceOfId(bytes32 account) private view returns (uint256 balance) {
        bytes memory payload = abi.encodePacked(BALANCE_OF_SELECTOR, abi.encode(account));
        (bytes memory output,) = kernel.staticCall(worldId, token, payload, 2_000);
        if (output.length != 32) revert InvalidBalanceRead(token, output.length);
        balance = abi.decode(output, (uint256));
    }

    function _openOrder(uint256 orderId, Side side) private view returns (Order storage order) {
        order = _order(orderId);
        if (order.side != side) revert InvalidOrder(orderId);
        if (order.status != Status.Open) revert InvalidStatus(orderId, Status.Open, order.status);
        if (block.timestamp > order.expiry) revert OrderExpired(orderId);
    }

    function _order(uint256 orderId) private view returns (Order storage order) {
        order = orders[orderId];
        if (order.status == Status.None) revert InvalidOrder(orderId);
    }

    function _pay(address recipient, uint256 amount) private {
        (bool success,) = recipient.call{value: amount}("");
        if (!success) revert NativeTransferFailed(recipient, amount);
    }

    function _assertSolvent() private view {
        if (address(this).balance < lockedEth) revert LockedEthInvariant(address(this).balance, lockedEth);
    }

    function _assertEscrowSolvent(uint256 liability) private view {
        uint256 balance = _src20BalanceOfId(escrow);
        if (balance < liability) revert EscrowInvariant(balance, liability);
    }

    function _rejectContractRecipient(address recipient) private view {
        if (recipient.code.length != 0) revert UnsupportedContractRecipient(recipient);
    }

    receive() external payable {
        if (msg.sender != address(router)) revert OnlyRouterRefund(msg.sender);
    }
}
