// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {SwapVMRouter} from "../src/SwapVMRouter.sol";
import {SwapVMSRC20Market} from "../src/SwapVMSRC20Market.sol";
import {SwapVMWorldFactory} from "../src/SwapVMWorldFactory.sol";
import {SwaputerSRC20MarketFactory} from "../src/SwaputerSRC20MarketFactory.sol";

contract MarketFactoryKernelMock {
    mapping(bytes32 account => bytes32 codeHash) internal _codeHashes;
    mapping(bytes32 escrow => bytes32 token) internal _escrowTokens;
    mapping(bytes32 escrow => address market) internal _escrowMarkets;
    mapping(bytes32 token => uint256 decimals) internal _tokenDecimals;

    function setCodeHash(bytes32 account, bytes32 codeHash) external {
        _codeHashes[account] = codeHash;
    }

    function setEscrowBindings(bytes32 escrow, bytes32 token, address market) external {
        _escrowTokens[escrow] = token;
        _escrowMarkets[escrow] = market;
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
        if (selector == bytes4(keccak256("trustedMarket()"))) return (abi.encode(_escrowMarkets[target]), 1);
        if (selector == bytes4(keccak256("decimals()"))) return (abi.encode(_tokenDecimals[target]), 1);
        return (bytes(""), 0);
    }
}

