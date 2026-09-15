// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {SwaputerCreationCodeStore} from "../src/SwaputerCreationCodeStore.sol";
import {SwaputerToken} from "../src/SwaputerToken.sol";
import {SwaputerHook} from "../src/SwaputerHook.sol";
import {SwaputerKernel} from "../src/SwaputerKernel.sol";
import {SwaputerWorldFactory} from "../src/SwaputerWorldFactory.sol";

/// @notice Explicit release-operator flow for one immutable Factory and one sealed World.
/// @dev This script does not deploy PoolManager, provide liquidity, publish a manifest, or select a network.
contract Stage7A2DeployScript is Script {
    error EnvironmentValueOutOfRange(string name);
    error ReleasePolicyViolation(string reason);

    string internal constant UNAUDITED_RC2_TAG = "swaputer-v1.2-gas-optimized";
    string internal constant UNAUDITED_RC2_COMMIT = "9fe7b09427d43ae892224094dfdd0af291e71b06";

    function run() external {
        validateReleasePolicy(
            vm.envString("STAGE7A2_RELEASE_ENVIRONMENT"),
            vm.envString("STAGE7A2_AUDIT_STATUS"),
            vm.envString("STAGE7A2_AUDIT_CANDIDATE_TAG"),
            vm.envString("STAGE7A2_AUDIT_CANDIDATE_COMMIT"),
            block.chainid
        );
        uint256 deployerKey = vm.envUint("STAGE7A2_PRIVATE_KEY");
        IPoolManager manager = IPoolManager(vm.envAddress("STAGE7A2_POOL_MANAGER"));
        bytes32 managerCodeHash = vm.envBytes32("STAGE7A2_POOL_MANAGER_CODE_HASH");
        bytes32 tokenSalt = vm.envBytes32("STAGE7A2_TOKEN_SALT");
        bytes32 bootstrapSalt = vm.envBytes32("STAGE7A2_BOOTSTRAP_SALT");
        uint256 initialSupply = vm.envUint("STAGE7A2_INITIAL_SUPPLY");
        address initialHolder = vm.envAddress("STAGE7A2_INITIAL_HOLDER");
        address protocolFeeAdmin = vm.envAddress("SVM_PROTOCOL_FEE_ADMIN");
        address feeController = vm.envAddress("SVM_FEE_CONTROLLER");
        bytes32 distributionCommitment = vm.envBytes32("STAGE7A2_DISTRIBUTION_COMMITMENT");
        uint128 byteGasPrice = _asUint128(vm.envUint("STAGE7A2_BYTE_GAS_PRICE"), "STAGE7A2_BYTE_GAS_PRICE");
        uint24 poolFee = _asUint24(vm.envUint("STAGE7A2_POOL_FEE"), "STAGE7A2_POOL_FEE");
        int24 tickSpacing = _asInt24(vm.envInt("STAGE7A2_TICK_SPACING"), "STAGE7A2_TICK_SPACING");
        uint160 initialSqrtPriceX96 =
            _asUint160(vm.envUint("STAGE7A2_INITIAL_SQRT_PRICE_X96"), "STAGE7A2_INITIAL_SQRT_PRICE_X96");

        vm.startBroadcast(deployerKey);
        SwaputerCreationCodeStore kernelStore = new SwaputerCreationCodeStore(type(SwaputerKernel).creationCode);
        SwaputerCreationCodeStore hookStore = new SwaputerCreationCodeStore(type(SwaputerHook).creationCode);
        SwaputerWorldFactory factory = new SwaputerWorldFactory(
            manager, managerCodeHash, address(kernelStore), address(hookStore), protocolFeeAdmin, feeController
        );
        vm.stopBroadcast();

        address predictedToken = factory.predictGasToken(tokenSalt, initialSupply, initialHolder);
        address predictedWorldDeployer = factory.predictWorldDeployer(bootstrapSalt);
        address predictedKernel = factory.predictKernel(predictedWorldDeployer);
        bytes memory hookArgs = abi.encode(
            manager,
            SwaputerKernel(predictedKernel),
            predictedToken,
            factory.initialProtocolFeeAdmin(),
            factory.feeController(),
            factory.initialProtocolFeeBps(),
            byteGasPrice,
            poolFee,
            tickSpacing
        );
        (address predictedHook, bytes32 hookSalt) = HookMiner.find(
            predictedWorldDeployer,
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG,
            type(SwaputerHook).creationCode,
            hookArgs
        );

        SwaputerWorldFactory.CreateWorldParams memory params = SwaputerWorldFactory.CreateWorldParams({
            tokenSalt: tokenSalt,
            bootstrapSalt: bootstrapSalt,
            hookSalt: hookSalt,
            predictedKernel: predictedKernel,
            predictedHook: predictedHook,
            initialSupply: initialSupply,
            initialHolder: initialHolder,
            distributionCommitment: distributionCommitment,
            byteGasPrice: byteGasPrice,
            poolFee: poolFee,
            tickSpacing: tickSpacing,
            initialSqrtPriceX96: initialSqrtPriceX96
        });

        vm.startBroadcast(deployerKey);
        (bytes32 worldId, SwaputerToken token, SwaputerKernel kernel, SwaputerHook hook) = factory.createWorld(params);
        vm.stopBroadcast();

        SwaputerWorldFactory.WorldConfig memory config = factory.getWorldConfig(worldId);
        console2.log("STAGE7A2_FACTORY", address(factory));
        console2.log("STAGE7A2_ROUTER", factory.router());
        console2.log("STAGE7A2_PROTOCOL_FEE_ADMIN", protocolFeeAdmin);
        console2.log("STAGE7A2_FEE_CONTROLLER", feeController);
        console2.log("STAGE7A2_INITIAL_PROTOCOL_FEE_BPS", factory.initialProtocolFeeBps());
        console2.log("STAGE7A2_REGISTRY", address(factory.referenceRegistry()));
        console2.log("STAGE7A2_WORLD_DEPLOYER", config.worldDeployer);
        console2.log("STAGE7A2_TOKEN", address(token));
        console2.log("STAGE7A2_KERNEL", address(kernel));
        console2.log("STAGE7A2_HOOK", address(hook));
        console2.log("STAGE7A2_WORLD_ID");
        console2.logBytes32(worldId);
        console2.log("STAGE7A2_CONFIG_HASH");
        console2.logBytes32(config.configHash);
        console2.log(
            "Stage 7A2 does not provision liquidity; complete the separate bootstrap checklist before trading."
        );
    }

    /// @notice There is deliberately no override. Stage 7D-U1 only permits local or zero-value testnet rehearsals.
    function validateReleasePolicy(
        string memory environment,
        string memory auditStatus,
        string memory candidateTag,
        string memory candidateCommit,
        uint256 chainId
    ) public pure {
        bytes32 environmentHash = keccak256(bytes(environment));
        bool isLocal = environmentHash == keccak256("local");
        bool isTestnet = environmentHash == keccak256("testnet");
        if (!isLocal && !isTestnet) revert ReleasePolicyViolation("environment");
        if (isLocal && chainId != 31337) revert ReleasePolicyViolation("local-chain-id");
        if (_isKnownMainnet(chainId)) revert ReleasePolicyViolation("mainnet-chain-id");
        if (keccak256(bytes(auditStatus)) != keccak256("unaudited")) {
            revert ReleasePolicyViolation("audit-status");
        }
        if (keccak256(bytes(candidateTag)) != keccak256(bytes(UNAUDITED_RC2_TAG))) {
            revert ReleasePolicyViolation("audit-candidate-tag");
        }
        if (keccak256(bytes(candidateCommit)) != keccak256(bytes(UNAUDITED_RC2_COMMIT))) {
            revert ReleasePolicyViolation("audit-candidate-commit");
        }
    }

    function _isKnownMainnet(uint256 chainId) private pure returns (bool) {
        return chainId == 1 || chainId == 10 || chainId == 56 || chainId == 100 || chainId == 137 || chainId == 250
            || chainId == 324 || chainId == 1101 || chainId == 8453 || chainId == 42161 || chainId == 42220
            || chainId == 43114 || chainId == 59144 || chainId == 81457 || chainId == 534352;
    }

    function _asUint128(uint256 value, string memory name) private pure returns (uint128) {
        if (value > type(uint128).max) revert EnvironmentValueOutOfRange(name);
        return uint128(value);
    }

    function _asUint24(uint256 value, string memory name) private pure returns (uint24) {
        if (value > type(uint24).max) revert EnvironmentValueOutOfRange(name);
        return uint24(value);
    }

    function _asUint16(uint256 value, string memory name) private pure returns (uint16) {
        if (value > type(uint16).max) revert EnvironmentValueOutOfRange(name);
        return uint16(value);
    }

    function _asInt24(int256 value, string memory name) private pure returns (int24) {
        if (value < type(int24).min || value > type(int24).max) revert EnvironmentValueOutOfRange(name);
        return int24(value);
    }

    function _asUint160(uint256 value, string memory name) private pure returns (uint160) {
        if (value > type(uint160).max) revert EnvironmentValueOutOfRange(name);
        return uint160(value);
    }
}
