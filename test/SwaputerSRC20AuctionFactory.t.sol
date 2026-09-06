// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {SwapVMRouter} from "../src/SwapVMRouter.sol";
import {SwapVMSRC20AuctionHouse} from "../src/SwapVMSRC20AuctionHouse.sol";
import {SwapVMWorldFactory} from "../src/SwapVMWorldFactory.sol";
import {SwaputerSRC20AuctionFactory} from "../src/SwaputerSRC20AuctionFactory.sol";

contract AuctionFactoryKernelMock {
    mapping(bytes32 account => bytes32 codeHash) internal _codeHashes;
    mapping(bytes32 escrow => bytes32 token) internal _escrowTokens;
    mapping(bytes32 escrow => address auction) internal _escrowAuctions;
    mapping(bytes32 token => uint256 decimals) internal _tokenDecimals;

    function setCodeHash(bytes32 account, bytes32 codeHash) external {
        _codeHashes[account] = codeHash;
    }

    function setEscrowBindings(bytes32 escrow, bytes32 token, address auction) external {
        _escrowTokens[escrow] = token;
        _escrowAuctions[escrow] = auction;
    }

    function setDecimals(bytes32 token, uint256 decimals) external {
        _tokenDecimals[token] = decimals;
    }

    function programCodeHash(bytes32, bytes32 account) external view returns (bytes32) {
        return _codeHashes[account];
    }

    function staticCall(bytes32, bytes32 target, bytes calldata input, uint32)
        external
        view
        returns (bytes memory output, uint32 bytesUsed)
    {
        bytes4 selector = bytes4(input);
        if (selector == bytes4(keccak256("tokenAccount()"))) return (abi.encode(_escrowTokens[target]), 1);
        if (selector == bytes4(keccak256("trustedAuction()"))) return (abi.encode(_escrowAuctions[target]), 1);
        if (selector == bytes4(keccak256("decimals()"))) return (abi.encode(_tokenDecimals[target]), 1);
        return (bytes(""), 0);
    }
}

contract AuctionFactoryWorldMock {
    SwapVMWorldFactory.WorldConfig internal _config;
    address public router;

    constructor(address kernel) {
        _config.kernel = kernel;
        _config.isSealed = true;
    }

    function getWorldConfig(bytes32) external view returns (SwapVMWorldFactory.WorldConfig memory) {
        return _config;
    }

    function setRouter(address router_) external {
        router = router_;
    }
}

contract AuctionFactoryRouterMock {
    address public immutable factory;

    constructor(address worldFactory) {
        factory = worldFactory;
    }
}

