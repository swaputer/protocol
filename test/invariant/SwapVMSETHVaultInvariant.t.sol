// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";

import {SwapVMKernel} from "../../src/SwapVMKernel.sol";
import {SwapVMRouter} from "../../src/SwapVMRouter.sol";
import {SwapVMSETHVaultTest} from "../SwapVMSETHVault.t.sol";

contract SwapVMSETHVaultInvariantTest is StdInvariant, SwapVMSETHVaultTest {
    using TransientStateLibrary for IPoolManager;

    uint64 public successfulVMCalls;
    uint256 public totalExecutedBytes;
    uint64 private _heightAtStart;
    uint256 private _gasSupplyAtStart;

    function setUp() public override {
        super.setUp();
        _heightAtStart = kernel.executionHeight(worldId);
        _gasSupplyAtStart = gasToken.totalSupply();

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = this.actionDeposit.selector;
        selectors[1] = this.actionRedeem.selector;
        selectors[2] = this.actionTransfer.selector;
        selectors[3] = this.actionRejectedDirectMint.selector;
        targetContract(address(this));
        targetSelector(FuzzSelector({addr: address(this), selectors: selectors}));
    }

    function actionDeposit(bool useBuyer, uint96 rawAmount) external {
        (address owner, uint256 ownerKey) = useBuyer ? (buyer, BUYER_KEY) : (actor, ACTOR_KEY);
        uint128 amount = uint128(bound(uint256(rawAmount), 1, 0.25 ether));
        if (owner.balance < uint256(amount) + VM_INPUT) return;

        SwapVMKernel.VMEnvelope memory mint = _signedMint(ownerKey, owner, owner, amount, _nonce(owner));
        vm.prank(owner);
        vault.deposit{value: uint256(amount) + VM_INPUT}(amount, VM_INPUT, mint, TickMath.MIN_SQRT_PRICE + 1);
        _recordSuccessfulVMCall();
    }

    function actionRedeem(bool useBuyer, uint96 rawAmount) external {
        (address owner, uint256 ownerKey) = useBuyer ? (buyer, BUYER_KEY) : (actor, ACTOR_KEY);
        uint256 balance = _balanceOf(owner);
        if (balance == 0 || owner.balance < VM_INPUT) return;
        uint128 amount = uint128(bound(uint256(rawAmount), 1, balance));

        SwapVMKernel.VMEnvelope memory burn = _signedBurn(ownerKey, owner, owner, amount, _nonce(owner));
        vm.prank(owner);
        vault.redeem{value: VM_INPUT}(amount, VM_INPUT, owner, burn, TickMath.MIN_SQRT_PRICE + 1);
        _recordSuccessfulVMCall();
    }

    function actionTransfer(bool buyerToActor, uint96 rawAmount) external {
        address sender = buyerToActor ? buyer : actor;
        address recipient = buyerToActor ? actor : buyer;
        uint256 senderKey = buyerToActor ? BUYER_KEY : ACTOR_KEY;
        uint256 balance = _balanceOf(sender);
        if (balance == 0 || sender.balance < VM_INPUT) return;
        uint256 amount = bound(uint256(rawAmount), 1, balance);
        bytes memory payload = abi.encodePacked(
            bytes4(keccak256("transfer(bytes32,uint256)")), abi.encode(kernel.eoaAccountId(recipient), amount)
        );
        SwapVMKernel.VMEnvelope memory transfer = _signedEnvelope(
            senderKey,
            sender,
            SwapVMKernel.RootOp.CALL,
            seth,
            payload,
            SETH_LIMIT,
            _nonce(sender),
            sender,
            VM_INPUT,
            sender
        );
        _buyVM(sender, transfer, VM_INPUT);
        _recordSuccessfulVMCall();
    }

    function actionRejectedDirectMint(bool useBuyer, uint96 rawAmount) external {
        (address owner, uint256 ownerKey) = useBuyer ? (buyer, BUYER_KEY) : (actor, ACTOR_KEY);
        if (owner.balance < VM_INPUT) return;
        uint128 amount = uint128(bound(uint256(rawAmount), 1, 0.25 ether));
        bytes memory payload = abi.encodePacked(
            bytes4(keccak256("bridgeMint(bytes32,uint256)")), abi.encode(kernel.eoaAccountId(owner), amount)
        );
        SwapVMKernel.VMEnvelope memory mint = _signedEnvelope(
            ownerKey, owner, SwapVMKernel.RootOp.CALL, seth, payload, SETH_LIMIT, _nonce(owner), owner, VM_INPUT, owner
        );

        uint64 nonceBefore = _nonce(owner);
        uint64 heightBefore = kernel.executionHeight(worldId);
        uint256 supplyBefore = _totalSupply();
        uint256 liabilityBefore = vault.lockedEth();
        uint256 backingBefore = address(vault).balance;
        uint256 gasSupplyBefore = gasToken.totalSupply();
        vm.prank(owner);
        (bool success,) = address(router).call{value: VM_INPUT}(
            abi.encodeCall(SwapVMRouter.buyVMExactInput, (worldId, TickMath.MIN_SQRT_PRICE + 1, mint))
        );
        assertFalse(success);
        assertEq(_nonce(owner), nonceBefore);
        assertEq(kernel.executionHeight(worldId), heightBefore);
        assertEq(_totalSupply(), supplyBefore);
        assertEq(vault.lockedEth(), liabilityBefore);
        assertEq(address(vault).balance, backingBefore);
        assertEq(gasToken.totalSupply(), gasSupplyBefore);
    }

    function invariant_sETHSupplyIsExactlyBacked() public view {
        uint256 supply = _totalSupply();
        assertEq(supply, vault.lockedEth());
        assertGe(address(vault).balance, vault.lockedEth());
        assertEq(_balanceOf(actor) + _balanceOf(buyer), supply);
        assertTrue(vault.isSolvent());
    }

    function invariant_successfulCallsReconcileKernelAndGasBurn() public view {
        assertEq(kernel.executionHeight(worldId), _heightAtStart + successfulVMCalls);
        assertEq(gasToken.totalSupply(), _gasSupplyAtStart - totalExecutedBytes * BYTE_GAS_PRICE);
    }

    function invariant_bindingsAndPoolDeltasRemainStable() public view {
        assertEq(address(vault.router()), address(router));
        assertEq(address(vault.kernel()), address(kernel));
        assertEq(vault.worldId(), worldId);
        assertEq(vault.seth(), seth);
        IPoolManager poolManager = IPoolManager(address(manager));
        assertEq(poolManager.getNonzeroDeltaCount(), 0);
        assertEq(poolManager.currencyDelta(address(router), key.currency0), 0);
        assertEq(poolManager.currencyDelta(address(router), key.currency1), 0);
    }

    function _recordSuccessfulVMCall() private {
        ++successfulVMCalls;
        totalExecutedBytes += kernel.executedBytes(worldId);
    }
}
