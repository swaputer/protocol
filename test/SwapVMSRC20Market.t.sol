// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {SwaputerCreationCodeStore} from "../src/SwaputerCreationCodeStore.sol";
import {SwaputerToken} from "../src/SwaputerToken.sol";
import {SwaputerHook} from "../src/SwaputerHook.sol";
import {SwaputerKernel} from "../src/SwaputerKernel.sol";
import {SwaputerAppRouter} from "../src/SwaputerAppRouter.sol";
import {SwapVMSRC20Market} from "../src/SwapVMSRC20Market.sol";
import {SwaputerWorldFactory} from "../src/SwaputerWorldFactory.sol";

contract MarketContractRecipient {}

contract SwapVMSRC20MarketTest is Test {
    using TransientStateLibrary for PoolManager;

    uint256 internal constant INITIAL_SUPPLY = 1e36;
    uint128 internal constant BYTE_GAS_PRICE = 1e12;
    uint24 internal constant POOL_FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    uint160 internal constant SQRT_PRICE_1_1 = 1 << 96;
    uint256 internal constant ACTOR_KEY = 0xA11CE;
    uint256 internal constant BUYER_KEY = 0xB0B;
    uint256 internal constant TOKEN_UNIT = 1 ether;
    uint256 internal constant SRC_SUPPLY = 5_000 * TOKEN_UNIT;
    uint128 internal constant ORDER_AMOUNT = 1_000 ether;
    uint128 internal constant UNIT_PRICE = 0.00001 ether;
    uint128 internal constant ORDER_PRICE = 0.01 ether;
    uint128 internal constant VM_INPUT = 0.25 ether;
    uint32 internal constant TOKEN_LIMIT = 3_000;
    uint32 internal constant ESCROW_LIMIT = 8_000;
    bytes32 internal constant MARKET_SALT = keccak256("SwapVMSRC20Market.complete-escrow.test");

    PoolManager internal manager;
    SwaputerWorldFactory internal factory;
    SwaputerAppRouter internal router;
    SwaputerToken internal gasToken;
    SwaputerKernel internal kernel;
    PoolKey internal key;
    bytes32 internal worldId;
    address internal actor;
    address internal buyer;

    SwapVMSRC20Market internal market;
    bytes32 internal src20;
    bytes32 internal src20CodeHash;
    bytes32 internal escrow;

    receive() external payable {}
    bytes32 internal escrowCodeHash;

    function setUp() public virtual {
        vm.deal(address(this), 1e30);
        actor = vm.addr(ACTOR_KEY);
        buyer = vm.addr(BUYER_KEY);
        vm.deal(actor, 100 ether);
        vm.deal(buyer, 100 ether);

        manager = new PoolManager(address(this));
        SwaputerCreationCodeStore kernelCodeStore = new SwaputerCreationCodeStore(type(SwaputerKernel).creationCode);
        SwaputerCreationCodeStore hookCodeStore = new SwaputerCreationCodeStore(type(SwaputerHook).creationCode);
        factory = new SwaputerWorldFactory(
            manager,
            address(manager).codehash,
            address(kernelCodeStore),
            address(hookCodeStore),
            address(0xFEE),
            address(0xC0FFEE)
        );
        router = SwaputerAppRouter(payable(factory.router()));

        SwaputerWorldFactory.CreateWorldParams memory params = _worldParams(bytes32(uint256(1)), bytes32(uint256(2)));
        SwaputerHook hook;
        (worldId, gasToken, kernel, hook) = factory.createWorld(params);
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
        vm.prank(address(0xFEE));
        hook.live();

        _deploySRC20AndEscrowMarket();
        _approveEscrow(2 * ORDER_AMOUNT);
    }

    function test_buyOrderLocksEthAndAnyHolderCanFillAtomically() public {
        uint256 buyerEthBefore = buyer.balance;
        uint256 sellerEthBefore = actor.balance;

        vm.prank(buyer);
        uint256 orderId = market.createBuyOrder{value: ORDER_PRICE + VM_INPUT}(
            ORDER_AMOUNT, UNIT_PRICE, VM_INPUT, uint64(block.timestamp + 1 days)
        );

        assertEq(market.lockedEth(), ORDER_PRICE + VM_INPUT);
        assertEq(address(market).balance, ORDER_PRICE + VM_INPUT);

        SwaputerKernel.VMEnvelope memory transfer =
            _signedTransfer(ACTOR_KEY, actor, buyer, ORDER_AMOUNT, _nonce(actor), VM_INPUT);
        vm.prank(actor);
        market.fillBuyOrder(orderId, transfer, TickMath.MIN_SQRT_PRICE + 1);

        SwapVMSRC20Market.Order memory order = market.getOrder(orderId);
        assertEq(uint8(order.side), uint8(SwapVMSRC20Market.Side.Buy));
        assertEq(uint8(order.status), uint8(SwapVMSRC20Market.Status.Filled));
        assertEq(order.maker, buyer);
        assertEq(order.taker, actor);
        assertEq(_balanceOf(actor), SRC_SUPPLY - ORDER_AMOUNT);
        assertEq(_balanceOf(buyer), ORDER_AMOUNT);
        assertEq(actor.balance, sellerEthBefore + ORDER_PRICE);
        assertEq(buyer.balance, buyerEthBefore - ORDER_PRICE - VM_INPUT);
        assertEq(market.lockedEth(), 0);
        assertEq(address(market).balance, 0);
        assertEq(manager.getNonzeroDeltaCount(), 0);
    }

    function test_contractAccountCannotCreateBuyOrderThatWouldReceiveUnspendableSRC20() public {
        address contractBuyer = address(new MarketContractRecipient());
        vm.deal(contractBuyer, ORDER_PRICE + VM_INPUT);

        vm.prank(contractBuyer);
        vm.expectPartialRevert(SwapVMSRC20Market.UnsupportedContractRecipient.selector);
        market.createBuyOrder{value: ORDER_PRICE + VM_INPUT}(
            ORDER_AMOUNT, UNIT_PRICE, VM_INPUT, uint64(block.timestamp + 1 days)
        );

        assertEq(market.orderCount(), 0);
        assertEq(address(market).balance, 0);
    }

    function test_sellOrderEscrowsSrc20AndBuyerFillsAtomically() public {
        uint256 sellerEthBefore = actor.balance;

        SwaputerKernel.VMEnvelope memory deposit =
            _signedEscrowDeposit(ACTOR_KEY, actor, ORDER_AMOUNT, _nonce(actor), VM_INPUT);
        vm.prank(actor);
        uint256 orderId = market.createSellOrder{value: VM_INPUT}(
            ORDER_AMOUNT, UNIT_PRICE, VM_INPUT, uint64(block.timestamp + 1 days), deposit, TickMath.MIN_SQRT_PRICE + 1
        );

        assertEq(actor.balance, sellerEthBefore - VM_INPUT);
        assertEq(_balanceOf(actor), SRC_SUPPLY - ORDER_AMOUNT);
        assertEq(_balanceOfId(escrow), ORDER_AMOUNT);
        assertEq(market.escrowedTokenAmount(), ORDER_AMOUNT);
        assertEq(market.activeSellAmount(actor), ORDER_AMOUNT);
        assertEq(market.lockedEth(), 0);
        assertEq(address(market).balance, 0);

        uint256 buyerEthBefore = buyer.balance;
        uint256 sellerEthBeforeFill = actor.balance;
        SwaputerKernel.VMEnvelope memory release =
            _signedEscrowRelease(BUYER_KEY, buyer, buyer, ORDER_AMOUNT, _nonce(buyer), VM_INPUT);

        vm.prank(buyer);
        market.settleSellOrder{value: ORDER_PRICE + VM_INPUT}(orderId, release, TickMath.MIN_SQRT_PRICE + 1);

        SwapVMSRC20Market.Order memory order = market.getOrder(orderId);
        assertEq(uint8(order.side), uint8(SwapVMSRC20Market.Side.Sell));
        assertEq(uint8(order.status), uint8(SwapVMSRC20Market.Status.Filled));
        assertEq(order.maker, actor);
        assertEq(order.taker, buyer);
        assertEq(_balanceOf(actor), SRC_SUPPLY - ORDER_AMOUNT);
        assertEq(_balanceOf(buyer), ORDER_AMOUNT);
        assertEq(_balanceOfId(escrow), 0);
        assertEq(actor.balance, sellerEthBeforeFill + ORDER_PRICE);
        assertEq(buyer.balance, buyerEthBefore - ORDER_PRICE - VM_INPUT);
        assertEq(market.escrowedTokenAmount(), 0);
        assertEq(market.activeSellAmount(actor), 0);
        assertEq(address(market).balance, 0);
        assertEq(manager.getNonzeroDeltaCount(), 0);
    }

    function test_sellOrderCancelReleasesEscrowToSeller() public {
        SwaputerKernel.VMEnvelope memory deposit =
            _signedEscrowDeposit(ACTOR_KEY, actor, ORDER_AMOUNT, _nonce(actor), VM_INPUT);
        vm.prank(actor);
        uint256 orderId = market.createSellOrder{value: VM_INPUT}(
            ORDER_AMOUNT, UNIT_PRICE, VM_INPUT, uint64(block.timestamp + 1 days), deposit, TickMath.MIN_SQRT_PRICE + 1
        );

        SwaputerKernel.VMEnvelope memory release =
            _signedEscrowRelease(ACTOR_KEY, actor, actor, ORDER_AMOUNT, _nonce(actor), VM_INPUT);
        vm.prank(actor);
        market.cancelSellOrder{value: VM_INPUT}(orderId, release, TickMath.MIN_SQRT_PRICE + 1);

        SwapVMSRC20Market.Order memory order = market.getOrder(orderId);
        assertEq(uint8(order.status), uint8(SwapVMSRC20Market.Status.Cancelled));
        assertEq(_balanceOf(actor), SRC_SUPPLY);
        assertEq(_balanceOfId(escrow), 0);
        assertEq(market.escrowedTokenAmount(), 0);
        assertEq(market.activeSellAmount(actor), 0);
        assertEq(address(market).balance, 0);
        assertEq(manager.getNonzeroDeltaCount(), 0);
    }

    function test_directTokenDonationCannotFreezeEscrowAccounting() public {
        uint128 donation = 1 ether;
        bytes memory donationPayload =
            abi.encodePacked(bytes4(keccak256("transfer(bytes32,uint256)")), abi.encode(escrow, donation));
        _buyVM(
            actor,
            _signedEnvelopeWithExecutor(
                ACTOR_KEY,
                actor,
                SwaputerKernel.RootOp.CALL,
                src20,
                donationPayload,
                TOKEN_LIMIT,
                _nonce(actor),
                actor,
                VM_INPUT,
                address(0)
            ),
            VM_INPUT
        );
        assertEq(_balanceOfId(escrow), donation);

        SwaputerKernel.VMEnvelope memory deposit =
            _signedEscrowDeposit(ACTOR_KEY, actor, ORDER_AMOUNT, _nonce(actor), VM_INPUT);
        vm.prank(actor);
        uint256 orderId = market.createSellOrder{value: VM_INPUT}(
            ORDER_AMOUNT, UNIT_PRICE, VM_INPUT, uint64(block.timestamp + 1 days), deposit, TickMath.MIN_SQRT_PRICE + 1
        );

        assertEq(_balanceOfId(escrow), donation + ORDER_AMOUNT);
        assertEq(market.escrowedTokenAmount(), ORDER_AMOUNT);
        assertTrue(market.isSellOrderSolvent(orderId));

        SwaputerKernel.VMEnvelope memory release =
            _signedEscrowRelease(ACTOR_KEY, actor, actor, ORDER_AMOUNT, _nonce(actor), VM_INPUT);
        vm.prank(actor);
        market.cancelSellOrder{value: VM_INPUT}(orderId, release, TickMath.MIN_SQRT_PRICE + 1);

        assertEq(_balanceOfId(escrow), donation);
        assertEq(market.escrowedTokenAmount(), 0);
    }

    function test_sellOrderWithoutEnoughAllowanceRollsBack() public {
        uint128 tooMuch = 3_000 ether;
        uint64 nonceBefore = _nonce(actor);
        uint256 balanceBefore = _balanceOf(actor);
        SwaputerKernel.VMEnvelope memory deposit =
            _signedEscrowDeposit(ACTOR_KEY, actor, tooMuch, nonceBefore, VM_INPUT);

        vm.prank(actor);
        vm.expectRevert();
        market.createSellOrder{value: VM_INPUT}(
            tooMuch, UNIT_PRICE, VM_INPUT, uint64(block.timestamp + 1 days), deposit, TickMath.MIN_SQRT_PRICE + 1
        );

        assertEq(_nonce(actor), nonceBefore);
        assertEq(_balanceOf(actor), balanceBefore);
        assertEq(_balanceOfId(escrow), 0);
        assertEq(market.orderCount(), 0);
        assertEq(market.escrowedTokenAmount(), 0);
        assertEq(address(market).balance, 0);
    }

    function test_sellOrderRejectsPayloadRedirection() public {
        bytes memory wrongDepositPayload = abi.encodePacked(
            bytes4(keccak256("deposit(bytes32,uint256)")), abi.encode(kernel.eoaAccountId(buyer), ORDER_AMOUNT)
        );
        SwaputerKernel.VMEnvelope memory wrongDeposit = _signedEnvelope(
            ACTOR_KEY,
            actor,
            SwaputerKernel.RootOp.CALL,
            escrow,
            wrongDepositPayload,
            ESCROW_LIMIT,
            _nonce(actor),
            actor,
            VM_INPUT
        );
        vm.prank(actor);
        vm.expectRevert(SwapVMSRC20Market.InvalidTransferPayload.selector);
        market.createSellOrder{value: VM_INPUT}(
            ORDER_AMOUNT,
            UNIT_PRICE,
            VM_INPUT,
            uint64(block.timestamp + 1 days),
            wrongDeposit,
            TickMath.MIN_SQRT_PRICE + 1
        );

        SwaputerKernel.VMEnvelope memory deposit =
            _signedEscrowDeposit(ACTOR_KEY, actor, ORDER_AMOUNT, _nonce(actor), VM_INPUT);
        vm.prank(actor);
        uint256 orderId = market.createSellOrder{value: VM_INPUT}(
            ORDER_AMOUNT, UNIT_PRICE, VM_INPUT, uint64(block.timestamp + 1 days), deposit, TickMath.MIN_SQRT_PRICE + 1
        );

        SwaputerKernel.VMEnvelope memory wrongRelease =
            _signedEscrowRelease(BUYER_KEY, buyer, actor, ORDER_AMOUNT, _nonce(buyer), VM_INPUT);
        vm.prank(buyer);
        vm.expectRevert(SwapVMSRC20Market.InvalidEnvelope.selector);
        market.settleSellOrder{value: ORDER_PRICE + VM_INPUT}(orderId, wrongRelease, TickMath.MIN_SQRT_PRICE + 1);

        SwapVMSRC20Market.Order memory order = market.getOrder(orderId);
        assertEq(uint8(order.status), uint8(SwapVMSRC20Market.Status.Open));
        assertEq(_balanceOfId(escrow), ORDER_AMOUNT);
        assertEq(market.escrowedTokenAmount(), ORDER_AMOUNT);
    }

    function test_sellOrdersRequireSignedEscrowReleaseForCancellationOrExpiry() public {
        SwaputerKernel.VMEnvelope memory deposit =
            _signedEscrowDeposit(ACTOR_KEY, actor, ORDER_AMOUNT, _nonce(actor), VM_INPUT);
        vm.prank(actor);
        uint256 orderId = market.createSellOrder{value: VM_INPUT}(
            ORDER_AMOUNT, UNIT_PRICE, VM_INPUT, uint64(block.timestamp + 1 days), deposit, TickMath.MIN_SQRT_PRICE + 1
        );

        vm.prank(actor);
        vm.expectPartialRevert(SwapVMSRC20Market.SellEscrowReleaseRequired.selector);
        market.cancelOrder(orderId);

        vm.warp(block.timestamp + 2 days);
        vm.expectPartialRevert(SwapVMSRC20Market.SellEscrowReleaseRequired.selector);
        market.expireOrder(orderId);
    }

    function test_buyOrderCancellationRefundsOnlyEscrowedLiability() public {
        vm.deal(address(market), 7 ether);
        uint256 forced = address(market).balance;
        uint256 buyerBefore = buyer.balance;

        vm.prank(buyer);
        uint256 orderId = market.createBuyOrder{value: ORDER_PRICE + VM_INPUT}(
            ORDER_AMOUNT, UNIT_PRICE, VM_INPUT, uint64(block.timestamp + 1 days)
        );
        vm.prank(buyer);
        market.cancelOrder(orderId);

        assertEq(buyer.balance, buyerBefore);
        assertEq(market.lockedEth(), 0);
        assertEq(address(market).balance, forced);
    }

    function _deploySRC20AndEscrowMarket() private {
        bytes32 actorId = kernel.eoaAccountId(actor);
        bytes memory src20Package = vm.readFileBinary("tooling/tinysol/programs/mintable-src20/MintableSRC20.svm");
        src20CodeHash = keccak256(src20Package);
        src20 = kernel.contractAccountId(worldId, actorId, kernel.creatorNonce(worldId, actorId), src20CodeHash);
        _buyVM(
            actor,
            _signedDeploy(
                ACTOR_KEY,
                src20CodeHash,
                abi.encodePacked(bytes4(uint32(src20Package.length)), src20Package),
                10_000,
                _nonce(actor),
                actor,
                VM_INPUT,
                address(0)
            ),
            VM_INPUT
        );
        assertEq(kernel.programCodeHash(worldId, src20), src20CodeHash);

        bytes memory mintPayload = abi.encodePacked(bytes4(keccak256("mint(bytes32)")), abi.encode(actorId));
        for (uint256 i; i < SRC_SUPPLY / (1_000 * TOKEN_UNIT); ++i) {
            _buyVM(
                actor,
                _signedCall(ACTOR_KEY, src20, mintPayload, TOKEN_LIMIT, _nonce(actor), actor, VM_INPUT, address(0)),
                VM_INPUT
            );
        }
        assertEq(_balanceOf(actor), SRC_SUPPLY);

        bytes memory escrowPackage = vm.readFileBinary("tooling/tinysol/programs/market-escrow/MarketEscrow.svm");
        escrowCodeHash = keccak256(escrowPackage);
        escrow = kernel.contractAccountId(worldId, actorId, kernel.creatorNonce(worldId, actorId), escrowCodeHash);
        bytes memory marketInitCode = abi.encodePacked(
            type(SwapVMSRC20Market).creationCode,
            abi.encode(router, worldId, src20, src20CodeHash, escrow, escrowCodeHash)
        );
        address predictedMarket = vm.computeCreate2Address(MARKET_SALT, keccak256(marketInitCode), address(this));
        bytes memory escrowArgs = abi.encode(src20, predictedMarket);
        _buyVM(
            actor,
            _signedDeploy(
                ACTOR_KEY,
                escrowCodeHash,
                abi.encodePacked(bytes4(uint32(escrowPackage.length)), escrowPackage, escrowArgs),
                10_000,
                _nonce(actor),
                actor,
                VM_INPUT,
                address(0)
            ),
            VM_INPUT
        );
        assertEq(kernel.programCodeHash(worldId, escrow), escrowCodeHash);

        market = new SwapVMSRC20Market{salt: MARKET_SALT}(router, worldId, src20, src20CodeHash, escrow, escrowCodeHash);
        assertEq(address(market), predictedMarket);
        assertEq(address(market.router()), address(router));
        assertEq(address(market.kernel()), address(kernel));
        assertEq(market.worldId(), worldId);
        assertEq(market.token(), src20);
        assertEq(market.escrow(), escrow);
    }

    function _approveEscrow(uint256 amount) internal {
        bytes memory payload =
            abi.encodePacked(bytes4(keccak256("approve(bytes32,uint256)")), abi.encode(escrow, amount));
        _buyVM(
            actor,
            _signedCall(ACTOR_KEY, src20, payload, TOKEN_LIMIT, _nonce(actor), actor, VM_INPUT, address(0)),
            VM_INPUT
        );
        assertEq(_allowance(kernel.eoaAccountId(actor), escrow), amount);
    }

    function _worldParams(bytes32 tokenSalt, bytes32 bootstrapSalt)
        private
        view
        returns (SwaputerWorldFactory.CreateWorldParams memory params)
    {
        address predictedToken = factory.predictGasToken(tokenSalt, INITIAL_SUPPLY, address(this));
        address predictedWorldDeployer = factory.predictWorldDeployer(bootstrapSalt);
        address predictedKernel = factory.predictKernel(predictedWorldDeployer);
        bytes memory hookArgs = abi.encode(
            manager,
            SwaputerKernel(predictedKernel),
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
            type(SwaputerHook).creationCode,
            hookArgs
        );
        params = SwaputerWorldFactory.CreateWorldParams({
            tokenSalt: tokenSalt,
            bootstrapSalt: bootstrapSalt,
            hookSalt: hookSalt,
            predictedKernel: predictedKernel,
            predictedHook: predictedHook,
            initialSupply: INITIAL_SUPPLY,
            initialHolder: address(this),
            distributionCommitment: keccak256("src20-market-test-distribution"),
            byteGasPrice: BYTE_GAS_PRICE,
            poolFee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            initialSqrtPriceX96: SQRT_PRICE_1_1
        });
    }

    function _signedTransfer(uint256 signingKey, address from, address to, uint128 amount, uint64 nonce, uint128 ethIn)
        internal
        view
        returns (SwaputerKernel.VMEnvelope memory action)
    {
        bytes memory payload = abi.encodePacked(
            bytes4(keccak256("transfer(bytes32,uint256)")), abi.encode(kernel.eoaAccountId(to), amount)
        );
        action = _signedEnvelope(
            signingKey, from, SwaputerKernel.RootOp.CALL, src20, payload, TOKEN_LIMIT, nonce, to, ethIn
        );
    }

    function _signedEscrowDeposit(uint256 signingKey, address seller, uint128 amount, uint64 nonce, uint128 ethIn)
        internal
        view
        returns (SwaputerKernel.VMEnvelope memory action)
    {
        bytes memory payload = abi.encodePacked(
            bytes4(keccak256("deposit(bytes32,uint256)")), abi.encode(kernel.eoaAccountId(seller), amount)
        );
        action = _signedEnvelope(
            signingKey, seller, SwaputerKernel.RootOp.CALL, escrow, payload, ESCROW_LIMIT, nonce, seller, ethIn
        );
    }

    function _signedEscrowRelease(
        uint256 signingKey,
        address signer,
        address recipient,
        uint128 amount,
        uint64 nonce,
        uint128 ethIn
    ) internal view returns (SwaputerKernel.VMEnvelope memory action) {
        bytes memory payload = abi.encodePacked(
            bytes4(keccak256("release(bytes32,uint256)")), abi.encode(kernel.eoaAccountId(recipient), amount)
        );
        action = _signedEnvelope(
            signingKey, signer, SwaputerKernel.RootOp.CALL, escrow, payload, ESCROW_LIMIT, nonce, recipient, ethIn
        );
    }

    function _signedDeploy(
        uint256 signingKey,
        bytes32 codeHash,
        bytes memory payload,
        uint32 limit,
        uint64 nonce,
        address recipient,
        uint128 ethIn,
        address executor
    ) private view returns (SwaputerKernel.VMEnvelope memory action) {
        action = _signedEnvelopeWithExecutor(
            signingKey,
            vm.addr(signingKey),
            SwaputerKernel.RootOp.DEPLOY,
            codeHash,
            payload,
            limit,
            nonce,
            recipient,
            ethIn,
            executor
        );
    }

    function _signedCall(
        uint256 signingKey,
        bytes32 target,
        bytes memory payload,
        uint32 limit,
        uint64 nonce,
        address recipient,
        uint128 ethIn,
        address executor
    ) internal view returns (SwaputerKernel.VMEnvelope memory action) {
        action = _signedEnvelopeWithExecutor(
            signingKey,
            vm.addr(signingKey),
            SwaputerKernel.RootOp.CALL,
            target,
            payload,
            limit,
            nonce,
            recipient,
            ethIn,
            executor
        );
    }

    function _signedEnvelope(
        uint256 signingKey,
        address signer,
        SwaputerKernel.RootOp op,
        bytes32 target,
        bytes memory payload,
        uint32 limit,
        uint64 nonce,
        address recipient,
        uint128 ethIn
    ) internal view returns (SwaputerKernel.VMEnvelope memory action) {
        action = _signedEnvelopeWithExecutor(
            signingKey, signer, op, target, payload, limit, nonce, recipient, ethIn, address(market)
        );
    }

    function _signedEnvelopeWithExecutor(
        uint256 signingKey,
        address signer,
        SwaputerKernel.RootOp op,
        bytes32 target,
        bytes memory payload,
        uint32 limit,
        uint64 nonce,
        address recipient,
        uint128 ethIn,
        address executor
    ) internal view returns (SwaputerKernel.VMEnvelope memory action) {
        action = SwaputerKernel.VMEnvelope({
            op: op,
            worldId: worldId,
            actor: signer,
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
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signingKey, digest);
        action.signature = abi.encodePacked(r, s, v);
    }

    function _buyVM(address caller, SwaputerKernel.VMEnvelope memory action, uint128 ethIn) internal {
        vm.prank(caller);
        router.buyVMExactInput{value: ethIn}(worldId, TickMath.MIN_SQRT_PRICE + 1, action);
    }

    function _nonce(address account) internal view returns (uint64) {
        return kernel.nonces(worldId, kernel.eoaAccountId(account));
    }

    function _balanceOf(address account) internal view returns (uint256) {
        return _balanceOfId(kernel.eoaAccountId(account));
    }

    function _balanceOfId(bytes32 account) internal view returns (uint256) {
        return _queryUint("balanceOf(bytes32)", abi.encode(account));
    }

    function _allowance(bytes32 owner, bytes32 spender) internal view returns (uint256) {
        return _queryUint("allowance(bytes32,bytes32)", abi.encode(owner, spender));
    }

    function _queryUint(string memory signature, bytes memory arguments) internal view returns (uint256 value) {
        (bytes memory output,) =
            kernel.staticCall(worldId, src20, abi.encodePacked(bytes4(keccak256(bytes(signature))), arguments), 2_000);
        assertEq(output.length, 32);
        value = abi.decode(output, (uint256));
    }
}