contract SwaputerSRC20AuctionFactoryTest is Test {
    bytes32 internal constant WORLD = keccak256("swaputer.auction.factory.world");
    bytes32 internal constant TOKEN = bytes32(uint256(0x101));
    bytes32 internal constant TOKEN_CODE_HASH = keccak256("open-mint-src20");
    bytes32 internal constant ESCROW = bytes32(uint256(0x202));
    bytes32 internal constant ESCROW_CODE_HASH = keccak256("auction-escrow");

    AuctionFactoryKernelMock internal kernel;
    SwapVMRouter internal router;
    SwaputerSRC20AuctionFactory internal auctionFactory;

    function setUp() public {
        kernel = new AuctionFactoryKernelMock();
        AuctionFactoryWorldMock worldFactory = new AuctionFactoryWorldMock(address(kernel));
        router = SwapVMRouter(payable(address(new AuctionFactoryRouterMock(address(worldFactory)))));
        worldFactory.setRouter(address(router));
        auctionFactory = new SwaputerSRC20AuctionFactory(router, WORLD, ESCROW_CODE_HASH, TOKEN_CODE_HASH);
        kernel.setCodeHash(TOKEN, TOKEN_CODE_HASH);
        kernel.setCodeHash(ESCROW, ESCROW_CODE_HASH);
        kernel.setDecimals(TOKEN, 18);
    }

    function test_deploysDeterministicAuctionHouseForVerifiedEscrow() public {
        address predicted = auctionFactory.predictAuctionHouse(TOKEN, TOKEN_CODE_HASH, ESCROW);
        kernel.setEscrowBindings(ESCROW, TOKEN, predicted);

        vm.expectEmit(true, true, true, true);
        emit SwaputerSRC20AuctionFactory.AuctionHouseCreated(TOKEN, predicted, ESCROW, TOKEN_CODE_HASH, 1);
        address deployed = auctionFactory.createAuctionHouse(TOKEN, TOKEN_CODE_HASH, ESCROW);

        assertEq(deployed, predicted);
        assertEq(auctionFactory.auctionHouseFor(TOKEN), predicted);
        assertEq(auctionFactory.auctionHouseCount(), 1);
        assertEq(auctionFactory.tokenAt(1), TOKEN);
        SwapVMSRC20AuctionHouse auctionHouse = SwapVMSRC20AuctionHouse(payable(deployed));
        assertEq(address(auctionHouse.router()), address(router));
        assertEq(address(auctionHouse.kernel()), address(kernel));
        assertEq(auctionHouse.worldId(), WORLD);
        assertEq(auctionHouse.token(), TOKEN);
        assertEq(auctionHouse.tokenCodeHash(), TOKEN_CODE_HASH);
        assertEq(auctionHouse.escrow(), ESCROW);
    }

    function test_rejectsWrongEscrowBindings() public {
        address predicted = auctionFactory.predictAuctionHouse(TOKEN, TOKEN_CODE_HASH, ESCROW);
        kernel.setEscrowBindings(ESCROW, bytes32(uint256(0xBAD)), predicted);
        vm.expectPartialRevert(SwaputerSRC20AuctionFactory.EscrowBindingMismatch.selector);
        auctionFactory.createAuctionHouse(TOKEN, TOKEN_CODE_HASH, ESCROW);

        kernel.setEscrowBindings(ESCROW, TOKEN, address(0xBEEF));
        vm.expectPartialRevert(SwaputerSRC20AuctionFactory.EscrowBindingMismatch.selector);
        auctionFactory.createAuctionHouse(TOKEN, TOKEN_CODE_HASH, ESCROW);
    }

    function test_rejectsUnknownTokensAndDuplicateAuctionHouse() public {
        bytes32 unknown = bytes32(uint256(0x303));
        vm.expectRevert(SwaputerSRC20AuctionFactory.InvalidToken.selector);
        auctionFactory.createAuctionHouse(unknown, TOKEN_CODE_HASH, ESCROW);

        address predicted = auctionFactory.predictAuctionHouse(TOKEN, TOKEN_CODE_HASH, ESCROW);
        kernel.setEscrowBindings(ESCROW, TOKEN, predicted);
        auctionFactory.createAuctionHouse(TOKEN, TOKEN_CODE_HASH, ESCROW);
        vm.expectPartialRevert(SwaputerSRC20AuctionFactory.AuctionHouseExists.selector);
        auctionFactory.createAuctionHouse(TOKEN, TOKEN_CODE_HASH, ESCROW);
    }

    function test_rejectsUntrustedTokenCodeHash() public {
        bytes32 untrustedCodeHash = keccak256("malicious-src20");
        kernel.setCodeHash(TOKEN, untrustedCodeHash);
        vm.expectPartialRevert(SwaputerSRC20AuctionFactory.UntrustedTokenCodeHash.selector);
        auctionFactory.createAuctionHouse(TOKEN, untrustedCodeHash, ESCROW);
    }

    function test_rejectsRouterThatIsNotFactoryBound() public {
        AuctionFactoryWorldMock worldFactory = new AuctionFactoryWorldMock(address(kernel));
        SwapVMRouter rogueRouter = SwapVMRouter(payable(address(new AuctionFactoryRouterMock(address(worldFactory)))));
        worldFactory.setRouter(address(0xBEEF));

        vm.expectRevert(SwaputerSRC20AuctionFactory.InvalidRouter.selector);
        new SwaputerSRC20AuctionFactory(rogueRouter, WORLD, ESCROW_CODE_HASH, TOKEN_CODE_HASH);
    }
}
