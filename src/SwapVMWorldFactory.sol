// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {ISwapVMWorldFactory} from "./interfaces/ISwapVMWorldFactory.sol";
import {SwapVMCreationCodeReader} from "./SwapVMCreationCodeStore.sol";
import {SwapVMGasToken} from "./SwapVMGasToken.sol";
import {SwapVMHook} from "./SwapVMHook.sol";
import {SwapVMKernel} from "./SwapVMKernel.sol";
import {SwapVMReferenceRegistry} from "./SwapVMReferenceRegistry.sol";
import {SwapVMRouter} from "./SwapVMRouter.sol";
import {SwapVMWorldDeployer} from "./SwapVMWorldDeployer.sol";

/// @notice Immutable Factory for sealed SwapVM Worlds on one existing PoolManager.
contract SwapVMWorldFactory is ISwapVMWorldFactory {
    using PoolIdLibrary for PoolKey;
    using SwapVMCreationCodeReader for address;

    uint160 private constant REQUIRED_HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    uint16 public constant MAX_PROTOCOL_FEE_BPS = 1_000;
    bytes32 public constant EXPECTED_KERNEL_CREATION_CODE_HASH =
        0x39325bff0318571ddcd4d4d9c7abe2d04b4577abb7629fe6118861ad099809af;
    bytes32 public constant EXPECTED_HOOK_CREATION_CODE_HASH =
        0xa2b1a6fc39aed06ca3000b30b29000cca79adee54b93306a16b82ba03197e844;
    bytes32 public constant WORLD_CONFIG_TYPEHASH = keccak256(
        "SwapVMWorldConfigV1(uint256 chainId,address factory,address poolManager,bytes32 poolManagerCodeHash,address router,address referenceRegistry,bytes32 worldId,address worldDeployer,address gasToken,address kernel,address hook,uint256 initialSupply,address initialHolder,bytes32 distributionCommitment,uint128 byteGasPrice,uint24 poolFee,int24 tickSpacing,uint160 initialSqrtPriceX96,bytes32 gasTokenCodeHash,bytes32 kernelCodeHash,bytes32 hookCodeHash)"
    );

    IPoolManager public immutable override poolManager;
    bytes32 public immutable poolManagerCodeHash;
    address public immutable override router;
    address public immutable initialProtocolFeeAdmin;
    address public immutable feeController;
    uint16 public immutable initialProtocolFeeBps;
    SwapVMReferenceRegistry public immutable referenceRegistry;
    address public immutable kernelCreationCodeStore;
    address public immutable hookCreationCodeStore;
    bytes32 public immutable kernelCreationCodeHash;
    bytes32 public immutable hookCreationCodeHash;

    struct CreateWorldParams {
        bytes32 tokenSalt;
        bytes32 bootstrapSalt;
        bytes32 hookSalt;
        address predictedKernel;
        address predictedHook;
        uint256 initialSupply;
        address initialHolder;
        bytes32 distributionCommitment;
        uint128 byteGasPrice;
        uint24 poolFee;
        int24 tickSpacing;
        uint160 initialSqrtPriceX96;
    }

    struct WorldConfig {
        address worldDeployer;
        address gasToken;
        address kernel;
        address hook;
        uint256 initialSupply;
        address initialHolder;
        bytes32 distributionCommitment;
        uint128 byteGasPrice;
        uint24 poolFee;
        int24 tickSpacing;
        uint160 initialSqrtPriceX96;
        uint64 sealedAtBlock;
        bytes32 gasTokenCodeHash;
        bytes32 kernelCodeHash;
        bytes32 hookCodeHash;
        bytes32 configHash;
        bool isSealed;
    }

    mapping(bytes32 worldId => WorldConfig config) private _worlds;

    event WorldConfigSet(
        bytes32 indexed worldId,
        bytes32 indexed configHash,
        address indexed hook,
        address kernel,
        address gasToken,
        address worldDeployer,
        uint128 byteGasPrice,
        uint24 poolFee,
        int24 tickSpacing,
        uint160 initialSqrtPriceX96
    );
    event WorldSealed(bytes32 indexed worldId, bytes32 indexed configHash);

    error InvalidPoolManager(address manager);
    error InvalidProtocolFeeAdmin(address admin);
    error InvalidFeeController(address controller);
    error InvalidInitialProtocolFee(uint256 supplied, uint256 maximum);
    error PoolManagerCodeHashMismatch(bytes32 expected, bytes32 actual);
    error InvalidInitialSupply();
    error InvalidInitialHolder();
    error InvalidDistributionCommitment();
    error BlockNumberOutOfRange(uint256 blockNumber);
    error WorldDeployerCollision(address predicted);
    error WorldDeployerPredictionMismatch(address expected, address actual);
    error KernelPredictionMismatch(address expected, address supplied);
    error HookPredictionMismatch(address expected, address supplied);
    error InvalidHookPermissionBits(address hook);
    error WorldAlreadyExists(bytes32 worldId);
    error DeploymentBindingMismatch();
    error RuntimeCodeMissing(address target);

    constructor(
        IPoolManager manager,
        bytes32 expectedPoolManagerCodeHash,
        address kernelCreationCodeStore_,
        address hookCreationCodeStore_,
        address protocolFeeAdmin_,
        address feeController_,
        uint16 initialProtocolFeeBps_
    ) {
        if (address(manager) == address(0) || address(manager).code.length == 0) {
            revert InvalidPoolManager(address(manager));
        }
        bytes32 actualManagerCodeHash = address(manager).codehash;
        if (expectedPoolManagerCodeHash == bytes32(0) || actualManagerCodeHash != expectedPoolManagerCodeHash) {
            revert PoolManagerCodeHashMismatch(expectedPoolManagerCodeHash, actualManagerCodeHash);
        }
        poolManager = manager;
        poolManagerCodeHash = expectedPoolManagerCodeHash;
        if (protocolFeeAdmin_ == address(0)) revert InvalidProtocolFeeAdmin(protocolFeeAdmin_);
        if (feeController_ == address(0)) revert InvalidFeeController(feeController_);
        if (initialProtocolFeeBps_ > MAX_PROTOCOL_FEE_BPS) {
            revert InvalidInitialProtocolFee(initialProtocolFeeBps_, MAX_PROTOCOL_FEE_BPS);
        }
        initialProtocolFeeAdmin = protocolFeeAdmin_;
        feeController = feeController_;
        initialProtocolFeeBps = initialProtocolFeeBps_;

        bytes32 actualKernelCreationCodeHash = keccak256(kernelCreationCodeStore_.read());
        bytes32 actualHookCreationCodeHash = keccak256(hookCreationCodeStore_.read());
        if (actualKernelCreationCodeHash != EXPECTED_KERNEL_CREATION_CODE_HASH) {
            revert SwapVMWorldDeployer.KernelCreationCodeMismatch(
                EXPECTED_KERNEL_CREATION_CODE_HASH, actualKernelCreationCodeHash
            );
        }
        if (actualHookCreationCodeHash != EXPECTED_HOOK_CREATION_CODE_HASH) {
            revert SwapVMWorldDeployer.HookCreationCodeMismatch(
                EXPECTED_HOOK_CREATION_CODE_HASH, actualHookCreationCodeHash
            );
        }
        kernelCreationCodeHash = actualKernelCreationCodeHash;
        hookCreationCodeHash = actualHookCreationCodeHash;
        kernelCreationCodeStore = kernelCreationCodeStore_;
        hookCreationCodeStore = hookCreationCodeStore_;

        referenceRegistry = new SwapVMReferenceRegistry();
        router = address(new SwapVMRouter(manager, ISwapVMWorldFactory(address(this))));
    }

    function createWorld(CreateWorldParams calldata params)
        external
        returns (bytes32 worldId, SwapVMGasToken gasToken, SwapVMKernel kernel, SwapVMHook hook)
    {
        if (address(poolManager).codehash != poolManagerCodeHash) {
            revert PoolManagerCodeHashMismatch(poolManagerCodeHash, address(poolManager).codehash);
        }
        if (params.initialSupply == 0) revert InvalidInitialSupply();
        if (params.initialHolder == address(0)) revert InvalidInitialHolder();
        if (params.distributionCommitment == bytes32(0)) revert InvalidDistributionCommitment();
        if (block.number > type(uint64).max) revert BlockNumberOutOfRange(block.number);

        gasToken = new SwapVMGasToken{salt: params.tokenSalt}(params.initialSupply, params.initialHolder);
        address predictedWorldDeployer = predictWorldDeployer(params.bootstrapSalt);
        if (predictedWorldDeployer.code.length != 0) revert WorldDeployerCollision(predictedWorldDeployer);
        address expectedKernel = predictKernel(predictedWorldDeployer);
        if (params.predictedKernel != expectedKernel) {
            revert KernelPredictionMismatch(expectedKernel, params.predictedKernel);
        }
        address expectedHook = predictHook(
            predictedWorldDeployer,
            params.hookSalt,
            expectedKernel,
            gasToken,
            params.byteGasPrice,
            params.poolFee,
            params.tickSpacing
        );
        if (params.predictedHook != expectedHook) revert HookPredictionMismatch(expectedHook, params.predictedHook);
        if (uint160(expectedHook) & Hooks.ALL_HOOK_MASK != REQUIRED_HOOK_FLAGS) {
            revert InvalidHookPermissionBits(expectedHook);
        }

        SwapVMWorldDeployer worldDeployer = new SwapVMWorldDeployer{salt: params.bootstrapSalt}(
            address(this), kernelCreationCodeStore, hookCreationCodeStore, kernelCreationCodeHash, hookCreationCodeHash
        );
        if (address(worldDeployer) != predictedWorldDeployer) {
            revert WorldDeployerPredictionMismatch(predictedWorldDeployer, address(worldDeployer));
        }
        (kernel, hook) = worldDeployer.deploy(
            expectedKernel,
            expectedHook,
            poolManager,
            gasToken,
            initialProtocolFeeAdmin,
            feeController,
            initialProtocolFeeBps,
            params.byteGasPrice,
            params.poolFee,
            params.tickSpacing,
            params.hookSalt
        );
        _validateDeployment(worldDeployer, gasToken, kernel, hook, params);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(gasToken)),
            fee: params.poolFee,
            tickSpacing: params.tickSpacing,
            hooks: IHooks(address(hook))
        });
        worldId = PoolId.unwrap(key.toId());
        if (_worlds[worldId].isSealed) revert WorldAlreadyExists(worldId);
        poolManager.initialize(key, params.initialSqrtPriceX96);
        if (!hook.poolBound() || hook.boundPoolId() != worldId) revert DeploymentBindingMismatch();

        WorldConfig memory config = WorldConfig({
            worldDeployer: address(worldDeployer),
            gasToken: address(gasToken),
            kernel: address(kernel),
            hook: address(hook),
            initialSupply: params.initialSupply,
            initialHolder: params.initialHolder,
            distributionCommitment: params.distributionCommitment,
            byteGasPrice: params.byteGasPrice,
            poolFee: params.poolFee,
            tickSpacing: params.tickSpacing,
            initialSqrtPriceX96: params.initialSqrtPriceX96,
            sealedAtBlock: uint64(block.number),
            gasTokenCodeHash: address(gasToken).codehash,
            kernelCodeHash: address(kernel).codehash,
            hookCodeHash: address(hook).codehash,
            configHash: bytes32(0),
            isSealed: true
        });
        config.configHash = _configHash(worldId, config);
        _worlds[worldId] = config;

        emit WorldConfigSet(
            worldId,
            config.configHash,
            config.hook,
            config.kernel,
            config.gasToken,
            config.worldDeployer,
            config.byteGasPrice,
            config.poolFee,
            config.tickSpacing,
            config.initialSqrtPriceX96
        );
        emit WorldSealed(worldId, config.configHash);
    }

    function getWorldConfig(bytes32 worldId) external view returns (WorldConfig memory) {
        return _worlds[worldId];
    }

    function getPoolKey(bytes32 worldId) external view override returns (PoolKey memory key, bool isSealed) {
        WorldConfig storage config = _worlds[worldId];
        isSealed = config.isSealed;
        if (!isSealed) return (key, false);
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(config.gasToken),
            fee: config.poolFee,
            tickSpacing: config.tickSpacing,
            hooks: IHooks(config.hook)
        });
    }

    function predictGasToken(bytes32 tokenSalt, uint256 initialSupply, address initialHolder)
        public
        view
        returns (address)
    {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(type(SwapVMGasToken).creationCode, abi.encode(initialSupply, initialHolder))
        );
        return _computeCreate2(address(this), tokenSalt, initCodeHash);
    }

    function predictWorldDeployer(bytes32 bootstrapSalt) public view returns (address) {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(SwapVMWorldDeployer).creationCode,
                abi.encode(
                    address(this),
                    kernelCreationCodeStore,
                    hookCreationCodeStore,
                    kernelCreationCodeHash,
                    hookCreationCodeHash
                )
            )
        );
        return _computeCreate2(address(this), bootstrapSalt, initCodeHash);
    }

    function predictKernel(address worldDeployer) public pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", worldDeployer, hex"01")))));
    }

    function predictHook(
        address worldDeployer,
        bytes32 hookSalt,
        address kernel,
        SwapVMGasToken gasToken,
        uint128 byteGasPrice,
        uint24 fee,
        int24 tickSpacing
    ) public view returns (address) {
        bytes memory hookCode = hookCreationCodeStore.read();
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                hookCode,
                abi.encode(
                    poolManager,
                    SwapVMKernel(kernel),
                    gasToken,
                    initialProtocolFeeAdmin,
                    feeController,
                    initialProtocolFeeBps,
                    byteGasPrice,
                    fee,
                    tickSpacing
                )
            )
        );
        return _computeCreate2(worldDeployer, hookSalt, initCodeHash);
    }

    function _validateDeployment(
        SwapVMWorldDeployer worldDeployer,
        SwapVMGasToken gasToken,
        SwapVMKernel kernel,
        SwapVMHook hook,
        CreateWorldParams calldata params
    ) private view {
        if (
            address(worldDeployer).code.length == 0 || address(gasToken).code.length == 0
                || address(kernel).code.length == 0 || address(hook).code.length == 0
        ) revert RuntimeCodeMissing(address(0));
        if (
            worldDeployer.factory() != address(this) || !worldDeployer.used() || kernel.hook() != address(hook)
                || address(hook.kernel()) != address(kernel) || address(hook.poolManager()) != address(poolManager)
                || address(hook.gasToken()) != address(gasToken) || kernel.byteGasPrice() != params.byteGasPrice
                || hook.feeAdmin() != initialProtocolFeeAdmin || hook.feeController() != feeController
                || hook.protocolFeeBps() != initialProtocolFeeBps || hook.byteGasPrice() != params.byteGasPrice
                || hook.poolFee() != params.poolFee || hook.poolTickSpacing() != params.tickSpacing
                || gasToken.totalSupply() != params.initialSupply
                || gasToken.balanceOf(params.initialHolder) != params.initialSupply
        ) revert DeploymentBindingMismatch();
    }

    function _configHash(bytes32 worldId, WorldConfig memory config) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                WORLD_CONFIG_TYPEHASH,
                block.chainid,
                address(this),
                address(poolManager),
                poolManagerCodeHash,
                router,
                address(referenceRegistry),
                worldId,
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

    function _computeCreate2(address deployer, bytes32 salt, bytes32 initCodeHash) private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }
}
