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
import {SwapVMSETHVault} from "../src/SwapVMSETHVault.sol";
import {SwapVMWorldFactory} from "../src/SwapVMWorldFactory.sol";

contract RejectETH {
    receive() external payable {
        revert();
    }
}

contract SwapVMSETHVaultTest is Test {
    using TransientStateLibrary for PoolManager;

    uint256 internal constant INITIAL_SUPPLY = 1e36;
    uint128 internal constant BYTE_GAS_PRICE = 1e12;
    uint24 internal constant POOL_FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    uint160 internal constant SQRT_PRICE_1_1 = 1 << 96;
    uint256 internal constant ACTOR_KEY = 0xA11CE;
    uint256 internal constant BUYER_KEY = 0xB0B;
    uint128 internal constant BRIDGE_AMOUNT = 1 ether;
    uint128 internal constant VM_INPUT = 0.25 ether;
    uint32 internal constant SETH_LIMIT = 8_000;
    bytes32 internal constant VAULT_SALT = keccak256("SwapVMSETHVault.atomic.test");

    PoolManager internal manager;
    SwapVMWorldFactory internal factory;
    SwapVMRouter internal router;
    SwapVMGasToken internal gasToken;
    SwapVMKernel internal kernel;
    PoolKey internal key;
    bytes32 internal worldId;
    address internal actor;
    address internal buyer;

    SwapVMSETHVault internal vault;
    bytes32 internal seth;
    bytes32 internal sethCodeHash;

    receive() external payable {}

    function setUp() public virtual {
        vm.deal(address(this), 1e30);
        actor = vm.addr(ACTOR_KEY);
        buyer = vm.addr(BUYER_KEY);
        vm.deal(actor, 100 ether);
        vm.deal(buyer, 100 ether);

        manager = new PoolManager(address(this));
        SwapVMCreationCodeStore kernelCodeStore = new SwapVMCreationCodeStore(type(SwapVMKernel).creationCode);
        SwapVMCreationCodeStore hookCodeStore = new SwapVMCreationCodeStore(type(SwapVMHook).creationCode);
        factory = new SwapVMWorldFactory(
            manager,
            address(manager).codehash,
            address(kernelCodeStore),
            address(hookCodeStore),
            address(0xFEE),
            address(0xC0FFEE)
        );
        router = SwapVMRouter(payable(factory.router()));

        (worldId, gasToken, kernel,) = factory.createWorld(_worldParams(bytes32(uint256(11)), bytes32(uint256(12))));
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

        _deploySETHAndVault();
    }

    function test_depositAtomicallyLocksEthAndMintsSETH() public {
        uint64 nonceBefore = _nonce(actor);
        SwapVMKernel.VMEnvelope memory mint = _signedMint(ACTOR_KEY, actor, actor, BRIDGE_AMOUNT, nonceBefore);

        vm.prank(actor);
        vault.deposit{value: BRIDGE_AMOUNT + VM_INPUT}(BRIDGE_AMOUNT, VM_INPUT, mint, TickMath.MIN_SQRT_PRICE + 1);

        assertEq(_nonce(actor), nonceBefore + 1);
        assertEq(_balanceOf(actor), BRIDGE_AMOUNT);
        assertEq(_totalSupply(), BRIDGE_AMOUNT);
        assertEq(vault.lockedEth(), BRIDGE_AMOUNT);
        assertEq(address(vault).balance, BRIDGE_AMOUNT);
        assertEq(vault.backingSurplus(), 0);
        assertTrue(vault.isSolvent());
        assertEq(manager.getNonzeroDeltaCount(), 0);
    }

    function test_depositRejectsContractRecipientThatCannotAuthorizeFutureTransfers() public {
        RejectETH contractRecipient = new RejectETH();
        uint64 nonceBefore = _nonce(actor);
        SwapVMKernel.VMEnvelope memory mint =
            _signedMint(ACTOR_KEY, actor, address(contractRecipient), BRIDGE_AMOUNT, nonceBefore);

        vm.prank(actor);
        vm.expectPartialRevert(SwapVMSETHVault.UnsupportedContractRecipient.selector);
        vault.deposit{value: BRIDGE_AMOUNT + VM_INPUT}(BRIDGE_AMOUNT, VM_INPUT, mint, TickMath.MIN_SQRT_PRICE + 1);

        assertEq(_nonce(actor), nonceBefore);
        assertEq(_totalSupply(), 0);
        assertEq(vault.lockedEth(), 0);
    }

    function test_vaultConstructorRejectsSETHBoundToDifferentVault() public {
        vm.expectRevert(SwapVMSETHVault.InvalidSETH.selector);
        new SwapVMSETHVault(router, worldId, seth, sethCodeHash);
    }

    function test_redeemAtomicallyBurnsSETHAndPaysChosenRecipient() public {
        _deposit(actor, actor, ACTOR_KEY, BRIDGE_AMOUNT);
        uint256 buyerBefore = buyer.balance;
        uint64 nonceBefore = _nonce(actor);
        SwapVMKernel.VMEnvelope memory burn = _signedBurn(ACTOR_KEY, actor, buyer, BRIDGE_AMOUNT, nonceBefore);

        vm.prank(actor);
        vault.redeem{value: VM_INPUT}(BRIDGE_AMOUNT, VM_INPUT, buyer, burn, TickMath.MIN_SQRT_PRICE + 1);

        assertEq(_nonce(actor), nonceBefore + 1);
        assertEq(_balanceOf(actor), 0);
        assertEq(_totalSupply(), 0);
        assertEq(vault.lockedEth(), 0);
        assertEq(address(vault).balance, 0);
        assertEq(buyer.balance, buyerBefore + BRIDGE_AMOUNT);
        assertTrue(vault.isSolvent());
        assertEq(manager.getNonzeroDeltaCount(), 0);
    }

    function test_directRouterMintCannotBypassVaultExecutorBinding() public {
        uint64 nonceBefore = _nonce(actor);
        bytes memory payload = abi.encodePacked(
            bytes4(keccak256("bridgeMint(bytes32,uint256)")), abi.encode(kernel.eoaAccountId(actor), BRIDGE_AMOUNT)
        );
        SwapVMKernel.VMEnvelope memory action = _signedEnvelope(
            ACTOR_KEY, actor, SwapVMKernel.RootOp.CALL, seth, payload, SETH_LIMIT, nonceBefore, actor, VM_INPUT, actor
        );

        vm.prank(actor);
        vm.expectRevert();
        router.buyVMExactInput{value: VM_INPUT}(worldId, TickMath.MIN_SQRT_PRICE + 1, action);

        assertEq(_nonce(actor), nonceBefore);
        assertEq(_totalSupply(), 0);
        assertEq(vault.lockedEth(), 0);
    }

    function test_sETHTransferUsesInternalMoveWithoutChangingBridgeLiability() public {
        _deposit(actor, actor, ACTOR_KEY, BRIDGE_AMOUNT);
        uint128 transferAmount = BRIDGE_AMOUNT / 4;
        bytes memory payload = abi.encodePacked(
            bytes4(keccak256("transfer(bytes32,uint256)")), abi.encode(kernel.eoaAccountId(buyer), transferAmount)
        );
        SwapVMKernel.VMEnvelope memory action = _signedEnvelope(
            ACTOR_KEY, actor, SwapVMKernel.RootOp.CALL, seth, payload, SETH_LIMIT, _nonce(actor), actor, VM_INPUT, actor
        );
        _buyVM(actor, action, VM_INPUT);

        assertEq(_balanceOf(actor), BRIDGE_AMOUNT - transferAmount);
        assertEq(_balanceOf(buyer), transferAmount);
        assertEq(_totalSupply(), BRIDGE_AMOUNT);
        assertEq(vault.lockedEth(), BRIDGE_AMOUNT);
        assertEq(address(vault).balance, BRIDGE_AMOUNT);
        assertTrue(vault.isSolvent());
    }

    function test_depositRejectsRecipientPayloadRedirectionBeforeVMExecution() public {
        uint64 nonceBefore = _nonce(actor);
        bytes memory wrongPayload = abi.encodePacked(
            bytes4(keccak256("bridgeMint(bytes32,uint256)")), abi.encode(kernel.eoaAccountId(buyer), BRIDGE_AMOUNT)
        );
        SwapVMKernel.VMEnvelope memory wrong = _signedEnvelope(
            ACTOR_KEY,
            actor,
            SwapVMKernel.RootOp.CALL,
            seth,
            wrongPayload,
            SETH_LIMIT,
            nonceBefore,
            actor,
            VM_INPUT,
            address(vault)
        );

        vm.prank(actor);
        vm.expectRevert(SwapVMSETHVault.InvalidBridgePayload.selector);
        vault.deposit{value: BRIDGE_AMOUNT + VM_INPUT}(BRIDGE_AMOUNT, VM_INPUT, wrong, TickMath.MIN_SQRT_PRICE + 1);

        assertEq(_nonce(actor), nonceBefore);
        assertEq(_totalSupply(), 0);
        assertEq(vault.lockedEth(), 0);
        assertEq(address(vault).balance, 0);
    }

    function test_redeemWithoutOwnerBalanceRollsBackVaultAndVMState() public {
        _deposit(actor, buyer, ACTOR_KEY, BRIDGE_AMOUNT);
        uint64 nonceBefore = _nonce(actor);
        SwapVMKernel.VMEnvelope memory burn = _signedBurn(ACTOR_KEY, actor, actor, BRIDGE_AMOUNT, nonceBefore);

        vm.prank(actor);
        vm.expectRevert();
        vault.redeem{value: VM_INPUT}(BRIDGE_AMOUNT, VM_INPUT, actor, burn, TickMath.MIN_SQRT_PRICE + 1);

        assertEq(_nonce(actor), nonceBefore);
        assertEq(_balanceOf(actor), 0);
        assertEq(_balanceOf(buyer), BRIDGE_AMOUNT);
        assertEq(_totalSupply(), BRIDGE_AMOUNT);
        assertEq(vault.lockedEth(), BRIDGE_AMOUNT);
        assertEq(address(vault).balance, BRIDGE_AMOUNT);
        assertTrue(vault.isSolvent());
    }

    function test_failedNativePayoutRollsBackBurnNonceAndLiability() public {
        _deposit(actor, actor, ACTOR_KEY, BRIDGE_AMOUNT);
        RejectETH rejecting = new RejectETH();
        uint64 nonceBefore = _nonce(actor);
        SwapVMKernel.VMEnvelope memory burn =
            _signedBurn(ACTOR_KEY, actor, address(rejecting), BRIDGE_AMOUNT, nonceBefore);

        vm.prank(actor);
        vm.expectPartialRevert(SwapVMSETHVault.NativeTransferFailed.selector);
        vault.redeem{value: VM_INPUT}(BRIDGE_AMOUNT, VM_INPUT, address(rejecting), burn, TickMath.MIN_SQRT_PRICE + 1);

        assertEq(_nonce(actor), nonceBefore);
        assertEq(_balanceOf(actor), BRIDGE_AMOUNT);
        assertEq(_totalSupply(), BRIDGE_AMOUNT);
        assertEq(vault.lockedEth(), BRIDGE_AMOUNT);
        assertEq(address(vault).balance, BRIDGE_AMOUNT);
        assertTrue(vault.isSolvent());
    }

    function test_forcedEthRemainsSurplusAndCannotInflateRedemption() public {
        vm.deal(address(vault), 7 ether);
        _deposit(actor, actor, ACTOR_KEY, BRIDGE_AMOUNT);
        assertEq(vault.backingSurplus(), 7 ether);

        SwapVMKernel.VMEnvelope memory burn = _signedBurn(ACTOR_KEY, actor, actor, BRIDGE_AMOUNT, _nonce(actor));
        vm.prank(actor);
        vault.redeem{value: VM_INPUT}(BRIDGE_AMOUNT, VM_INPUT, actor, burn, TickMath.MIN_SQRT_PRICE + 1);

        assertEq(address(vault).balance, 7 ether);
        assertEq(vault.lockedEth(), 0);
        assertEq(vault.backingSurplus(), 7 ether);
        assertTrue(vault.isSolvent());
    }

    function _deploySETHAndVault() private {
        bytes32 actorId = kernel.eoaAccountId(actor);
        bytes memory packageBytes = vm.readFileBinary("tooling/tinysol/programs/seth/SETH.svm");
        sethCodeHash = keccak256(packageBytes);
        seth = kernel.contractAccountId(worldId, actorId, kernel.creatorNonce(worldId, actorId), sethCodeHash);

        bytes memory vaultInitCode =
            abi.encodePacked(type(SwapVMSETHVault).creationCode, abi.encode(router, worldId, seth, sethCodeHash));
        address predictedVault = vm.computeCreate2Address(VAULT_SALT, keccak256(vaultInitCode), address(this));
        bytes memory deployPayload =
            abi.encodePacked(bytes4(uint32(packageBytes.length)), packageBytes, abi.encode(predictedVault));
        SwapVMKernel.VMEnvelope memory deploy = _signedEnvelope(
            ACTOR_KEY,
            actor,
            SwapVMKernel.RootOp.DEPLOY,
            sethCodeHash,
            deployPayload,
            20_000,
            _nonce(actor),
            actor,
            VM_INPUT,
            address(0)
        );
        _buyVM(actor, deploy, VM_INPUT);
        assertEq(kernel.programCodeHash(worldId, seth), sethCodeHash);

        vault = new SwapVMSETHVault{salt: VAULT_SALT}(router, worldId, seth, sethCodeHash);
        assertEq(address(vault), predictedVault);
        assertEq(address(vault.router()), address(router));
        assertEq(address(vault.kernel()), address(kernel));
        assertEq(vault.worldId(), worldId);
        assertEq(vault.seth(), seth);
        assertEq(_queryAddress("vault()"), predictedVault);
    }

    function _deposit(address payer, address recipient, uint256 keyValue, uint128 amount) private {
        SwapVMKernel.VMEnvelope memory mint = _signedMint(keyValue, payer, recipient, amount, _nonce(payer));
        vm.prank(payer);
        vault.deposit{value: amount + VM_INPUT}(amount, VM_INPUT, mint, TickMath.MIN_SQRT_PRICE + 1);
    }

    function _signedMint(uint256 keyValue, address payer, address recipient, uint128 amount, uint64 nonce)
        internal
        view
        returns (SwapVMKernel.VMEnvelope memory)
    {
        bytes memory payload = abi.encodePacked(
            bytes4(keccak256("bridgeMint(bytes32,uint256)")), abi.encode(kernel.eoaAccountId(recipient), amount)
        );
        return _signedEnvelope(
            keyValue,
            payer,
            SwapVMKernel.RootOp.CALL,
            seth,
            payload,
            SETH_LIMIT,
            nonce,
            recipient,
            VM_INPUT,
            address(vault)
        );
    }

    function _signedBurn(uint256 keyValue, address owner, address recipient, uint128 amount, uint64 nonce)
        internal
        view
        returns (SwapVMKernel.VMEnvelope memory)
    {
        bytes memory payload = abi.encodePacked(bytes4(keccak256("bridgeBurn(uint256)")), abi.encode(amount));
        return _signedEnvelope(
            keyValue,
            owner,
            SwapVMKernel.RootOp.CALL,
            seth,
            payload,
            SETH_LIMIT,
            nonce,
            recipient,
            VM_INPUT,
            address(vault)
        );
    }

    function _signedEnvelope(
        uint256 keyValue,
        address signer,
        SwapVMKernel.RootOp op,
        bytes32 target,
        bytes memory payload,
        uint32 limit,
        uint64 nonce,
        address recipient,
        uint128 ethIn,
        address executor
    ) internal view returns (SwapVMKernel.VMEnvelope memory action) {
        assertEq(vm.addr(keyValue), signer);
        action = SwapVMKernel.VMEnvelope({
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
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(keyValue, digest);
        action.signature = abi.encodePacked(r, s, v);
    }

    function _buyVM(address caller, SwapVMKernel.VMEnvelope memory action, uint128 ethIn) internal {
        vm.prank(caller);
        router.buyVMExactInput{value: ethIn}(worldId, TickMath.MIN_SQRT_PRICE + 1, action);
    }

    function _nonce(address account) internal view returns (uint64) {
        return kernel.nonces(worldId, kernel.eoaAccountId(account));
    }

    function _balanceOf(address account) internal view returns (uint256) {
        return _queryUint("balanceOf(bytes32)", abi.encode(kernel.eoaAccountId(account)));
    }

    function _totalSupply() internal view returns (uint256) {
        return _queryUint("totalSupply()", bytes(""));
    }

    function _queryAddress(string memory signature) private view returns (address value) {
        (bytes memory output,) =
            kernel.staticCall(worldId, seth, abi.encodePacked(bytes4(keccak256(bytes(signature)))), 2_000);
        assertEq(output.length, 32);
        value = address(uint160(abi.decode(output, (uint256))));
    }

    function _queryUint(string memory signature, bytes memory arguments) internal view returns (uint256 value) {
        (bytes memory output,) =
            kernel.staticCall(worldId, seth, abi.encodePacked(bytes4(keccak256(bytes(signature))), arguments), 2_000);
        assertEq(output.length, 32);
        value = abi.decode(output, (uint256));
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
            distributionCommitment: keccak256("seth-vault-test-distribution"),
            byteGasPrice: BYTE_GAS_PRICE,
            poolFee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            initialSqrtPriceX96: SQRT_PRICE_1_1
        });
    }
}
