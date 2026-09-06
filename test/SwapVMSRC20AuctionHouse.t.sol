// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {SwapVMCreationCodeStore} from "../src/SwapVMCreationCodeStore.sol";
import {SwapVMGasToken} from "../src/SwapVMGasToken.sol";
import {SwapVMHook} from "../src/SwapVMHook.sol";
import {SwapVMKernel} from "../src/SwapVMKernel.sol";
import {SwapVMRouter} from "../src/SwapVMRouter.sol";
import {SwapVMSRC20AuctionHouse} from "../src/SwapVMSRC20AuctionHouse.sol";
import {SwapVMWorldFactory} from "../src/SwapVMWorldFactory.sol";

contract AuctionContractBidder {}

contract SwapVMSRC20AuctionHouseTest is Test {
    using TransientStateLibrary for PoolManager;

    uint256 internal constant INITIAL_SUPPLY = 1e36;
    uint128 internal constant BYTE_GAS_PRICE = 1e12;
    uint24 internal constant POOL_FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    uint160 internal constant SQRT_PRICE_1_1 = 1 << 96;
    uint256 internal constant SELLER_KEY = 0xA11CE;
    uint256 internal constant BIDDER_ONE_KEY = 0xB0B;
    uint256 internal constant BIDDER_TWO_KEY = 0xCAFE;
    uint256 internal constant SRC_SUPPLY = 5_000 ether;
    uint128 internal constant LOT_AMOUNT = 1_000 ether;
    uint128 internal constant RESERVE_PRICE = 0.1 ether;
    uint128 internal constant SECOND_BID = 0.105 ether;
    uint128 internal constant VM_INPUT = 0.25 ether;
    uint32 internal constant TOKEN_LIMIT = 3_000;
    uint32 internal constant ESCROW_LIMIT = 8_000;
    bytes32 internal constant AUCTION_SALT = keccak256("SwapVMSRC20AuctionHouse.integration.test");

    PoolManager internal manager;
    SwapVMWorldFactory internal factory;
    SwapVMRouter internal router;
    SwapVMGasToken internal gasToken;
    SwapVMKernel internal kernel;
    PoolKey internal key;
    bytes32 internal worldId;
    address internal seller;
    address internal bidderOne;
    address internal bidderTwo;

    SwapVMSRC20AuctionHouse internal auctionHouse;
    bytes32 internal src20;
    bytes32 internal src20CodeHash;
    bytes32 internal escrow;
    bytes32 internal escrowCodeHash;

    receive() external payable {}

    function setUp() public {
        vm.deal(address(this), 1e30);
        seller = vm.addr(SELLER_KEY);
        bidderOne = vm.addr(BIDDER_ONE_KEY);
        bidderTwo = vm.addr(BIDDER_TWO_KEY);
        vm.deal(seller, 100 ether);
        vm.deal(bidderOne, 100 ether);
        vm.deal(bidderTwo, 100 ether);

        manager = new PoolManager(address(this));
        SwapVMCreationCodeStore kernelCodeStore = new SwapVMCreationCodeStore(type(SwapVMKernel).creationCode);
        SwapVMCreationCodeStore hookCodeStore = new SwapVMCreationCodeStore(type(SwapVMHook).creationCode);
        factory = new SwapVMWorldFactory(
            manager,
            address(manager).codehash,
            address(kernelCodeStore),
            address(hookCodeStore),
            address(0xFEE),
            address(0xC0FFEE),
            300
        );
        router = SwapVMRouter(payable(factory.router()));

        SwapVMWorldFactory.CreateWorldParams memory params = _worldParams(bytes32(uint256(1)), bytes32(uint256(2)));
        (worldId, gasToken, kernel,) = factory.createWorld(params);
        bool isSealed;
        (key, isSealed) = factory.getPoolKey(worldId);
        assertTrue(isSealed);

        PoolModifyLiquidityTest liquidityRouter = new PoolModifyLiquidityTest(manager);
        gasToken.approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity{value: 1e25}(
            key,
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e24, salt: bytes32(0)}),
            bytes("")
        );

        _deploySRC20AndAuctionHouse();
        _approveEscrow(2 * LOT_AMOUNT);
    }

    function test_completeEnglishAuctionEscrowsBidsAndSettlesAtomically() public {
        uint64 endTime = uint64(block.timestamp + 1 days);
        SwapVMKernel.VMEnvelope memory deposit =
            _signedEscrowDeposit(SELLER_KEY, seller, LOT_AMOUNT, _nonce(seller), VM_INPUT);
        vm.prank(seller);
        uint256 auctionId = auctionHouse.createAuction{value: VM_INPUT}(
            LOT_AMOUNT, RESERVE_PRICE, VM_INPUT, endTime, deposit, TickMath.MIN_SQRT_PRICE + 1
        );

        assertEq(_balanceOf(seller), SRC_SUPPLY - LOT_AMOUNT);
        assertEq(_balanceOfId(escrow), LOT_AMOUNT);
        assertEq(auctionHouse.escrowedTokenAmount(), LOT_AMOUNT);
        assertEq(auctionHouse.activeAuctionCount(), 1);
        assertTrue(auctionHouse.isEscrowSolvent());

        vm.prank(bidderOne);
        auctionHouse.bid{value: RESERVE_PRICE}(auctionId);
        assertEq(auctionHouse.lockedEth(), RESERVE_PRICE);
        assertEq(auctionHouse.minimumNextBid(auctionId), SECOND_BID);

        vm.prank(bidderTwo);
        auctionHouse.bid{value: SECOND_BID}(auctionId);
        assertEq(auctionHouse.claimableEth(bidderOne), RESERVE_PRICE);
        assertEq(auctionHouse.lockedEth(), RESERVE_PRICE + SECOND_BID);

        uint256 bidderOneBefore = bidderOne.balance;
        vm.prank(bidderOne);
        auctionHouse.withdrawEth();
        assertEq(bidderOne.balance, bidderOneBefore + RESERVE_PRICE);
        assertEq(auctionHouse.lockedEth(), SECOND_BID);

        vm.warp(endTime);
        SwapVMKernel.VMEnvelope memory release =
            _signedEscrowRelease(BIDDER_TWO_KEY, bidderTwo, bidderTwo, LOT_AMOUNT, _nonce(bidderTwo), VM_INPUT);
        vm.prank(bidderTwo);
        auctionHouse.settleAuction{value: VM_INPUT}(auctionId, release, TickMath.MIN_SQRT_PRICE + 1);

        SwapVMSRC20AuctionHouse.Auction memory auction = auctionHouse.getAuction(auctionId);
        assertEq(uint8(auction.status), uint8(SwapVMSRC20AuctionHouse.Status.Settled));
        assertEq(auction.highestBidder, bidderTwo);
        assertEq(auction.bidCount, 2);
        assertEq(_balanceOf(bidderTwo), LOT_AMOUNT);
        assertEq(_balanceOfId(escrow), 0);
        assertEq(auctionHouse.escrowedTokenAmount(), 0);
        assertEq(auctionHouse.activeAuctionCount(), 0);
        assertEq(auctionHouse.claimableEth(seller), SECOND_BID);
        assertEq(auctionHouse.lockedEth(), SECOND_BID);

        uint256 sellerBefore = seller.balance;
        vm.prank(seller);
        auctionHouse.withdrawEth();
        assertEq(seller.balance, sellerBefore + SECOND_BID);
        assertEq(auctionHouse.lockedEth(), 0);
        assertEq(address(auctionHouse).balance, 0);
        assertEq(manager.getNonzeroDeltaCount(), 0);
    }

    function test_contractAccountCannotBecomeHighestBidderAndReceiveUnspendableSRC20() public {
        uint256 auctionId = _createAuction(uint64(block.timestamp + 1 days));
        address contractBidder = address(new AuctionContractBidder());
        vm.deal(contractBidder, RESERVE_PRICE);

        vm.prank(contractBidder);
        vm.expectPartialRevert(SwapVMSRC20AuctionHouse.UnsupportedContractRecipient.selector);
        auctionHouse.bid{value: RESERVE_PRICE}(auctionId);

        assertEq(auctionHouse.lockedEth(), 0);
        assertEq(auctionHouse.getAuction(auctionId).highestBidder, address(0));
    }

    function test_sellerCanCancelOnlyBeforeFirstBid() public {
        uint64 endTime = uint64(block.timestamp + 1 days);
        uint256 auctionId = _createAuction(endTime);
        SwapVMKernel.VMEnvelope memory release =
            _signedEscrowRelease(SELLER_KEY, seller, seller, LOT_AMOUNT, _nonce(seller), VM_INPUT);
        vm.prank(seller);
        auctionHouse.cancelAuction{value: VM_INPUT}(auctionId, release, TickMath.MIN_SQRT_PRICE + 1);

        assertEq(uint8(auctionHouse.getAuction(auctionId).status), uint8(SwapVMSRC20AuctionHouse.Status.Cancelled));
        assertEq(_balanceOf(seller), SRC_SUPPLY);
        assertEq(_balanceOfId(escrow), 0);

        uint256 secondAuctionId = _createAuction(uint64(block.timestamp + 1 days));
        vm.prank(bidderOne);
        auctionHouse.bid{value: RESERVE_PRICE}(secondAuctionId);
        SwapVMKernel.VMEnvelope memory secondRelease =
            _signedEscrowRelease(SELLER_KEY, seller, seller, LOT_AMOUNT, _nonce(seller), VM_INPUT);
        vm.prank(seller);
        vm.expectPartialRevert(SwapVMSRC20AuctionHouse.BidAlreadyPlaced.selector);
        auctionHouse.cancelAuction{value: VM_INPUT}(secondAuctionId, secondRelease, TickMath.MIN_SQRT_PRICE + 1);
    }

    function test_enforcesReserveIncrementDeadlineAndPermissionlessSettlement() public {
        uint64 endTime = uint64(block.timestamp + 1 days);
        uint256 auctionId = _createAuction(endTime);

        vm.prank(bidderOne);
        vm.expectPartialRevert(SwapVMSRC20AuctionHouse.BidTooLow.selector);
        auctionHouse.bid{value: RESERVE_PRICE - 1}(auctionId);

        vm.prank(bidderOne);
        auctionHouse.bid{value: RESERVE_PRICE}(auctionId);

        vm.prank(bidderTwo);
        vm.expectPartialRevert(SwapVMSRC20AuctionHouse.BidTooLow.selector);
        auctionHouse.bid{value: SECOND_BID - 1}(auctionId);

        SwapVMKernel.VMEnvelope memory earlyRelease =
            _signedEscrowRelease(BIDDER_ONE_KEY, bidderOne, bidderOne, LOT_AMOUNT, _nonce(bidderOne), VM_INPUT);
        vm.prank(bidderOne);
        vm.expectPartialRevert(SwapVMSRC20AuctionHouse.AuctionStillRunning.selector);
        auctionHouse.settleAuction{value: VM_INPUT}(auctionId, earlyRelease, TickMath.MIN_SQRT_PRICE + 1);

        vm.warp(endTime);
        SwapVMKernel.VMEnvelope memory permissionlessRelease =
            _signedEscrowRelease(BIDDER_TWO_KEY, bidderTwo, bidderOne, LOT_AMOUNT, _nonce(bidderTwo), VM_INPUT);
        vm.prank(bidderTwo);
        auctionHouse.settleAuction{value: VM_INPUT}(auctionId, permissionlessRelease, TickMath.MIN_SQRT_PRICE + 1);

        assertEq(_balanceOf(bidderOne), LOT_AMOUNT);
        assertEq(auctionHouse.claimableEth(seller), RESERVE_PRICE);

        vm.prank(bidderTwo);
        vm.expectPartialRevert(SwapVMSRC20AuctionHouse.InvalidStatus.selector);
        auctionHouse.bid{value: SECOND_BID}(auctionId);
    }

    function test_rejectsRedirectedEscrowPayload() public {
        bytes memory wrongPayload = abi.encodePacked(
            bytes4(keccak256("deposit(bytes32,uint256)")), abi.encode(kernel.eoaAccountId(bidderOne), LOT_AMOUNT)
        );
        SwapVMKernel.VMEnvelope memory wrongDeposit = _signedEnvelope(
            SELLER_KEY,
            seller,
            SwapVMKernel.RootOp.CALL,
            escrow,
            wrongPayload,
            ESCROW_LIMIT,
            _nonce(seller),
            seller,
            VM_INPUT,
            address(auctionHouse)
        );
        vm.prank(seller);
        vm.expectRevert(SwapVMSRC20AuctionHouse.InvalidTransferPayload.selector);
        auctionHouse.createAuction{value: VM_INPUT}(
            LOT_AMOUNT,
            RESERVE_PRICE,
            VM_INPUT,
            uint64(block.timestamp + 1 days),
            wrongDeposit,
            TickMath.MIN_SQRT_PRICE + 1
        );
        assertEq(_balanceOf(seller), SRC_SUPPLY);
        assertEq(_balanceOfId(escrow), 0);
        assertEq(auctionHouse.auctionCount(), 0);
    }

    function _createAuction(uint64 endTime) private returns (uint256 auctionId) {
        SwapVMKernel.VMEnvelope memory deposit =
            _signedEscrowDeposit(SELLER_KEY, seller, LOT_AMOUNT, _nonce(seller), VM_INPUT);
        vm.prank(seller);
        auctionId = auctionHouse.createAuction{value: VM_INPUT}(
            LOT_AMOUNT, RESERVE_PRICE, VM_INPUT, endTime, deposit, TickMath.MIN_SQRT_PRICE + 1
        );
    }

    function _deploySRC20AndAuctionHouse() private {
        bytes32 sellerId = kernel.eoaAccountId(seller);
        bytes memory src20Package = vm.readFileBinary("tooling/tinysol/programs/mintable-src20/MintableSRC20.svm");
        src20CodeHash = keccak256(src20Package);
        src20 = kernel.contractAccountId(worldId, sellerId, kernel.creatorNonce(worldId, sellerId), src20CodeHash);
        _buyVM(
            seller,
            _signedEnvelope(
                SELLER_KEY,
                seller,
                SwapVMKernel.RootOp.DEPLOY,
                src20CodeHash,
                abi.encodePacked(bytes4(uint32(src20Package.length)), src20Package),
                10_000,
                _nonce(seller),
                seller,
                VM_INPUT,
                address(0)
            ),
            VM_INPUT
        );

        bytes memory mintPayload = abi.encodePacked(bytes4(keccak256("mint(bytes32)")), abi.encode(sellerId));
        for (uint256 i; i < SRC_SUPPLY / (1_000 ether); ++i) {
            _buyVM(
                seller,
                _signedEnvelope(
                    SELLER_KEY,
                    seller,
                    SwapVMKernel.RootOp.CALL,
                    src20,
                    mintPayload,
                    TOKEN_LIMIT,
                    _nonce(seller),
                    seller,
                    VM_INPUT,
                    address(0)
                ),
                VM_INPUT
            );
        }
        assertEq(_balanceOf(seller), SRC_SUPPLY);

        bytes memory escrowPackage = vm.readFileBinary("tooling/tinysol/programs/auction-escrow/AuctionEscrow.svm");
        escrowCodeHash = keccak256(escrowPackage);
        escrow = kernel.contractAccountId(worldId, sellerId, kernel.creatorNonce(worldId, sellerId), escrowCodeHash);
        bytes memory initCode = abi.encodePacked(
            type(SwapVMSRC20AuctionHouse).creationCode,
            abi.encode(router, worldId, src20, src20CodeHash, escrow, escrowCodeHash)
        );
        address predicted = vm.computeCreate2Address(AUCTION_SALT, keccak256(initCode), address(this));
        _buyVM(
            seller,
            _signedEnvelope(
                SELLER_KEY,
                seller,
                SwapVMKernel.RootOp.DEPLOY,
                escrowCodeHash,
                abi.encodePacked(bytes4(uint32(escrowPackage.length)), escrowPackage, abi.encode(src20, predicted)),
                10_000,
                _nonce(seller),
                seller,
                VM_INPUT,
                address(0)
            ),
            VM_INPUT
        );
        auctionHouse = new SwapVMSRC20AuctionHouse{salt: AUCTION_SALT}(
            router, worldId, src20, src20CodeHash, escrow, escrowCodeHash
        );
        assertEq(address(auctionHouse), predicted);
    }

    function _approveEscrow(uint256 amount) private {
        bytes memory payload =
            abi.encodePacked(bytes4(keccak256("approve(bytes32,uint256)")), abi.encode(escrow, amount));
        _buyVM(
            seller,
            _signedEnvelope(
                SELLER_KEY,
                seller,
                SwapVMKernel.RootOp.CALL,
                src20,
                payload,
                TOKEN_LIMIT,
                _nonce(seller),
                seller,
                VM_INPUT,
                address(0)
            ),
            VM_INPUT
        );
    }

    function _signedEscrowDeposit(uint256 key_, address actor, uint128 amount, uint64 nonce, uint128 ethIn)
        private
        view
        returns (SwapVMKernel.VMEnvelope memory action)
    {
        bytes memory payload = abi.encodePacked(
            bytes4(keccak256("deposit(bytes32,uint256)")), abi.encode(kernel.eoaAccountId(actor), amount)
        );
        action = _signedEnvelope(
            key_,
            actor,
            SwapVMKernel.RootOp.CALL,
            escrow,
            payload,
            ESCROW_LIMIT,
            nonce,
            actor,
            ethIn,
            address(auctionHouse)
        );
    }

    function _signedEscrowRelease(
        uint256 key_,
        address actor,
        address recipient,
        uint128 amount,
        uint64 nonce,
        uint128 ethIn
    ) private view returns (SwapVMKernel.VMEnvelope memory action) {
        bytes memory payload = abi.encodePacked(
            bytes4(keccak256("release(bytes32,uint256)")), abi.encode(kernel.eoaAccountId(recipient), amount)
        );
        action = _signedEnvelope(
            key_,
            actor,
            SwapVMKernel.RootOp.CALL,
            escrow,
            payload,
            ESCROW_LIMIT,
            nonce,
            recipient,
            ethIn,
            address(auctionHouse)
        );
    }

    function _signedEnvelope(
        uint256 key_,
        address actor,
        SwapVMKernel.RootOp op,
        bytes32 target,
        bytes memory payload,
        uint32 limit,
        uint64 nonce,
        address recipient,
        uint128 ethIn,
        address executor
    ) private view returns (SwapVMKernel.VMEnvelope memory action) {
        action = SwapVMKernel.VMEnvelope({
            op: op,
            worldId: worldId,
            actor: actor,
            targetOrCodeHash: target,
            payload: payload,
            byteGasLimit: limit,
            minNetTokenOut: 1,
            nonce: nonce,
            deadline: uint64(block.timestamp + 1 days),
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
                uint160(TickMath.MIN_SQRT_PRICE + 1),
                action.recipient,
                address(router),
                action.authorizedExecutor,
                action.nonce,
                action.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", kernel.domainSeparator(worldId), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key_, digest);
        action.signature = abi.encodePacked(r, s, v);
    }

    function _buyVM(address caller, SwapVMKernel.VMEnvelope memory action, uint128 ethIn) private {
        vm.prank(caller);
        router.buyVMExactInput{value: ethIn}(worldId, TickMath.MIN_SQRT_PRICE + 1, action);
    }

    function _worldParams(bytes32 tokenSalt, bytes32 bootstrapSalt)
        private
        view
        returns (SwapVMWorldFactory.CreateWorldParams memory params)
    {
        address predictedToken = factory.predictGasToken(tokenSalt, INITIAL_SUPPLY, address(this));
        address predictedWorldDeployer = factory.predictWorldDeployer(bootstrapSalt);
        address predictedKernel = factory.predictKernel(predictedWorldDeployer);
        bytes memory hookArgs = abi.encode(
            manager,
            SwapVMKernel(predictedKernel),
            predictedToken,
            factory.initialProtocolFeeAdmin(),
            factory.feeController(),
            factory.initialProtocolFeeBps(),
            BYTE_GAS_PRICE,
            POOL_FEE,
            TICK_SPACING
        );
        (address predictedHook, bytes32 hookSalt) = HookMiner.find(
            predictedWorldDeployer,
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG,
            type(SwapVMHook).creationCode,
            hookArgs
        );
        params = SwapVMWorldFactory.CreateWorldParams({
            tokenSalt: tokenSalt,
            bootstrapSalt: bootstrapSalt,
            hookSalt: hookSalt,
            predictedKernel: predictedKernel,
            predictedHook: predictedHook,
            initialSupply: INITIAL_SUPPLY,
            initialHolder: address(this),
            distributionCommitment: keccak256("src20-auction-test-distribution"),
            byteGasPrice: BYTE_GAS_PRICE,
            poolFee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            initialSqrtPriceX96: SQRT_PRICE_1_1
        });
    }

    function _nonce(address account) private view returns (uint64) {
        return kernel.nonces(worldId, kernel.eoaAccountId(account));
    }

    function _balanceOf(address account) private view returns (uint256) {
        return _balanceOfId(kernel.eoaAccountId(account));
    }

    function _balanceOfId(bytes32 account) private view returns (uint256) {
        (bytes memory output,) = kernel.staticCall(
            worldId, src20, abi.encodePacked(bytes4(keccak256("balanceOf(bytes32)")), abi.encode(account)), 2_000
        );
        assertEq(output.length, 32);
        return abi.decode(output, (uint256));
    }
}
