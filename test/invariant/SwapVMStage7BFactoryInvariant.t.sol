// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {SwaputerToken} from "../../src/SwaputerToken.sol";
import {SwaputerHook} from "../../src/SwaputerHook.sol";
import {SwaputerKernel} from "../../src/SwaputerKernel.sol";
import {SwaputerWorldFactory} from "../../src/SwaputerWorldFactory.sol";
import {SwapVMStage7A2Test} from "../SwapVMStage7A2.t.sol";

contract SwapVMStage7BFactoryHandler is Test {
    SwaputerWorldFactory private immutable _factory;
    SwaputerWorldFactory.CreateWorldParams private _duplicate;
    SwaputerWorldFactory.CreateWorldParams private _validSecond;
    SwaputerWorldFactory.CreateWorldParams private _wrongKernel;
    SwaputerWorldFactory.CreateWorldParams private _wrongHook;
    SwaputerWorldFactory.CreateWorldParams private _wrongPermissions;

    bytes32 public createdWorldId;
    uint256 public failedAttempts;
    bool public secondCreated;

    constructor(
        SwaputerWorldFactory factory_,
        SwaputerWorldFactory.CreateWorldParams memory duplicate_,
        SwaputerWorldFactory.CreateWorldParams memory validSecond_,
        SwaputerWorldFactory.CreateWorldParams memory wrongKernel_,
        SwaputerWorldFactory.CreateWorldParams memory wrongHook_,
        SwaputerWorldFactory.CreateWorldParams memory wrongPermissions_
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
        try _factory.createWorld(_validSecond) returns (bytes32 id, SwaputerToken, SwaputerKernel, SwaputerHook) {
            assertFalse(secondCreated, "one CREATE2 tuple cannot create twice");
            secondCreated = true;
            createdWorldId = id;
        } catch {
            assertTrue(secondCreated, "fresh valid tuple unexpectedly failed");
            failedAttempts += 1;
        }
    }

    function _expectFailure(SwaputerWorldFactory.CreateWorldParams storage params, address caller) private {
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

        SwaputerWorldFactory.CreateWorldParams memory duplicate = _worldParams(bytes32(uint256(1)), bytes32(uint256(2)));
        SwaputerWorldFactory.CreateWorldParams memory validSecond = _customWorldParams(
            bytes32(uint256(7_001)),
            bytes32(uint256(7_002)),
            7e35,
            address(0x7007),
            7e12,
            500,
            10,
            TickMath.getSqrtPriceAtTick(120)
        );

        SwaputerWorldFactory.CreateWorldParams memory wrongKernel =
            _unminedParams(bytes32(uint256(7_101)), bytes32(uint256(7_102)), bytes32(0));
        wrongKernel.predictedKernel = address(uint160(wrongKernel.predictedKernel) + 1);

        SwaputerWorldFactory.CreateWorldParams memory wrongHook =
            _unminedParams(bytes32(uint256(7_201)), bytes32(uint256(7_202)), bytes32(0));
        wrongHook.predictedHook = address(uint160(wrongHook.predictedHook) + 1);

        SwaputerWorldFactory.CreateWorldParams memory wrongPermissions =
            _paramsWithInvalidPermissionBits(bytes32(uint256(7_301)), bytes32(uint256(7_302)));

        handler =
            new SwapVMStage7BFactoryHandler(factory, duplicate, validSecond, wrongKernel, wrongHook, wrongPermissions);
        targetContract(address(handler));
    }

    function invariant_originalWorldIsImmutableAndSealed() public view {
        SwaputerWorldFactory.WorldConfig memory config = factory.getWorldConfig(worldId);
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
        SwaputerWorldFactory.WorldConfig memory config = factory.getWorldConfig(secondId);
        assertTrue(handler.secondCreated());
        assertTrue(config.isSealed);
        assertEq(config.configHash, _worldConfigHash(secondId, config));
        assertEq(SwaputerKernel(config.kernel).hook(), config.hook);
        assertEq(address(SwaputerHook(payable(config.hook)).kernel()), config.kernel);
        assertEq(address(SwaputerHook(payable(config.hook)).poolManager()), address(manager));
        assertEq(
            uint160(config.hook) & Hooks.ALL_HOOK_MASK,
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
    }

    function _unminedParams(bytes32 tokenSalt, bytes32 bootstrapSalt, bytes32 hookSalt)
        private
        view
        returns (SwaputerWorldFactory.CreateWorldParams memory params)
    {
        address predictedToken = factory.predictGasToken(tokenSalt, INITIAL_SUPPLY, address(this));
        address predictedDeployer = factory.predictWorldDeployer(bootstrapSalt);
        address predictedKernel = factory.predictKernel(predictedDeployer);
        address predictedHook = factory.predictHook(
            predictedDeployer,
            hookSalt,
            predictedKernel,
            SwaputerToken(predictedToken),
            BYTE_GAS_PRICE,
            POOL_FEE,
            TICK_SPACING
        );
        params = SwaputerWorldFactory.CreateWorldParams({
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
        returns (SwaputerWorldFactory.CreateWorldParams memory params)
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
    ) private view returns (SwaputerWorldFactory.CreateWorldParams memory params) {
        address predictedToken = factory.predictGasToken(tokenSalt, supply, holder);
        address predictedDeployer = factory.predictWorldDeployer(bootstrapSalt);
        address predictedKernel = factory.predictKernel(predictedDeployer);
        bytes memory hookArgs = abi.encode(
            manager,
            SwaputerKernel(predictedKernel),
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
            type(SwaputerHook).creationCode,
            hookArgs
        );
        params = SwaputerWorldFactory.CreateWorldParams({
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