contract MarketFactoryWorldMock {
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

contract MarketFactoryRouterMock {
    address public immutable factory;

    constructor(address worldFactory) {
        factory = worldFactory;
    }
}

contract SwaputerSRC20MarketFactoryTest is Test {
    bytes32 internal constant WORLD = keccak256("swaputer.market.factory.world");
    bytes32 internal constant TOKEN = bytes32(uint256(0x101));
    bytes32 internal constant TOKEN_CODE_HASH = keccak256("open-mint-src20");
    bytes32 internal constant ESCROW = bytes32(uint256(0x202));
    bytes32 internal constant ESCROW_CODE_HASH = keccak256("market-escrow");

    MarketFactoryKernelMock internal kernel;
    SwapVMRouter internal router;
    SwaputerSRC20MarketFactory internal marketFactory;

    function setUp() public {
        kernel = new MarketFactoryKernelMock();
        MarketFactoryWorldMock worldFactory = new MarketFactoryWorldMock(address(kernel));
        router = SwapVMRouter(payable(address(new MarketFactoryRouterMock(address(worldFactory)))));
        worldFactory.setRouter(address(router));
        marketFactory = new SwaputerSRC20MarketFactory(router, WORLD, ESCROW_CODE_HASH, TOKEN_CODE_HASH);
        kernel.setCodeHash(TOKEN, TOKEN_CODE_HASH);
        kernel.setCodeHash(ESCROW, ESCROW_CODE_HASH);
        kernel.setDecimals(TOKEN, 18);
    }

    function test_deploysDeterministicMarketForVerifiedEscrowBindings() public {
        address predicted = marketFactory.predictMarket(TOKEN, TOKEN_CODE_HASH, ESCROW);
        kernel.setEscrowBindings(ESCROW, TOKEN, predicted);

        vm.expectEmit(true, true, true, true);
        emit SwaputerSRC20MarketFactory.MarketCreated(TOKEN, predicted, ESCROW, TOKEN_CODE_HASH, 1);
        address deployed = marketFactory.createMarket(TOKEN, TOKEN_CODE_HASH, ESCROW);

        assertEq(deployed, predicted);
        assertEq(marketFactory.marketFor(TOKEN), predicted);
        assertEq(marketFactory.marketCount(), 1);
        assertEq(marketFactory.tokenAt(1), TOKEN);
        SwapVMSRC20Market market = SwapVMSRC20Market(payable(deployed));
        assertEq(address(market.router()), address(router));
        assertEq(address(market.kernel()), address(kernel));
        assertEq(market.worldId(), WORLD);
        assertEq(market.token(), TOKEN);
        assertEq(market.tokenCodeHash(), TOKEN_CODE_HASH);
        assertEq(market.escrow(), ESCROW);
    }

    function test_rejectsWrongEscrowTokenOrTrustedMarket() public {
        address predicted = marketFactory.predictMarket(TOKEN, TOKEN_CODE_HASH, ESCROW);
        kernel.setEscrowBindings(ESCROW, bytes32(uint256(0xBAD)), predicted);
        vm.expectPartialRevert(SwaputerSRC20MarketFactory.EscrowBindingMismatch.selector);
        marketFactory.createMarket(TOKEN, TOKEN_CODE_HASH, ESCROW);

        kernel.setEscrowBindings(ESCROW, TOKEN, address(0xBEEF));
        vm.expectPartialRevert(SwaputerSRC20MarketFactory.EscrowBindingMismatch.selector);
        marketFactory.createMarket(TOKEN, TOKEN_CODE_HASH, ESCROW);
    }

    function test_rejectsUnknownProgramsAndDuplicateMarket() public {
        bytes32 unknown = bytes32(uint256(0x303));
        vm.expectRevert(SwaputerSRC20MarketFactory.InvalidToken.selector);
        marketFactory.createMarket(unknown, TOKEN_CODE_HASH, ESCROW);

        address predicted = marketFactory.predictMarket(TOKEN, TOKEN_CODE_HASH, ESCROW);
        kernel.setEscrowBindings(ESCROW, TOKEN, predicted);
        marketFactory.createMarket(TOKEN, TOKEN_CODE_HASH, ESCROW);
        vm.expectPartialRevert(SwaputerSRC20MarketFactory.MarketExists.selector);
        marketFactory.createMarket(TOKEN, TOKEN_CODE_HASH, ESCROW);
    }

    function test_rejectsUntrustedTokenCodeHash() public {
        bytes32 untrustedCodeHash = keccak256("malicious-src20");
        kernel.setCodeHash(TOKEN, untrustedCodeHash);
        vm.expectPartialRevert(SwaputerSRC20MarketFactory.UntrustedTokenCodeHash.selector);
        marketFactory.createMarket(TOKEN, untrustedCodeHash, ESCROW);
    }

    function test_marketQuotesUsingVerifiedTokenDecimals() public {
        kernel.setDecimals(TOKEN, 6);
        address predicted = marketFactory.predictMarket(TOKEN, TOKEN_CODE_HASH, ESCROW);
        kernel.setEscrowBindings(ESCROW, TOKEN, predicted);

        SwapVMSRC20Market deployed =
            SwapVMSRC20Market(payable(marketFactory.createMarket(TOKEN, TOKEN_CODE_HASH, ESCROW)));

        assertEq(deployed.tokenScale(), 1e6);
        assertEq(deployed.quotePrice(1e6, 1 ether), 1 ether);
    }

    function test_rejectsTokenDecimalsThatDoNotFitUint128Amounts() public {
        kernel.setDecimals(TOKEN, 39);
        address predicted = marketFactory.predictMarket(TOKEN, TOKEN_CODE_HASH, ESCROW);
        kernel.setEscrowBindings(ESCROW, TOKEN, predicted);

        vm.expectPartialRevert(SwapVMSRC20Market.InvalidTokenDecimals.selector);
        marketFactory.createMarket(TOKEN, TOKEN_CODE_HASH, ESCROW);
    }

    function test_rejectsRouterThatIsNotFactoryBound() public {
        MarketFactoryWorldMock worldFactory = new MarketFactoryWorldMock(address(kernel));
        SwapVMRouter rogueRouter = SwapVMRouter(payable(address(new MarketFactoryRouterMock(address(worldFactory)))));
        worldFactory.setRouter(address(0xBEEF));

        vm.expectRevert(SwaputerSRC20MarketFactory.InvalidRouter.selector);
        new SwaputerSRC20MarketFactory(rogueRouter, WORLD, ESCROW_CODE_HASH, TOKEN_CODE_HASH);
    }
}
