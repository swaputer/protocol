// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {SwapVMCreationCodeStore} from "../../src/SwapVMCreationCodeStore.sol";
import {SwapVMGasToken} from "../../src/SwapVMGasToken.sol";
import {SwapVMHook} from "../../src/SwapVMHook.sol";
import {SwapVMKernel} from "../../src/SwapVMKernel.sol";
import {SwapVMWorldFactory} from "../../src/SwapVMWorldFactory.sol";

interface IBaseMainnetUniversalRouter {
    function poolManager() external view returns (address);
    function V4_POSITION_MANAGER() external view returns (address);
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IBaseMainnetPositionManager {
    function poolManager() external view returns (address);
    function permit2() external view returns (address);
}

/// @notice Read-only fork rehearsal against pinned official Base Mainnet Uniswap deployments.
/// @dev Liquidity is added to the fresh fork-only pool through PoolModifyLiquidityTest. The official
///      PositionManager is never impersonated or mutated; its PoolManager and Permit2 bindings are verified.
contract SwapVMBaseMainnetForkTest is Test {
    using stdJson for string;
    using TransientStateLibrary for IPoolManager;

    uint256 private constant BASE_MAINNET_CHAIN_ID = 8_453;

    address private constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address private constant POSITION_MANAGER = 0x7C5f5A4bBd8fD63184577525326123B519429bDc;
    address private constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address private constant UNIVERSAL_ROUTER = 0xFdf682F51FE81Aa4898F0AE2163d8A55c127fbC7;

    bytes32 private constant POOL_MANAGER_CODE_HASH =
        0x83b2af6e9f3158defc2811cbcb0db71ecf8b2ba2abea39c39e370ac5c6f43eb6;
    bytes32 private constant POSITION_MANAGER_CODE_HASH =
        0x243f9e091ddf11c7c04e28059fdbbf1bab82b72d414fafb8e096c097aaeb622a;
    bytes32 private constant PERMIT2_CODE_HASH = 0xa67739abc3ede9dbdc0491636c67d6a14ac07fab9030c3f509b1eb7b11dff8ed;
    bytes32 private constant UNIVERSAL_ROUTER_CODE_HASH =
        0x4436f45787722467059726381c27a999d0725a7a8b6ae2c4217223987275e3ef;

    uint256 private constant INITIAL_SUPPLY = 1e36;
    uint128 private constant BYTE_GAS_PRICE = 1e12;
    uint24 private constant POOL_FEE = 3_000;
    int24 private constant TICK_SPACING = 60;
    uint160 private constant SQRT_PRICE_1_1 = 1 << 96;
    uint160 private constant SQRT_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint128 private constant VM_INPUT = 0.01 ether;
    uint32 private constant ACTION_LIMIT = 2_000;
    uint32 private constant DEPLOY_EXECUTED_BYTES = 73;
    uint32 private constant CALL_EXECUTED_BYTES = 191;
    // Public deterministic Forge-only signer. It never controls upstream funds and no transaction is broadcast.
    uint256 private constant DETERMINISTIC_TEST_KEY = 0xA11CE;

    IPoolManager private manager;
    SwapVMWorldFactory private factory;
    SwapVMGasToken private gasToken;
    SwapVMKernel private kernel;
    SwapVMHook private hook;
    PoolKey private poolKey;
    bytes32 private worldId;
    address private actor;

    struct StateSnapshot {
        uint64 height;
        uint32 executedBytes;
        uint64 nonce;
        uint64 creatorNonce;
        uint256 supply;
        uint256 fees;
        uint256 feeClaims;
        uint256 actorTokenBalance;
    }

    modifier onlyBaseMainnetFork() {
        vm.skip(block.chainid != BASE_MAINNET_CHAIN_ID, "requires the pinned Base Mainnet fork");
        _;
    }

    function test_baseMainnetOfficialBindingsAndCodeHashes() public onlyBaseMainnetFork {
        assertEq(block.chainid, BASE_MAINNET_CHAIN_ID, "Base Mainnet fork required");
        assertEq(POOL_MANAGER.codehash, POOL_MANAGER_CODE_HASH, "PoolManager code hash drift");
        assertEq(POSITION_MANAGER.codehash, POSITION_MANAGER_CODE_HASH, "PositionManager code hash drift");
        assertEq(PERMIT2.codehash, PERMIT2_CODE_HASH, "Permit2 code hash drift");
        assertEq(UNIVERSAL_ROUTER.codehash, UNIVERSAL_ROUTER_CODE_HASH, "Universal Router code hash drift");

        IBaseMainnetUniversalRouter officialRouter = IBaseMainnetUniversalRouter(UNIVERSAL_ROUTER);
        IBaseMainnetPositionManager officialPositionManager = IBaseMainnetPositionManager(POSITION_MANAGER);
        assertEq(officialRouter.poolManager(), POOL_MANAGER, "Universal Router PoolManager binding drift");
        assertEq(
            officialRouter.V4_POSITION_MANAGER(), POSITION_MANAGER, "Universal Router PositionManager binding drift"
        );
        assertEq(officialPositionManager.poolManager(), POOL_MANAGER, "PositionManager PoolManager binding drift");
        assertEq(officialPositionManager.permit2(), PERMIT2, "PositionManager Permit2 binding drift");
    }

    function test_baseMainnetFreshWorldOfficialUniversalRouterDeployAndCall() public onlyBaseMainnetFork {
        _deployFreshWorldAndLiquidity();

        (bytes memory packageBytes, bytes32 codeHash) = _conformancePackage();
        bytes32 actorId = kernel.eoaAccountId(actor);
        uint64 heightBefore = kernel.executionHeight(worldId);
        uint64 nonceBefore = kernel.nonces(worldId, actorId);
        uint64 creatorNonceBefore = kernel.creatorNonce(worldId, actorId);
        bytes32 programId = kernel.contractAccountId(worldId, actorId, creatorNonceBefore, codeHash);
        uint256 supplyBefore = gasToken.totalSupply();
        uint256 feesBefore = hook.accruedProtocolFees();
        uint256 actorBalanceBefore = gasToken.balanceOf(actor);
        uint256 feePerSwap = hook.protocolFee(VM_INPUT);

        bytes memory deployPayload =
            abi.encodePacked(bytes4(uint32(packageBytes.length)), packageBytes, abi.encode(uint256(5)));
        _executeOfficialRouter(
            _signedAction(
                SwapVMKernel.RootOp.DEPLOY, codeHash, deployPayload, nonceBefore, ACTION_LIMIT, UNIVERSAL_ROUTER
            )
        );

        assertEq(kernel.executionHeight(worldId), heightBefore + 1, "DEPLOY height");
        assertEq(kernel.nonces(worldId, actorId), nonceBefore + 1, "DEPLOY nonce");
        assertEq(kernel.creatorNonce(worldId, actorId), creatorNonceBefore + 1, "DEPLOY creator nonce");
        assertEq(kernel.programCodeHash(worldId, programId), codeHash, "DEPLOY program code hash");
        assertEq(kernel.executedBytes(worldId), DEPLOY_EXECUTED_BYTES, "DEPLOY executed bytes");
        assertEq(_queryUint(programId, "getScalar()", bytes("")), 5, "constructor state");
        assertEq(
            supplyBefore - gasToken.totalSupply(),
            uint256(DEPLOY_EXECUTED_BYTES) * BYTE_GAS_PRICE,
            "DEPLOY byte gas burn"
        );
        assertEq(hook.accruedProtocolFees(), feesBefore + feePerSwap, "DEPLOY protocol fee");

        bytes memory callPayload =
            abi.encodePacked(bytes4(keccak256("controlFlow(uint256,bool)")), abi.encode(uint256(4), true));
        _executeOfficialRouter(
            _signedAction(
                SwapVMKernel.RootOp.CALL, programId, callPayload, nonceBefore + 1, ACTION_LIMIT, UNIVERSAL_ROUTER
            )
        );

        uint256 expectedBurn = uint256(DEPLOY_EXECUTED_BYTES + CALL_EXECUTED_BYTES) * BYTE_GAS_PRICE;
        assertEq(kernel.executionHeight(worldId), heightBefore + 2, "CALL height");
        assertEq(kernel.nonces(worldId, actorId), nonceBefore + 2, "CALL nonce");
        assertEq(kernel.creatorNonce(worldId, actorId), creatorNonceBefore + 1, "CALL creator nonce");
        assertEq(kernel.executedBytes(worldId), CALL_EXECUTED_BYTES, "CALL executed bytes");
        assertEq(_queryUint(programId, "getScalar()", bytes("")), 14, "CALL state");
        assertEq(supplyBefore - gasToken.totalSupply(), expectedBurn, "total byte gas burn");
        assertEq(hook.accruedProtocolFees(), feesBefore + (feePerSwap * 2), "total protocol fee");
        assertEq(_nativeFeeClaimBalance(), hook.accruedProtocolFees(), "accounted native fee claims");
        assertGt(gasToken.balanceOf(actor), actorBalanceBefore, "actor receives net gas token output");
        assertEq(manager.getNonzeroDeltaCount(), 0, "PoolManager deltas settled");
    }

    function test_baseMainnetUniversalRouterAdversarialRollback() public onlyBaseMainnetFork {
        _deployFreshWorldAndLiquidity();

        (bytes memory packageBytes, bytes32 codeHash) = _conformancePackage();
        bytes32 actorId = kernel.eoaAccountId(actor);
        uint64 nonceBefore = kernel.nonces(worldId, actorId);
        bytes32 programId = kernel.contractAccountId(worldId, actorId, 0, codeHash);
        bytes memory deployPayload =
            abi.encodePacked(bytes4(uint32(packageBytes.length)), packageBytes, abi.encode(uint256(5)));
        SwapVMKernel.VMEnvelope memory deployAction = _signedAction(
            SwapVMKernel.RootOp.DEPLOY, codeHash, deployPayload, nonceBefore, ACTION_LIMIT, UNIVERSAL_ROUTER
        );

        StateSnapshot memory pristine = _snapshot(actorId);
        deployAction.recipient = address(0xBEEF);
        vm.expectRevert();
        _executeOfficialRouter(deployAction);
        _assertSnapshot(pristine, actorId, "mutated envelope");

        deployAction = _signedAction(
            SwapVMKernel.RootOp.DEPLOY, codeHash, deployPayload, nonceBefore, ACTION_LIMIT, UNIVERSAL_ROUTER
        );
        _executeOfficialRouter(deployAction);
        StateSnapshot memory deployed = _snapshot(actorId);

        vm.expectRevert();
        _executeOfficialRouter(deployAction);
        _assertSnapshot(deployed, actorId, "replay");

        bytes memory callPayload =
            abi.encodePacked(bytes4(keccak256("controlFlow(uint256,bool)")), abi.encode(uint256(4), true));
        SwapVMKernel.VMEnvelope memory wrongRouter = _signedAction(
            SwapVMKernel.RootOp.CALL, programId, callPayload, nonceBefore + 1, ACTION_LIMIT, factory.router()
        );
        vm.expectRevert();
        _executeOfficialRouter(wrongRouter);
        _assertSnapshot(deployed, actorId, "wrong router binding");

        SwapVMKernel.VMEnvelope memory outOfByteGas =
            _signedAction(SwapVMKernel.RootOp.CALL, programId, callPayload, nonceBefore + 1, 1, UNIVERSAL_ROUTER);
        vm.expectRevert();
        _executeOfficialRouter(outOfByteGas);
        _assertSnapshot(deployed, actorId, "out of byte gas");
    }

    function _deployFreshWorldAndLiquidity() private {
        assertEq(block.chainid, BASE_MAINNET_CHAIN_ID, "Base Mainnet fork required");
        assertEq(POOL_MANAGER.codehash, POOL_MANAGER_CODE_HASH, "PoolManager code hash drift");
        manager = IPoolManager(POOL_MANAGER);
        actor = vm.addr(DETERMINISTIC_TEST_KEY);
        vm.deal(address(this), 30_000 ether);
        vm.deal(actor, 100 ether);

        bytes memory canonicalKernelCreationCode = vm.getCode("src/SwapVMKernel.sol:SwapVMKernel");
        bytes memory canonicalHookCreationCode = vm.getCode("src/SwapVMHook.sol:SwapVMHook");
        SwapVMCreationCodeStore kernelCodeStore = new SwapVMCreationCodeStore(canonicalKernelCreationCode);
        SwapVMCreationCodeStore hookCodeStore = new SwapVMCreationCodeStore(canonicalHookCreationCode);
        factory = new SwapVMWorldFactory(
            manager,
            POOL_MANAGER_CODE_HASH,
            address(kernelCodeStore),
            address(hookCodeStore),
            address(this),
            address(this)
        );

        bytes32 tokenSalt = keccak256("swaputer-base-mainnet-fork-token");
        bytes32 bootstrapSalt = keccak256("swaputer-base-mainnet-fork-world");
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
            canonicalHookCreationCode,
            hookArgs
        );
        SwapVMWorldFactory.CreateWorldParams memory params = SwapVMWorldFactory.CreateWorldParams({
            tokenSalt: tokenSalt,
            bootstrapSalt: bootstrapSalt,
            hookSalt: hookSalt,
            predictedKernel: predictedKernel,
            predictedHook: predictedHook,
            initialSupply: INITIAL_SUPPLY,
            initialHolder: address(this),
            distributionCommitment: keccak256("swaputer-base-mainnet-fork-distribution"),
            byteGasPrice: BYTE_GAS_PRICE,
            poolFee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            initialSqrtPriceX96: SQRT_PRICE_1_1
        });
        (worldId, gasToken, kernel, hook) = factory.createWorld(params);
        bool isSealed;
        (poolKey, isSealed) = factory.getPoolKey(worldId);
        assertTrue(isSealed, "fresh world sealed");
        assertEq(address(poolKey.hooks), address(hook), "fresh hook binding");

        // Fork-local test router avoids fabricating an LP NFT or impersonating the official PositionManager.
        PoolModifyLiquidityTest liquidityRouter = new PoolModifyLiquidityTest(manager);
        gasToken.approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity{value: 20_000 ether}(
            poolKey,
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e23, salt: bytes32(0)}),
            bytes("")
        );
        gasToken.approve(address(liquidityRouter), 0);
        assertEq(manager.getNonzeroDeltaCount(), 0, "liquidity deltas settled");
    }

    function _conformancePackage() private view returns (bytes memory packageBytes, bytes32 codeHash) {
        string memory fixture = vm.readFile("tooling/tinysol/fixtures/compiler/Conformance.json");
        packageBytes = fixture.readBytes(".package");
        codeHash = fixture.readBytes32(".codeHash");
        assertEq(keccak256(packageBytes), codeHash, "compiler fixture hash");
    }

    function _executeOfficialRouter(SwapVMKernel.VMEnvelope memory envelope) private {
        bytes[] memory actionParams = new bytes[](3);
        actionParams[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: true,
                amountIn: VM_INPUT,
                amountOutMinimum: envelope.minNetTokenOut,
                minHopPriceX36: 0,
                hookData: abi.encode(envelope)
            })
        );
        actionParams[1] = abi.encode(Currency.wrap(address(0)), uint256(VM_INPUT));
        actionParams[2] = abi.encode(poolKey.currency1, uint256(envelope.minNetTokenOut));

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(hex"060c0f", actionParams);
        vm.prank(actor);
        IBaseMainnetUniversalRouter(UNIVERSAL_ROUTER).execute{value: VM_INPUT}(hex"10", inputs, envelope.deadline);
    }

    function _signedAction(
        SwapVMKernel.RootOp op,
        bytes32 target,
        bytes memory payload,
        uint64 nonce,
        uint32 byteGasLimit,
        address routerBinding
    ) private view returns (SwapVMKernel.VMEnvelope memory envelope) {
        envelope = SwapVMKernel.VMEnvelope({
            op: op,
            worldId: worldId,
            actor: actor,
            targetOrCodeHash: target,
            payload: payload,
            byteGasLimit: byteGasLimit,
            minNetTokenOut: 1,
            nonce: nonce,
            deadline: uint64(block.timestamp + 10 minutes),
            recipient: actor,
            authorizedExecutor: address(0),
            signature: bytes("")
        });
        bytes32 structHash = keccak256(
            abi.encode(
                kernel.VM_ACTION_TYPEHASH(),
                uint8(envelope.op),
                envelope.worldId,
                envelope.actor,
                envelope.targetOrCodeHash,
                keccak256(envelope.payload),
                envelope.byteGasLimit,
                envelope.minNetTokenOut,
                VM_INPUT,
                SQRT_PRICE_LIMIT,
                envelope.recipient,
                routerBinding,
                envelope.authorizedExecutor,
                envelope.nonce,
                envelope.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", kernel.domainSeparator(worldId), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(DETERMINISTIC_TEST_KEY, digest);
        envelope.signature = abi.encodePacked(r, s, v);
    }

    function _queryUint(bytes32 programId, string memory signature, bytes memory arguments)
        private
        view
        returns (uint256 value)
    {
        (bytes memory output,) = kernel.staticCall(
            worldId, programId, abi.encodePacked(bytes4(keccak256(bytes(signature))), arguments), ACTION_LIMIT
        );
        assertEq(output.length, 32, "query output width");
        value = abi.decode(output, (uint256));
    }

    function _snapshot(bytes32 actorId) private view returns (StateSnapshot memory state) {
        state = StateSnapshot({
            height: kernel.executionHeight(worldId),
            executedBytes: kernel.executedBytes(worldId),
            nonce: kernel.nonces(worldId, actorId),
            creatorNonce: kernel.creatorNonce(worldId, actorId),
            supply: gasToken.totalSupply(),
            fees: hook.accruedProtocolFees(),
            feeClaims: _nativeFeeClaimBalance(),
            actorTokenBalance: gasToken.balanceOf(actor)
        });
    }

    function _assertSnapshot(StateSnapshot memory expected, bytes32 actorId, string memory reason) private view {
        assertEq(kernel.executionHeight(worldId), expected.height, string.concat(reason, ": height"));
        assertEq(kernel.executedBytes(worldId), expected.executedBytes, string.concat(reason, ": bytes"));
        assertEq(kernel.nonces(worldId, actorId), expected.nonce, string.concat(reason, ": nonce"));
        assertEq(kernel.creatorNonce(worldId, actorId), expected.creatorNonce, string.concat(reason, ": creator nonce"));
        assertEq(gasToken.totalSupply(), expected.supply, string.concat(reason, ": supply"));
        assertEq(hook.accruedProtocolFees(), expected.fees, string.concat(reason, ": fees"));
        assertEq(_nativeFeeClaimBalance(), expected.feeClaims, string.concat(reason, ": fee claims"));
        assertEq(gasToken.balanceOf(actor), expected.actorTokenBalance, string.concat(reason, ": actor token"));
        assertEq(manager.getNonzeroDeltaCount(), 0, string.concat(reason, ": PoolManager deltas"));
    }

    function _nativeFeeClaimBalance() private view returns (uint256) {
        return manager.balanceOf(address(hook), Currency.wrap(address(0)).toId());
    }

    receive() external payable {}
}
