// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {SwapVMCreationCodeReader, SwapVMCreationCodeStore} from "../src/SwapVMCreationCodeStore.sol";
import {SwapVMGasToken} from "../src/SwapVMGasToken.sol";
import {SwapVMHook} from "../src/SwapVMHook.sol";
import {SwapVMKernel} from "../src/SwapVMKernel.sol";
import {SwapVMRouter} from "../src/SwapVMRouter.sol";
import {SwapVMWorldDeployer} from "../src/SwapVMWorldDeployer.sol";
import {SwapVMWorldFactory} from "../src/SwapVMWorldFactory.sol";

/// @notice Isolated Foundry proof for the S7B-002 public-salt availability risk.
/// @dev These are simulated calls, not broadcast transactions or receipt evidence.
contract Stage7MSaltRecoveryTest is Test {
    using PoolIdLibrary for PoolKey;

    uint256 private constant INITIAL_SUPPLY = 1e36;
    uint128 private constant BYTE_GAS_PRICE = 1e12;
    uint24 private constant POOL_FEE = 3000;
    int24 private constant TICK_SPACING = 60;
    uint160 private constant SQRT_PRICE_1_1 = 1 << 96;
    address private constant FEE_ADMIN = address(0xFEE);
    address private constant FEE_CONTROLLER = address(0xC0FFEE);
    address private constant PUBLISHER = address(0x7100);
    address private constant GRIEFER = address(0x7200);
    uint160 private constant REQUIRED_HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    bytes32 private constant WORLD_SEALED_TOPIC = keccak256("WorldSealed(bytes32,bytes32)");

    PoolManager private manager;
    SwapVMCreationCodeStore private kernelCodeStore;
    SwapVMCreationCodeStore private hookCodeStore;
    SwapVMWorldFactory private factory;
    SwapVMRouter private router;
    SwapVMGasToken private token;
    SwapVMKernel private kernel;
    SwapVMHook private hook;
    bytes32 private worldId;

    struct WorldPlan {
        SwapVMWorldFactory.CreateWorldParams params;
        address gasToken;
        address worldDeployer;
        address kernel;
        address hook;
        bytes32 worldId;
    }

    function setUp() public {
        manager = new PoolManager(address(this));
        kernelCodeStore = new SwapVMCreationCodeStore(vm.getCode("src/SwapVMKernel.sol:SwapVMKernel"));
        hookCodeStore = new SwapVMCreationCodeStore(vm.getCode("src/SwapVMHook.sol:SwapVMHook"));
        factory = new SwapVMWorldFactory(
            manager,
            address(manager).codehash,
            address(kernelCodeStore),
            address(hookCodeStore),
            FEE_ADMIN,
            FEE_CONTROLLER,
            300
        );
        router = SwapVMRouter(payable(factory.router()));

        WorldPlan memory baseline = _plan(
            bytes32(uint256(1)),
            bytes32(uint256(2)),
            INITIAL_SUPPLY,
            address(this),
            keccak256("stage7a2-test-distribution"),
            BYTE_GAS_PRICE,
            POOL_FEE,
            TICK_SPACING
        );
        (worldId, token, kernel, hook) = factory.createWorld(baseline.params);
    }

    function test_exactCopyFrontRunCannotRedirectSupplyOrMutateConfig() public {
        bytes32 originalConfigHash = factory.getWorldConfig(worldId).configHash;
        WorldPlan memory candidate = _plan(
            bytes32(uint256(11_001)),
            bytes32(uint256(11_002)),
            INITIAL_SUPPLY,
            PUBLISHER,
            keccak256("s7b002-exact-copy"),
            BYTE_GAS_PRICE,
            POOL_FEE,
            TICK_SPACING
        );
        bytes32 publisherParamsHash = keccak256(abi.encode(candidate.params));
        bytes32 copiedParamsHash = keccak256(abi.encode(candidate.params));
        assertEq(copiedParamsHash, publisherParamsHash, "copy must be byte-identical");

        _createAndAssert(candidate, GRIEFER, true);

        vm.expectRevert(bytes(""));
        vm.prank(PUBLISHER);
        factory.createWorld(candidate.params);

        SwapVMWorldFactory.WorldConfig memory config = factory.getWorldConfig(candidate.worldId);
        assertEq(config.initialHolder, PUBLISHER);
        assertEq(SwapVMGasToken(candidate.gasToken).totalSupply(), INITIAL_SUPPLY);
        assertEq(SwapVMGasToken(candidate.gasToken).balanceOf(PUBLISHER), INITIAL_SUPPLY);
        assertEq(SwapVMGasToken(candidate.gasToken).balanceOf(GRIEFER), 0, "copier cannot redirect declared supply");
        assertEq(factory.getWorldConfig(worldId).configHash, originalConfigHash, "existing World changed");
    }

    function test_bootstrapSaltCollisionRollsBackAndRecoversWithRecomputedAddresses() public {
        bytes32 originalConfigHash = factory.getWorldConfig(worldId).configHash;
        WorldPlan memory candidate = _plan(
            bytes32(uint256(12_001)),
            bytes32(uint256(12_002)),
            INITIAL_SUPPLY,
            PUBLISHER,
            keccak256("s7b002-bootstrap-candidate"),
            BYTE_GAS_PRICE,
            POOL_FEE,
            TICK_SPACING
        );
        WorldPlan memory griefer = _plan(
            bytes32(uint256(12_003)),
            candidate.params.bootstrapSalt,
            INITIAL_SUPPLY / 2,
            GRIEFER,
            keccak256("s7b002-bootstrap-griefer"),
            BYTE_GAS_PRICE + 1,
            500,
            10
        );
        assertEq(candidate.worldDeployer, griefer.worldDeployer, "bootstrap salt must consume the same deployer");
        assertEq(candidate.kernel, griefer.kernel, "nonce-one Kernel address must also be consumed");
        assertTrue(candidate.gasToken != griefer.gasToken);
        assertTrue(candidate.hook != griefer.hook);

        _createAndAssert(griefer, GRIEFER, false);

        vm.expectRevert(
            abi.encodeWithSelector(SwapVMWorldFactory.WorldDeployerCollision.selector, candidate.worldDeployer)
        );
        vm.prank(PUBLISHER);
        factory.createWorld(candidate.params);
        assertEq(candidate.gasToken.code.length, 0, "candidate Token was not rolled back");
        assertGt(candidate.worldDeployer.code.length, 0, "griefer deployer must remain complete");
        assertGt(candidate.kernel.code.length, 0, "griefer Kernel must remain complete");
        assertEq(candidate.hook.code.length, 0, "candidate Hook must not exist");
        _assertUnsealedAndUninitialized(candidate);

        WorldPlan memory recovery = _plan(
            candidate.params.tokenSalt,
            bytes32(uint256(12_004)),
            candidate.params.initialSupply,
            candidate.params.initialHolder,
            candidate.params.distributionCommitment,
            candidate.params.byteGasPrice,
            candidate.params.poolFee,
            candidate.params.tickSpacing
        );
        assertEq(recovery.gasToken, candidate.gasToken, "unconsumed token salt should remain reusable");
        assertTrue(recovery.worldDeployer != candidate.worldDeployer, "recovery deployer was not recomputed");
        assertTrue(recovery.kernel != candidate.kernel, "recovery Kernel was not recomputed");
        assertTrue(recovery.hook != candidate.hook, "recovery Hook was not recomputed");
        assertTrue(recovery.worldId != candidate.worldId, "recovery World id was not recomputed");
        assertTrue(_draftHash(recovery) != _draftHash(candidate), "invalidated draft was reused");

        _createAndAssert(recovery, PUBLISHER, true);
        assertEq(factory.getWorldConfig(worldId).configHash, originalConfigHash, "existing World changed");
    }

    function test_tokenSaltCollisionRollsBackAndRecoversWithRecomputedAddresses() public {
        bytes32 originalConfigHash = factory.getWorldConfig(worldId).configHash;
        WorldPlan memory candidate = _plan(
            bytes32(uint256(13_001)),
            bytes32(uint256(13_002)),
            INITIAL_SUPPLY,
            PUBLISHER,
            keccak256("s7b002-token-candidate"),
            BYTE_GAS_PRICE,
            POOL_FEE,
            TICK_SPACING
        );
        WorldPlan memory griefer = _plan(
            candidate.params.tokenSalt,
            bytes32(uint256(13_003)),
            candidate.params.initialSupply,
            candidate.params.initialHolder,
            keccak256("s7b002-token-griefer"),
            BYTE_GAS_PRICE + 1,
            500,
            10
        );
        assertEq(candidate.gasToken, griefer.gasToken, "token init code and salt must collide");
        assertTrue(candidate.worldDeployer != griefer.worldDeployer);

        _createAndAssert(griefer, GRIEFER, false);
        assertEq(SwapVMGasToken(griefer.gasToken).balanceOf(PUBLISHER), INITIAL_SUPPLY);
        assertEq(
            SwapVMGasToken(griefer.gasToken).balanceOf(GRIEFER), 0, "griefer cannot redirect candidate Token supply"
        );

        vm.expectRevert(bytes(""));
        vm.prank(PUBLISHER);
        factory.createWorld(candidate.params);
        assertEq(candidate.worldDeployer.code.length, 0, "candidate deployer must not be partially created");
        assertEq(candidate.kernel.code.length, 0, "candidate Kernel must not be partially created");
        assertEq(candidate.hook.code.length, 0, "candidate Hook must not be partially created");
        _assertUnsealedAndUninitialized(candidate);

        WorldPlan memory recovery = _plan(
            bytes32(uint256(13_004)),
            candidate.params.bootstrapSalt,
            candidate.params.initialSupply,
            candidate.params.initialHolder,
            candidate.params.distributionCommitment,
            candidate.params.byteGasPrice,
            candidate.params.poolFee,
            candidate.params.tickSpacing
        );
        assertTrue(recovery.gasToken != candidate.gasToken, "recovery Token was not recomputed");
        assertEq(recovery.worldDeployer, candidate.worldDeployer, "unconsumed bootstrap salt should remain reusable");
        assertEq(recovery.kernel, candidate.kernel, "nonce-one Kernel should remain reusable");
        assertTrue(recovery.hook != candidate.hook, "recovery Hook was not recomputed for the new Token");
        assertTrue(recovery.worldId != candidate.worldId, "recovery World id was not recomputed");
        assertTrue(_draftHash(recovery) != _draftHash(candidate), "invalidated draft was reused");

        _createAndAssert(recovery, PUBLISHER, true);
        assertEq(factory.getWorldConfig(worldId).configHash, originalConfigHash, "existing World changed");
    }

    function _plan(
        bytes32 tokenSalt,
        bytes32 bootstrapSalt,
        uint256 initialSupply,
        address initialHolder,
        bytes32 distributionCommitment,
        uint128 byteGasPrice,
        uint24 poolFee,
        int24 tickSpacing
    ) private returns (WorldPlan memory plan) {
        plan.gasToken = factory.predictGasToken(tokenSalt, initialSupply, initialHolder);
        plan.worldDeployer = factory.predictWorldDeployer(bootstrapSalt);
        plan.kernel = factory.predictKernel(plan.worldDeployer);
        bytes memory hookArgs = abi.encode(
            manager,
            SwapVMKernel(plan.kernel),
            plan.gasToken,
            factory.initialProtocolFeeAdmin(),
            factory.feeController(),
            factory.initialProtocolFeeBps(),
            byteGasPrice,
            poolFee,
            tickSpacing
        );
        bytes32 hookSalt;
        vm.pauseGasMetering();
        (plan.hook, hookSalt) = HookMiner.find(
            plan.worldDeployer, REQUIRED_HOOK_FLAGS, SwapVMCreationCodeReader.read(address(hookCodeStore)), hookArgs
        );
        vm.resumeGasMetering();
        plan.params = SwapVMWorldFactory.CreateWorldParams({
            tokenSalt: tokenSalt,
            bootstrapSalt: bootstrapSalt,
            hookSalt: hookSalt,
            predictedKernel: plan.kernel,
            predictedHook: plan.hook,
            initialSupply: initialSupply,
            initialHolder: initialHolder,
            distributionCommitment: distributionCommitment,
            byteGasPrice: byteGasPrice,
            poolFee: poolFee,
            tickSpacing: tickSpacing,
            initialSqrtPriceX96: SQRT_PRICE_1_1
        });
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(plan.gasToken),
            fee: poolFee,
            tickSpacing: tickSpacing,
            hooks: IHooks(plan.hook)
        });
        plan.worldId = PoolId.unwrap(poolKey.toId());
        _assertPredictions(plan);
    }

    function _assertPredictions(WorldPlan memory plan) private view {
        assertEq(
            factory.predictGasToken(plan.params.tokenSalt, plan.params.initialSupply, plan.params.initialHolder),
            plan.gasToken
        );
        assertEq(factory.predictWorldDeployer(plan.params.bootstrapSalt), plan.worldDeployer);
        assertEq(factory.predictKernel(plan.worldDeployer), plan.kernel);
        assertEq(
            factory.predictHook(
                plan.worldDeployer,
                plan.params.hookSalt,
                plan.kernel,
                SwapVMGasToken(plan.gasToken),
                plan.params.byteGasPrice,
                plan.params.poolFee,
                plan.params.tickSpacing
            ),
            plan.hook
        );
        assertEq(uint160(plan.hook) & Hooks.ALL_HOOK_MASK, REQUIRED_HOOK_FLAGS);
    }

    function _createAndAssert(WorldPlan memory plan, address caller, bool assertEvent) private {
        if (assertEvent) vm.recordLogs();
        vm.prank(caller);
        factory.createWorld(plan.params);
        if (assertEvent) _assertWorldSealedEvent(vm.getRecordedLogs(), plan.worldId);
        _assertCreated(plan);
    }

    function _assertCreated(WorldPlan memory plan) private view {
        assertGt(plan.gasToken.code.length, 0);
        assertGt(plan.worldDeployer.code.length, 0);
        assertGt(plan.kernel.code.length, 0);
        assertGt(plan.hook.code.length, 0);
        assertTrue(SwapVMWorldDeployer(plan.worldDeployer).used());

        SwapVMWorldFactory.WorldConfig memory config = factory.getWorldConfig(plan.worldId);
        assertTrue(config.isSealed);
        assertEq(config.configHash, _worldConfigHash(plan.worldId, config));
        assertEq(config.worldDeployer, plan.worldDeployer);
        assertEq(config.gasToken, plan.gasToken);
        assertEq(config.kernel, plan.kernel);
        assertEq(config.hook, plan.hook);
        assertEq(config.initialHolder, plan.params.initialHolder);
        assertEq(config.distributionCommitment, plan.params.distributionCommitment);
        assertEq(config.gasTokenCodeHash, plan.gasToken.codehash);
        assertEq(config.kernelCodeHash, plan.kernel.codehash);
        assertEq(config.hookCodeHash, plan.hook.codehash);
        assertEq(SwapVMKernel(plan.kernel).hook(), plan.hook);
        assertEq(address(SwapVMHook(payable(plan.hook)).kernel()), plan.kernel);
        assertEq(address(SwapVMHook(payable(plan.hook)).gasToken()), plan.gasToken);
        assertEq(SwapVMGasToken(plan.gasToken).totalSupply(), plan.params.initialSupply);
        assertEq(SwapVMGasToken(plan.gasToken).balanceOf(plan.params.initialHolder), plan.params.initialSupply);

        (PoolKey memory storedKey, bool isSealed) = factory.getPoolKey(plan.worldId);
        assertTrue(isSealed);
        assertEq(PoolId.unwrap(storedKey.toId()), plan.worldId);
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(IPoolManager(address(manager)), PoolId.wrap(plan.worldId));
        assertEq(sqrtPriceX96, plan.params.initialSqrtPriceX96);
    }

    function _assertUnsealedAndUninitialized(WorldPlan memory plan) private view {
        assertFalse(factory.getWorldConfig(plan.worldId).isSealed, "failed candidate was sealed");
        (, bool isSealed) = factory.getPoolKey(plan.worldId);
        assertFalse(isSealed, "failed candidate PoolKey was stored");
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(IPoolManager(address(manager)), PoolId.wrap(plan.worldId));
        assertEq(sqrtPriceX96, 0, "failed candidate pool was initialized");
    }

    function _assertWorldSealedEvent(Vm.Log[] memory logs, bytes32 expectedWorldId) private view {
        uint256 matches;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(factory) && logs[i].topics.length == 3
                    && logs[i].topics[0] == WORLD_SEALED_TOPIC && logs[i].topics[1] == expectedWorldId
            ) ++matches;
        }
        assertEq(matches, 1, "missing or duplicate WorldSealed event");
    }

    function _draftHash(WorldPlan memory plan) private pure returns (bytes32) {
        return keccak256(abi.encode(plan.params));
    }

    function _worldConfigHash(bytes32 id, SwapVMWorldFactory.WorldConfig memory config) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                factory.WORLD_CONFIG_TYPEHASH(),
                block.chainid,
                address(factory),
                address(manager),
                factory.poolManagerCodeHash(),
                address(router),
                address(factory.referenceRegistry()),
                id,
                config.worldDeployer,
                config.gasToken,
                config.kernel,
                config.hook,
                config.initialSupply,
                config.initialHolder,
                config.distributionCommitment,
                config.byteGasPrice,
                config.poolFee,
                config.tickSpacing,
                config.initialSqrtPriceX96,
                config.gasTokenCodeHash,
                config.kernelCodeHash,
                config.hookCodeHash
            )
        );
    }
}
