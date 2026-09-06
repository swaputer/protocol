// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {SwapVMGasToken} from "../../src/SwapVMGasToken.sol";
import {SwapVMHook} from "../../src/SwapVMHook.sol";
import {SwapVMKernel} from "../../src/SwapVMKernel.sol";
import {SwapVMWorldFactory} from "../../src/SwapVMWorldFactory.sol";
import {SwapVMStage7A2Test} from "../SwapVMStage7A2.t.sol";

contract SwapVMStage7BFactoryHandler is Test {
    SwapVMWorldFactory private immutable _factory;
    SwapVMWorldFactory.CreateWorldParams private _duplicate;
    SwapVMWorldFactory.CreateWorldParams private _validSecond;
    SwapVMWorldFactory.CreateWorldParams private _wrongKernel;
    SwapVMWorldFactory.CreateWorldParams private _wrongHook;
    SwapVMWorldFactory.CreateWorldParams private _wrongPermissions;

    bytes32 public createdWorldId;
    uint256 public failedAttempts;
    bool public secondCreated;

    constructor(
        SwapVMWorldFactory factory_,
        SwapVMWorldFactory.CreateWorldParams memory duplicate_,
        SwapVMWorldFactory.CreateWorldParams memory validSecond_,
        SwapVMWorldFactory.CreateWorldParams memory wrongKernel_,
        SwapVMWorldFactory.CreateWorldParams memory wrongHook_,
        SwapVMWorldFactory.CreateWorldParams memory wrongPermissions_
    ) {
        _factory = factory_;
        _duplicate = duplicate_;
        _validSecond = validSecond_;
        _wrongKernel = wrongKernel_;
        _wrongHook = wrongHook_;
        _wrongPermissions = wrongPermissions_;
    }

    function attemptDuplicate(address caller) external {
        _expectFailure(_duplicate, caller);
    }

    function attemptWrongKernel(address caller) external {
        _expectFailure(_wrongKernel, caller);
    }

    function attemptWrongHook(address caller) external {
        _expectFailure(_wrongHook, caller);
    }

    function attemptWrongPermissionBits(address caller) external {
        _expectFailure(_wrongPermissions, caller);
    }

    function createSecondWorld(address caller) external {
        vm.assume(caller != address(0));
        vm.prank(caller);
        try _factory.createWorld(_validSecond) returns (bytes32 id, SwapVMGasToken, SwapVMKernel, SwapVMHook) {
            assertFalse(secondCreated, "one CREATE2 tuple cannot create twice");
            secondCreated = true;
            createdWorldId = id;
        } catch {
            assertTrue(secondCreated, "fresh valid tuple unexpectedly failed");
            failedAttempts += 1;
        }
    }

    function _expectFailure(SwapVMWorldFactory.CreateWorldParams storage params, address caller) private {
        vm.assume(caller != address(0));
        vm.prank(caller);
        try _factory.createWorld(params) {
            fail();
        } catch {
            failedAttempts += 1;
        }
    }
}

