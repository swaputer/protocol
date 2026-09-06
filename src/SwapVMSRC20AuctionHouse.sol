// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SwapVMKernel} from "./SwapVMKernel.sol";
import {SwapVMRouter} from "./SwapVMRouter.sol";
import {SwapVMWorldFactory} from "./SwapVMWorldFactory.sol";

/// @notice English auctions for one immutable SRC20 program in one Swaputer World.
/// @dev Lots are held by a bound SVM escrow program. Bids, refunds, and seller proceeds are
///      pull-based native ETH liabilities. Token release is an atomic signed SVM execution.
contract SwapVMSRC20AuctionHouse {
    uint256 public constant MIN_INCREMENT_BPS = 500;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_DURATION = 30 days;
    bytes4 public constant DEPOSIT_SELECTOR = bytes4(keccak256("deposit(bytes32,uint256)"));
    bytes4 public constant RELEASE_SELECTOR = bytes4(keccak256("release(bytes32,uint256)"));
    bytes4 public constant BALANCE_OF_SELECTOR = bytes4(keccak256("balanceOf(bytes32)"));

    enum Status {
        None,
        Open,
        Settled,
        Cancelled
    }

    struct Auction {
        address seller;
        address highestBidder;
        uint64 endTime;
        Status status;
        uint32 bidCount;
        uint128 amount;
        uint128 reservePriceWei;
        uint128 highestBidWei;
        uint128 vmEthAmount;
    }

    SwapVMRouter public immutable router;
    SwapVMKernel public immutable kernel;
    bytes32 public immutable worldId;
    bytes32 public immutable token;
    bytes32 public immutable tokenCodeHash;
    bytes32 public immutable escrow;
    bytes32 public immutable escrowCodeHash;

    uint256 public auctionCount;
    uint256 public activeAuctionCount;
    uint256 public lockedEth;
    uint256 public escrowedTokenAmount;
    mapping(uint256 auctionId => Auction auction) public auctions;
    mapping(address account => uint256 amount) public claimableEth;

    bytes32 private constant REENTRANCY_SLOT = keccak256("swaputer.src20-auction-house.reentrancy");

    error ZeroAddress();
    error InvalidWorld();
    error InvalidRouter();
    error InvalidToken();
    error InvalidEscrow();
    error InvalidAmount();
    error InvalidReservePrice();
    error InvalidVMInput();
    error InvalidEndTime(uint64 endTime);
    error IncorrectValue(uint256 expected, uint256 actual);
    error InvalidAuction(uint256 auctionId);
    error InvalidStatus(uint256 auctionId, Status expected, Status actual);
    error AuctionStillRunning(uint256 auctionId);
    error AuctionEnded(uint256 auctionId);
    error BidTooLow(uint256 minimum, uint256 actual);
    error SellerCannotBid();
    error BidAlreadyPlaced(uint256 auctionId);
    error NothingToWithdraw();
    error Unauthorized(address expected, address actual);
    error InvalidEnvelope();
    error InvalidTransferPayload();
    error InvalidBalanceRead(bytes32 token, uint256 outputLength);
    error NativeTransferFailed(address recipient, uint256 amount);
    error OnlyRouterRefund(address caller);
    error Reentrancy();
    error LockedEthInvariant(uint256 balance, uint256 liability);
    error EscrowInvariant(uint256 balance, uint256 liability);
    error InvalidVMResult(uint32 length);
    error UnsupportedContractRecipient(address recipient);

    event AuctionCreated(
        uint256 indexed auctionId,
        address indexed seller,
        uint128 amount,
        uint128 reservePriceWei,
        uint128 vmEthAmount,
        uint64 endTime
    );
    event BidPlaced(
        uint256 indexed auctionId,
        address indexed bidder,
        uint128 amountWei,
        address indexed previousBidder,
        uint128 previousBidWei,
        uint32 bidCount
    );
    event AuctionSettled(
        uint256 indexed auctionId,
        address indexed seller,
        address indexed winner,
        uint128 amount,
        uint128 winningBidWei,
        uint256 vmEthSpent
    );
    event AuctionCancelled(uint256 indexed auctionId, address indexed seller, uint128 amount, uint256 vmEthSpent);
    event EthWithdrawn(address indexed account, uint256 amount);
    event LotEscrowed(uint256 indexed auctionId, address indexed seller, uint128 amount, uint256 vmEthSpent);
    event LotReleased(uint256 indexed auctionId, address indexed recipient, uint128 amount, uint256 vmEthSpent);

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
        if (!config.isSealed || config.kernel == address(0)) revert InvalidWorld();
        SwapVMKernel boundKernel = SwapVMKernel(config.kernel);
        if (boundKernel.programCodeHash(boundWorldId, boundToken) != expectedTokenCodeHash) revert InvalidToken();
        if (boundKernel.programCodeHash(boundWorldId, boundEscrow) != expectedEscrowCodeHash) revert InvalidEscrow();
        router = boundRouter;
        kernel = boundKernel;
        worldId = boundWorldId;
        token = boundToken;
        tokenCodeHash = expectedTokenCodeHash;
        escrow = boundEscrow;
        escrowCodeHash = expectedEscrowCodeHash;
    }

    function getAuction(uint256 auctionId) external view returns (Auction memory auction) {
        auction = _auction(auctionId);
    }

    function minimumNextBid(uint256 auctionId) public view returns (uint256 minimum) {
        Auction storage auction = _auction(auctionId);
        if (auction.highestBidWei == 0) return auction.reservePriceWei;
        uint256 increment = uint256(auction.highestBidWei) * MIN_INCREMENT_BPS / BPS_DENOMINATOR;
        if (increment == 0) increment = 1;
        minimum = uint256(auction.highestBidWei) + increment;
    }

    function isEscrowSolvent() external view returns (bool) {
        return _src20BalanceOfId(escrow) >= escrowedTokenAmount;
    }

    function createAuction(
        uint128 amount,
        uint128 reservePriceWei,
        uint128 vmEthAmount,
        uint64 endTime,
        SwapVMKernel.VMEnvelope calldata depositEnvelope,
        uint160 sqrtPriceLimitX96
    ) external payable nonReentrant returns (uint256 auctionId) {
        if (amount == 0) revert InvalidAmount();
        if (reservePriceWei == 0) revert InvalidReservePrice();
        if (vmEthAmount == 0) revert InvalidVMInput();
        if (endTime <= block.timestamp || endTime > block.timestamp + MAX_DURATION) revert InvalidEndTime(endTime);
        if (msg.value != vmEthAmount) revert IncorrectValue(vmEthAmount, msg.value);
        _validateEscrowEnvelope(depositEnvelope, msg.sender, msg.sender, DEPOSIT_SELECTOR, amount);

        (uint256 vmEthSpent, uint256 vmEscrowBalance) =
            _runVM(depositEnvelope, vmEthAmount, sqrtPriceLimitX96, msg.sender);
        uint256 nextEscrowed = escrowedTokenAmount + uint256(amount);
        if (vmEscrowBalance != nextEscrowed) revert EscrowInvariant(vmEscrowBalance, nextEscrowed);
        _assertEscrowSolvent(nextEscrowed);

        auctionId = ++auctionCount;
        auctions[auctionId] = Auction({
            seller: msg.sender,
            highestBidder: address(0),
            endTime: endTime,
            status: Status.Open,
            bidCount: 0,
            amount: amount,
            reservePriceWei: reservePriceWei,
            highestBidWei: 0,
            vmEthAmount: vmEthAmount
        });
        activeAuctionCount += 1;
        escrowedTokenAmount = nextEscrowed;
        _assertSolvent();
        emit AuctionCreated(auctionId, msg.sender, amount, reservePriceWei, vmEthAmount, endTime);
        emit LotEscrowed(auctionId, msg.sender, amount, vmEthSpent);
    }

    function bid(uint256 auctionId) external payable nonReentrant {
        if (msg.sender.code.length != 0) revert UnsupportedContractRecipient(msg.sender);
        Auction storage auction = _openAuction(auctionId);
        if (msg.sender == auction.seller) revert SellerCannotBid();
        uint256 minimum = minimumNextBid(auctionId);
        if (msg.value < minimum || msg.value > type(uint128).max) revert BidTooLow(minimum, msg.value);

        address previousBidder = auction.highestBidder;
        uint128 previousBid = auction.highestBidWei;
        if (previousBidder != address(0)) claimableEth[previousBidder] += previousBid;
        auction.highestBidder = msg.sender;
        auction.highestBidWei = uint128(msg.value);
        auction.bidCount += 1;
        lockedEth += msg.value;
        _assertSolvent();
        emit BidPlaced(auctionId, msg.sender, uint128(msg.value), previousBidder, previousBid, auction.bidCount);
    }

    function settleAuction(
        uint256 auctionId,
        SwapVMKernel.VMEnvelope calldata releaseEnvelope,
        uint160 sqrtPriceLimitX96
    ) external payable nonReentrant {
        Auction storage auction = _auction(auctionId);
        if (auction.status != Status.Open) revert InvalidStatus(auctionId, Status.Open, auction.status);
        if (block.timestamp < auction.endTime) revert AuctionStillRunning(auctionId);
        if (auction.highestBidder == address(0)) revert InvalidAuction(auctionId);
        if (auction.highestBidder.code.length != 0) {
            revert UnsupportedContractRecipient(auction.highestBidder);
        }
        if (msg.value != auction.vmEthAmount) revert IncorrectValue(auction.vmEthAmount, msg.value);
        _validateEscrowEnvelope(releaseEnvelope, msg.sender, auction.highestBidder, RELEASE_SELECTOR, auction.amount);
        _assertEscrowSolvent(escrowedTokenAmount);

        auction.status = Status.Settled;
        activeAuctionCount -= 1;
        escrowedTokenAmount -= auction.amount;
        claimableEth[auction.seller] += auction.highestBidWei;
        (uint256 vmEthSpent, uint256 vmEscrowBalance) =
            _runVM(releaseEnvelope, auction.vmEthAmount, sqrtPriceLimitX96, msg.sender);
        if (vmEscrowBalance != escrowedTokenAmount) revert EscrowInvariant(vmEscrowBalance, escrowedTokenAmount);
        _assertEscrowSolvent(escrowedTokenAmount);
        _assertSolvent();
        emit LotReleased(auctionId, auction.highestBidder, auction.amount, vmEthSpent);
        emit AuctionSettled(
            auctionId, auction.seller, auction.highestBidder, auction.amount, auction.highestBidWei, vmEthSpent
        );
    }

    function cancelAuction(
        uint256 auctionId,
        SwapVMKernel.VMEnvelope calldata releaseEnvelope,
        uint160 sqrtPriceLimitX96
    ) external payable nonReentrant {
        Auction storage auction = _auction(auctionId);
        if (auction.status != Status.Open) revert InvalidStatus(auctionId, Status.Open, auction.status);
        if (msg.sender != auction.seller) revert Unauthorized(auction.seller, msg.sender);
        if (auction.highestBidder != address(0)) revert BidAlreadyPlaced(auctionId);
        if (msg.value == 0 || msg.value > type(uint128).max) revert InvalidVMInput();
        _validateEscrowEnvelope(releaseEnvelope, auction.seller, auction.seller, RELEASE_SELECTOR, auction.amount);
        _assertEscrowSolvent(escrowedTokenAmount);

        auction.status = Status.Cancelled;
        activeAuctionCount -= 1;
        escrowedTokenAmount -= auction.amount;
        (uint256 vmEthSpent, uint256 vmEscrowBalance) =
            _runVM(releaseEnvelope, msg.value, sqrtPriceLimitX96, auction.seller);
        if (vmEscrowBalance != escrowedTokenAmount) revert EscrowInvariant(vmEscrowBalance, escrowedTokenAmount);
        _assertEscrowSolvent(escrowedTokenAmount);
        _assertSolvent();
        emit LotReleased(auctionId, auction.seller, auction.amount, vmEthSpent);
        emit AuctionCancelled(auctionId, auction.seller, auction.amount, vmEthSpent);
    }

    function withdrawEth() external nonReentrant {
        uint256 amount = claimableEth[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        claimableEth[msg.sender] = 0;
        lockedEth -= amount;
        _pay(msg.sender, amount);
        _assertSolvent();
        emit EthWithdrawn(msg.sender, amount);
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

    function _validateEscrowEnvelope(
        SwapVMKernel.VMEnvelope calldata envelope,
        address actor,
        address recipient,
        bytes4 selector,
        uint128 amount
    ) private view {
        if (
            envelope.op != SwapVMKernel.RootOp.CALL || envelope.worldId != worldId || envelope.actor != actor
                || envelope.targetOrCodeHash != escrow || envelope.recipient != recipient
                || envelope.authorizedExecutor != address(this)
        ) revert InvalidEnvelope();
        _validatePayload(envelope.payload, selector, kernel.eoaAccountId(recipient), amount);
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

    function _src20BalanceOfId(bytes32 account) private view returns (uint256 balance) {
        bytes memory payload = abi.encodePacked(BALANCE_OF_SELECTOR, abi.encode(account));
        (bytes memory output,) = kernel.staticCall(worldId, token, payload, 2_000);
        if (output.length != 32) revert InvalidBalanceRead(token, output.length);
        balance = abi.decode(output, (uint256));
    }

    function _openAuction(uint256 auctionId) private view returns (Auction storage auction) {
        auction = _auction(auctionId);
        if (auction.status != Status.Open) revert InvalidStatus(auctionId, Status.Open, auction.status);
        if (block.timestamp >= auction.endTime) revert AuctionEnded(auctionId);
    }

    function _auction(uint256 auctionId) private view returns (Auction storage auction) {
        auction = auctions[auctionId];
        if (auction.status == Status.None) revert InvalidAuction(auctionId);
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

    receive() external payable {
        if (msg.sender != address(router)) revert OnlyRouterRefund(msg.sender);
    }
}
