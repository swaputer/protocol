// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";

import {SwapVMKernel} from "../../src/SwapVMKernel.sol";
import {SwapVMStage2Test} from "../SwapVMStage2.t.sol";

contract SwapVMAuthorizationInvariantTest is StdInvariant, SwapVMStage2Test {
    using TransientStateLibrary for IPoolManager;

    uint128 private constant ETH_IN = 0.1 ether;
    uint32 private constant ACTION_LIMIT = 100;

    address private other;
    uint256 private supplyAtStart;
    uint64 public successfulCalls;
    uint256 public totalExecutedBytes;
    uint64 public rejectedCalls;
    uint64 public unexpectedSuccessfulRejections;
    uint64 public rejectionStateViolations;

    function setUp() public override {
        super.setUp();
        other = vm.addr(OTHER_KEY);
        vm.deal(other, 100 ether);
        supplyAtStart = token.totalSupply();

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = this.actionExecuteValid.selector;
        selectors[1] = this.actionRejectMutatedEnvelope.selector;
        selectors[2] = this.actionRejectBindingMismatch.selector;
        selectors[3] = this.actionRejectFreshInvalid.selector;
        targetContract(address(this));
        targetSelector(FuzzSelector({addr: address(this), selectors: selectors}));
    }

    function actionExecuteValid() external {
        uint64 nonce = kernel.nonces(worldId, kernel.eoaAccountId(actor));
        SwapVMKernel.VMEnvelope memory action = _validAction(nonce);
        vm.prank(actor);
        router.swap{value: ETH_IN}(key, _buyParams(ETH_IN, _priceLimit()), actor, abi.encode(action));
        ++successfulCalls;
        totalExecutedBytes += kernel.executedBytes(worldId);
    }

    function actionRejectMutatedEnvelope(uint8 rawMode) external {
        uint64 nonce = kernel.nonces(worldId, kernel.eoaAccountId(actor));
        SwapVMKernel.VMEnvelope memory action = _validAction(nonce);
        uint8 mode = rawMode % 11;
        if (mode == 0) action.worldId = bytes32(uint256(worldId) ^ 1);
        else if (mode == 1) action.actor = other;
        else if (mode == 2) action.targetOrCodeHash = VIEW_TARGET;
        else if (mode == 3) action.payload = hex"01";
        else if (mode == 4) action.byteGasLimit = ACTION_LIMIT - 1;
        else if (mode == 5) action.minNetTokenOut = 1;
        else if (mode == 6) action.nonce = nonce + 1;
        else if (mode == 7) action.deadline += 1;
        else if (mode == 8) action.recipient = other;
        else if (mode == 9) action.authorizedExecutor = other;
        else action.signature[0] = bytes1(uint8(action.signature[0]) ^ 1);
        _expectRejected(action, actor, actor, ETH_IN, _priceLimit());
    }

    function actionRejectBindingMismatch(uint8 rawMode) external {
        uint64 nonce = kernel.nonces(worldId, kernel.eoaAccountId(actor));
        uint8 mode = rawMode % 5;
        uint128 signedEth = ETH_IN;
        uint128 sentEth = ETH_IN;
        uint160 signedPrice = _priceLimit();
        uint160 actualPrice = signedPrice;
        address signedRecipient = actor;
        address actualRecipient = actor;
        address signedExecutor = actor;
        address caller = actor;
        address signedRouter = address(router);
        if (mode == 0) {
            sentEth += 1;
        } else if (mode == 1) {
            actualPrice += 1;
        } else if (mode == 2) {
            signedRouter = other;
        } else if (mode == 3) {
            actualRecipient = other;
        } else {
            signedExecutor = other;
            caller = actor;
        }

        SwapVMKernel.VMEnvelope memory action = _signedAction(
            ACTOR_KEY,
            STATE_TARGET,
            bytes(""),
            ACTION_LIMIT,
            0,
            nonce,
            uint64(block.timestamp + 1 days),
            signedRecipient,
            signedExecutor,
            signedEth,
            signedPrice,
            signedRouter
        );
        _expectRejected(action, caller, actualRecipient, sentEth, actualPrice);
    }

    function actionRejectFreshInvalid(uint8 rawMode) external {
        uint64 nonce = kernel.nonces(worldId, kernel.eoaAccountId(actor));
        uint8 mode = rawMode % 5;
        uint64 signedNonce = mode == 0 ? nonce + 1 : (mode == 1 && nonce != 0 ? nonce - 1 : nonce);
        uint64 deadline = mode == 2 ? uint64(block.timestamp - 1) : uint64(block.timestamp + 1 days);
        SwapVMKernel.VMEnvelope memory action = _signedAction(
            ACTOR_KEY,
            STATE_TARGET,
            bytes(""),
            ACTION_LIMIT,
            0,
            signedNonce,
            deadline,
            actor,
            actor,
            ETH_IN,
            _priceLimit(),
            address(router)
        );
        if (mode == 1 && nonce == 0) action.signature = new bytes(64);
        else if (mode == 3) action.signature = new bytes(64);
        else if (mode == 4) action.signature[64] = bytes1(uint8(1));
        _expectRejected(action, actor, actor, ETH_IN, _priceLimit());
    }

    function invariant_onlyValidAuthorizationMutatesKernelState() public view {
        assertEq(unexpectedSuccessfulRejections, 0);
        assertEq(rejectionStateViolations, 0);
        assertEq(kernel.executionHeight(worldId), successfulCalls);
        assertEq(kernel.nonces(worldId, kernel.eoaAccountId(actor)), successfulCalls);
        assertEq(token.totalSupply(), supplyAtStart - totalExecutedBytes * BYTE_GAS_PRICE);
        bytes32 expectedStorage = successfulCalls == 0 ? bytes32(0) : bytes32(uint256(42));
        assertEq(kernel.programStorageAt(worldId, STATE_TARGET, bytes32(uint256(1))), expectedStorage);
    }

    function invariant_authorizationFailuresNeverLeakPoolDeltas() public view {
        IPoolManager poolManager = IPoolManager(address(manager));
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(poolManager.getNonzeroDeltaCount(), 0);
        assertEq(poolManager.currencyDelta(address(router), key.currency0), 0);
        assertEq(poolManager.currencyDelta(address(router), key.currency1), 0);
        assertEq(poolManager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(poolManager.currencyDelta(address(hook), key.currency1), 0);
    }

    function _validAction(uint64 nonce) private view returns (SwapVMKernel.VMEnvelope memory) {
        return _signedAction(
            ACTOR_KEY,
            STATE_TARGET,
            bytes(""),
            ACTION_LIMIT,
            0,
            nonce,
            uint64(block.timestamp + 1 days),
            actor,
            actor,
            ETH_IN,
            _priceLimit(),
            address(router)
        );
    }

    function _expectRejected(
        SwapVMKernel.VMEnvelope memory action,
        address caller,
        address recipient,
        uint128 ethIn,
        uint160 priceLimit
    ) private {
        bytes32 beforeState = _stateFingerprint();
        vm.prank(caller);
        try router.swap{value: ethIn}(key, _buyParams(ethIn, priceLimit), recipient, abi.encode(action)) {
            ++unexpectedSuccessfulRejections;
        } catch {
            ++rejectedCalls;
            if (_stateFingerprint() != beforeState) ++rejectionStateViolations;
        }
    }

    function _stateFingerprint() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                kernel.executionHeight(worldId),
                kernel.executedBytes(worldId),
                kernel.nonces(worldId, kernel.eoaAccountId(actor)),
                kernel.nonces(worldId, kernel.eoaAccountId(other)),
                kernel.programStorageAt(worldId, STATE_TARGET, bytes32(uint256(1))),
                token.totalSupply(),
                token.balanceOf(actor),
                token.balanceOf(other),
                token.balanceOf(address(hook)),
                token.balanceOf(address(router)),
                address(manager).balance
            )
        );
    }

    function _priceLimit() private pure returns (uint160) {
        return TickMath.MIN_SQRT_PRICE + 1;
    }
}