contract SwapVMStage7BFactoryInvariantTest is StdInvariant, SwapVMStage7A2Test {
    SwapVMStage7BFactoryHandler private handler;
    bytes32 private originalConfigHash;

    function setUp() public override {
        super.setUp();
        originalConfigHash = factory.getWorldConfig(worldId).configHash;

        SwapVMWorldFactory.CreateWorldParams memory duplicate = _worldParams(bytes32(uint256(1)), bytes32(uint256(2)));
        SwapVMWorldFactory.CreateWorldParams memory validSecond = _customWorldParams(
            bytes32(uint256(7_001)),
            bytes32(uint256(7_002)),
            7e35,
            address(0x7007),
            7e12,
            500,
            10,
            TickMath.getSqrtPriceAtTick(120)
        );

        SwapVMWorldFactory.CreateWorldParams memory wrongKernel =
            _unminedParams(bytes32(uint256(7_101)), bytes32(uint256(7_102)), bytes32(0));
        wrongKernel.predictedKernel = address(uint160(wrongKernel.predictedKernel) + 1);

        SwapVMWorldFactory.CreateWorldParams memory wrongHook =
            _unminedParams(bytes32(uint256(7_201)), bytes32(uint256(7_202)), bytes32(0));
        wrongHook.predictedHook = address(uint160(wrongHook.predictedHook) + 1);

        SwapVMWorldFactory.CreateWorldParams memory wrongPermissions =
            _paramsWithInvalidPermissionBits(bytes32(uint256(7_301)), bytes32(uint256(7_302)));

        handler =
            new SwapVMStage7BFactoryHandler(factory, duplicate, validSecond, wrongKernel, wrongHook, wrongPermissions);
        targetContract(address(handler));
    }

    function invariant_originalWorldIsImmutableAndSealed() public view {
        SwapVMWorldFactory.WorldConfig memory config = factory.getWorldConfig(worldId);
        assertTrue(config.isSealed);
        assertEq(config.configHash, originalConfigHash);
        assertEq(config.configHash, _worldConfigHash(worldId, config));
        assertEq(config.kernel, address(kernel));
        assertEq(config.hook, address(hook));
        assertEq(config.gasToken, address(token));
    }

    function invariant_anyCreatedSecondWorldIsCompleteAndBound() public view {
        bytes32 secondId = handler.createdWorldId();
        if (secondId == bytes32(0)) return;
        SwapVMWorldFactory.WorldConfig memory config = factory.getWorldConfig(secondId);
        assertTrue(handler.secondCreated());
        assertTrue(config.isSealed);
        assertEq(config.configHash, _worldConfigHash(secondId, config));
        assertEq(SwapVMKernel(config.kernel).hook(), config.hook);
        assertEq(address(SwapVMHook(payable(config.hook)).kernel()), config.kernel);
        assertEq(address(SwapVMHook(payable(config.hook)).poolManager()), address(manager));
        assertEq(
            uint160(config.hook) & Hooks.ALL_HOOK_MASK,
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
    }

    function _unminedParams(bytes32 tokenSalt, bytes32 bootstrapSalt, bytes32 hookSalt)
        private
        view
        returns (SwapVMWorldFactory.CreateWorldParams memory params)
    {
        address predictedToken = factory.predictGasToken(tokenSalt, INITIAL_SUPPLY, address(this));
        address predictedDeployer = factory.predictWorldDeployer(bootstrapSalt);
        address predictedKernel = factory.predictKernel(predictedDeployer);
        address predictedHook = factory.predictHook(
            predictedDeployer,
            hookSalt,
            predictedKernel,
            SwapVMGasToken(predictedToken),
            BYTE_GAS_PRICE,
            POOL_FEE,
            TICK_SPACING
        );
        params = SwapVMWorldFactory.CreateWorldParams({
            tokenSalt: tokenSalt,
            bootstrapSalt: bootstrapSalt,
            hookSalt: hookSalt,
            predictedKernel: predictedKernel,
            predictedHook: predictedHook,
            initialSupply: INITIAL_SUPPLY,
            initialHolder: address(this),
            distributionCommitment: keccak256("stage7b-factory-invariant-distribution"),
            byteGasPrice: BYTE_GAS_PRICE,
            poolFee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            initialSqrtPriceX96: SQRT_PRICE_1_1
        });
    }

    function _paramsWithInvalidPermissionBits(bytes32 tokenSalt, bytes32 bootstrapSalt)
        private
        view
        returns (SwapVMWorldFactory.CreateWorldParams memory params)
    {
        for (uint256 rawSalt; rawSalt < 256; rawSalt++) {
            params = _unminedParams(tokenSalt, bootstrapSalt, bytes32(rawSalt));
            if (
                uint160(params.predictedHook) & Hooks.ALL_HOOK_MASK
                    != (Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                            | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG)
            ) return params;
        }
        revert("unable to find invalid permission address");
    }

    function _customWorldParams(
        bytes32 tokenSalt,
        bytes32 bootstrapSalt,
        uint256 supply,
        address holder,
        uint128 gasPrice,
        uint24 fee,
        int24 tickSpacing,
        uint160 initialPrice
    ) private view returns (SwapVMWorldFactory.CreateWorldParams memory params) {
        address predictedToken = factory.predictGasToken(tokenSalt, supply, holder);
        address predictedDeployer = factory.predictWorldDeployer(bootstrapSalt);
        address predictedKernel = factory.predictKernel(predictedDeployer);
        bytes memory hookArgs = abi.encode(
            manager,
            SwapVMKernel(predictedKernel),
            predictedToken,
            factory.initialProtocolFeeAdmin(),
            factory.feeController(),
            factory.initialProtocolFeeBps(),
            gasPrice,
            fee,
            tickSpacing
        );
        (address predictedHook, bytes32 hookSalt) = HookMiner.find(
            predictedDeployer,
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
            initialSupply: supply,
            initialHolder: holder,
            distributionCommitment: keccak256("stage7b-custom-world-distribution"),
            byteGasPrice: gasPrice,
            poolFee: fee,
            tickSpacing: tickSpacing,
            initialSqrtPriceX96: initialPrice
        });
    }
}
