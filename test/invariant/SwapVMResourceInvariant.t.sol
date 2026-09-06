// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";

import {SwapVMKernel} from "../../src/SwapVMKernel.sol";
import {SwapVMStage2Test} from "../SwapVMStage2.t.sol";

contract SwapVMResourceInvariantTest is StdInvariant, SwapVMStage2Test {
    using TransientStateLibrary for IPoolManager;

    uint128 private constant ETH_IN = 0.1 ether;
    bytes32 private constant RESOURCE_LOOP_TARGET = 0x0100000000000000000000000000000000000000000000000000000000002001;
    bytes32 private constant STACK_TARGET = 0x0100000000000000000000000000000000000000000000000000000000002002;
    bytes32 private constant MEMORY_TARGET = 0x0100000000000000000000000000000000000000000000000000000000002003;
    bytes32 private constant MISSING_HALT_TARGET = 0x0100000000000000000000000000000000000000000000000000000000002004;
    bytes32 private constant INVALID_JUMP_TARGET = 0x0100000000000000000000000000000000000000000000000000000000002005;
    bytes32 private constant REVERT_TARGET = 0x0100000000000000000000000000000000000000000000000000000000002006;
    bytes32 private constant LARGE_EVENT_TARGET = 0x0100000000000000000000000000000000000000000000000000000000002007;
    bytes32 private constant MANY_EVENTS_TARGET = 0x0100000000000000000000000000000000000000000000000000000000002008;
    bytes32 private constant CALL_DEPTH_TARGET = 0x0100000000000000000000000000000000000000000000000000000000002009;
    bytes32 private constant TOTAL_MEMORY_TARGET = 0x010000000000000000000000000000000000000000000000000000000000200a;

    bytes32[10] private attackTargets;
    uint256 private supplyAtStart;
    uint256 private actorEthAtStart;
    uint64 public rejectedAttacks;
    uint64 public unexpectedSuccessfulAttacks;
    uint64 public rejectionStateViolations;

    function setUp() public override {
        super.setUp();
        attackTargets = [
            RESOURCE_LOOP_TARGET,
            STACK_TARGET,
            MEMORY_TARGET,
            MISSING_HALT_TARGET,
            INVALID_JUMP_TARGET,
            REVERT_TARGET,
            LARGE_EVENT_TARGET,
            MANY_EVENTS_TARGET,
            CALL_DEPTH_TARGET,
            TOTAL_MEMORY_TARGET
        ];

        kernel.install(worldId, RESOURCE_LOOP_TARGET, hex"602a6001555b600556");

        bytes memory stackOverflow = new bytes(1_026);
        for (uint256 i; i < 1_025; ++i) {
            stackOverflow[i] = bytes1(uint8(0x5f));
        }
        kernel.install(worldId, STACK_TARGET, stackOverflow);

        kernel.install(worldId, MEMORY_TARGET, hex"6001620100015200");
        kernel.install(worldId, MISSING_HALT_TARGET, hex"5f");
        kernel.install(worldId, INVALID_JUMP_TARGET, hex"600156");
        kernel.install(worldId, REVERT_TARGET, hex"602a6001555f5ffd");
        kernel.install(worldId, LARGE_EVENT_TARGET, hex"6110015fa000");

        bytes memory manyEvents = hex"602a600155";
        for (uint256 i; i < 65; ++i) {
            manyEvents = bytes.concat(manyEvents, hex"5f5fa0");
        }
        kernel.install(worldId, MANY_EVENTS_TARGET, bytes.concat(manyEvents, hex"00"));

        kernel.install(worldId, CALL_DEPTH_TARGET, abi.encodePacked(hex"7f", CALL_DEPTH_TARGET, hex"5f5f5f5ff100"));
        kernel.install(
            worldId, TOTAL_MEMORY_TARGET, abi.encodePacked(hex"7f", TOTAL_MEMORY_TARGET, hex"5f5f6120015ff100")
        );

        supplyAtStart = token.totalSupply();
        actorEthAtStart = actor.balance;
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = this.actionAttack.selector;
        targetContract(address(this));
        targetSelector(FuzzSelector({addr: address(this), selectors: selectors}));
    }

    function actionAttack(uint8 rawMode, uint32 rawLoopLimit) external {
        uint8 mode = rawMode % 10;
        uint32 byteLimit;
        if (mode == 0) byteLimit = uint32(bound(uint256(rawLoopLimit), 6, 1_000));
        else if (mode == 1) byteLimit = 2_000;
        else if (mode == 2) byteLimit = 8;
        else if (mode == 3) byteLimit = 1;
        else if (mode == 4) byteLimit = 3;
        else if (mode == 5) byteLimit = 8;
        else if (mode == 6) byteLimit = 6;
        else if (mode == 7) byteLimit = 201;
        else byteLimit = 2_000;

        SwapVMKernel.VMEnvelope memory action = _signedAction(
            ACTOR_KEY,
            attackTargets[mode],
            bytes(""),
            byteLimit,
            0,
            0,
            uint64(block.timestamp + 1 days),
            actor,
            actor,
            ETH_IN,
            TickMath.MIN_SQRT_PRICE + 1,
            address(router)
        );
        bytes32 beforeState = _stateFingerprint();
        vm.prank(actor);
        try router.swap{value: ETH_IN}(
            key, _buyParams(ETH_IN, TickMath.MIN_SQRT_PRICE + 1), actor, abi.encode(action)
        ) {
            ++unexpectedSuccessfulAttacks;
        } catch {
            ++rejectedAttacks;
            if (_stateFingerprint() != beforeState) ++rejectionStateViolations;
        }
    }

    function invariant_resourceFailuresAreAtomicAndUnmetered() public view {
        assertEq(unexpectedSuccessfulAttacks, 0);
        assertEq(rejectionStateViolations, 0);
        assertEq(kernel.executionHeight(worldId), 0);
        assertEq(kernel.executedBytes(worldId), 0);
        assertEq(kernel.nonces(worldId, kernel.eoaAccountId(actor)), 0);
        assertEq(token.totalSupply(), supplyAtStart);
        assertEq(actor.balance, actorEthAtStart);
        for (uint256 i; i < attackTargets.length; ++i) {
            assertEq(kernel.programStorageAt(worldId, attackTargets[i], bytes32(uint256(1))), bytes32(0));
        }
    }

    function invariant_resourceFailuresNeverLeakPoolDeltas() public view {
        IPoolManager poolManager = IPoolManager(address(manager));
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(poolManager.getNonzeroDeltaCount(), 0);
        assertEq(poolManager.currencyDelta(address(router), key.currency0), 0);
        assertEq(poolManager.currencyDelta(address(router), key.currency1), 0);
        assertEq(poolManager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(poolManager.currencyDelta(address(hook), key.currency1), 0);
    }

    function _stateFingerprint() private view returns (bytes32 state) {
        state = keccak256(
            abi.encode(
                kernel.executionHeight(worldId),
                kernel.executedBytes(worldId),
                kernel.nonces(worldId, kernel.eoaAccountId(actor)),
                token.totalSupply(),
                token.balanceOf(actor),
                token.balanceOf(address(hook)),
                token.balanceOf(address(router)),
                actor.balance,
                address(manager).balance
            )
        );
        for (uint256 i; i < attackTargets.length; ++i) {
            state =
                keccak256(abi.encode(state, kernel.programStorageAt(worldId, attackTargets[i], bytes32(uint256(1)))));
        }
    }
}
