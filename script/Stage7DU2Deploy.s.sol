// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {SwaputerCreationCodeStore} from "../src/SwaputerCreationCodeStore.sol";
import {SwaputerToken} from "../src/SwaputerToken.sol";
import {SwaputerHook} from "../src/SwaputerHook.sol";
import {SwaputerKernel} from "../src/SwaputerKernel.sol";
import {SwaputerWorldFactory} from "../src/SwaputerWorldFactory.sol";

abstract contract Stage7DU2BaseSepoliaScript is Script {
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    IPoolManager internal constant MANAGER = IPoolManager(0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408);
    bytes32 internal constant MANAGER_CODE_HASH = 0x03c45db6d09b14da7c1f7239a5a49697f976d395277e6d2acb6fbed3f9e0249f;
    address internal constant DEPLOYER = 0x590a77Ec892bB78206bcad2444B62d1bC31A2D03;
    address internal constant KERNEL_STORE = 0x4AF2984F528fC0c4F33Cb0e2F566A6Be3362f44d;
    address internal constant HOOK_STORE = 0x659b39dbAb1E0cd25c83bfe3B4338D41cF123B35;
    address internal constant FACTORY = 0xF327e35FEA7EE7c92a765D1f00eD6A2A3db5b340;
    address internal constant REGISTRY = 0xa4488C58Cd94E09f578262a08973175C36273F03;
    address internal constant ROUTER = 0xEDAbF849F3F74FE3C92FCEa50968332f77B06F07;
    address internal constant TOKEN = 0xe7bE2F5Af5281D81394c1ed22a27EDe5fdbb8775;
    address internal constant WORLD_DEPLOYER = 0x9529f25DA0294180B11fB461e67f21D523174b71;
    address internal constant KERNEL = 0xA048C894A738185c24B4A5020Fb6708dAb160283;
    address internal constant HOOK = 0x8166eb00f52399Abdf725d1bB42A8344928A0044;

    bytes32 internal constant KERNEL_STORE_CODE_HASH =
        0x55dadc60aee012382d97c092c4a36e0f6f2a052af9f0a03ab61105111fd57ef1;
    bytes32 internal constant HOOK_STORE_CODE_HASH = 0x051a9d05c4b871e4567c39f8c0917b827978be2d7b4116f62b9122c604400ed4;
    bytes32 internal constant TOKEN_SALT = 0x3759c435ce279ce074811ee5a2644fe5b2ef4bb873ca21ad5ee903565433faef;
    bytes32 internal constant BOOTSTRAP_SALT = 0xdf010f36bf156164481ba9fe4a254f6d5b826a38894ac0106bf86fd1ad573d5e;
    bytes32 internal constant HOOK_SALT = 0x000000000000000000000000000000000000000000000000000000000000488c;
    bytes32 internal constant DISTRIBUTION_COMMITMENT =
        0x66535c0450d86529bbd9d36149c4251e78d0966e2d63426afc84951727e66170;
    uint256 internal constant INITIAL_SUPPLY = 1_000_000_000 ether;
    uint128 internal constant BYTE_GAS_PRICE = 1_000_000_000_000;
    uint24 internal constant POOL_FEE = 3_000;
    int24 internal constant TICK_SPACING = 60;
    uint160 internal constant INITIAL_SQRT_PRICE_X96 = 1 << 96;

    function _key() internal returns (uint256 key) {
        require(block.chainid == BASE_SEPOLIA_CHAIN_ID, "BASE_SEPOLIA_ONLY");
        require(address(MANAGER).codehash == MANAGER_CODE_HASH, "POOL_MANAGER_CODE_HASH_MISMATCH");
        key = vm.envUint("STAGE7A2_PRIVATE_KEY");
        require(vm.addr(key) == DEPLOYER, "DEPLOYER_MISMATCH");
    }
}

/// @notice First public-testnet checkpoint: deploy only the two immutable creation-code stores.
contract Stage7DU2StoreBootstrapScript is Stage7DU2BaseSepoliaScript {
    function run() external {
        uint256 key = _key();
        require(vm.getNonce(DEPLOYER) == 754, "DEPLOYER_NONCE_MISMATCH");
        require(KERNEL_STORE.code.length == 0 && HOOK_STORE.code.length == 0, "STORE_ADDRESS_OCCUPIED");

        vm.startBroadcast(key);
        SwaputerCreationCodeStore kernelStore = new SwaputerCreationCodeStore(type(SwaputerKernel).creationCode);
        SwaputerCreationCodeStore hookStore = new SwaputerCreationCodeStore(type(SwaputerHook).creationCode);
        vm.stopBroadcast();

        require(address(kernelStore) == KERNEL_STORE, "KERNEL_STORE_ADDRESS_MISMATCH");
        require(address(hookStore) == HOOK_STORE, "HOOK_STORE_ADDRESS_MISMATCH");
        require(KERNEL_STORE.codehash == KERNEL_STORE_CODE_HASH, "KERNEL_STORE_CODE_HASH_MISMATCH");
        require(HOOK_STORE.codehash == HOOK_STORE_CODE_HASH, "HOOK_STORE_CODE_HASH_MISMATCH");
        console2.log("STAGE7D_U2_KERNEL_STORE", address(kernelStore));
        console2.log("STAGE7D_U2_HOOK_STORE", address(hookStore));
    }
}

/// @notice Second checkpoint: deploy the immutable Factory and create exactly one sealed World.
contract Stage7DU2FactoryWorldScript is Stage7DU2BaseSepoliaScript {
    function run() external {
        uint256 key = _key();
        require(vm.getNonce(DEPLOYER) == 756, "DEPLOYER_NONCE_MISMATCH");
        require(KERNEL_STORE.codehash == KERNEL_STORE_CODE_HASH, "KERNEL_STORE_CODE_HASH_MISMATCH");
        require(HOOK_STORE.codehash == HOOK_STORE_CODE_HASH, "HOOK_STORE_CODE_HASH_MISMATCH");
        require(FACTORY.code.length == 0, "FACTORY_ADDRESS_OCCUPIED");

        vm.startBroadcast(key);
        SwaputerWorldFactory factory = new SwaputerWorldFactory(
            MANAGER,
            MANAGER_CODE_HASH,
            KERNEL_STORE,
            HOOK_STORE,
            vm.envAddress("SVM_PROTOCOL_FEE_ADMIN"),
            vm.envAddress("SVM_FEE_CONTROLLER")
        );
        vm.stopBroadcast();

        require(address(factory) == FACTORY, "FACTORY_ADDRESS_MISMATCH");
        require(factory.router() == ROUTER, "ROUTER_ADDRESS_MISMATCH");
        require(address(factory.referenceRegistry()) == REGISTRY, "REGISTRY_ADDRESS_MISMATCH");
        require(factory.predictGasToken(TOKEN_SALT, INITIAL_SUPPLY, DEPLOYER) == TOKEN, "TOKEN_PREDICTION_MISMATCH");
        require(factory.predictWorldDeployer(BOOTSTRAP_SALT) == WORLD_DEPLOYER, "DEPLOYER_PREDICTION_MISMATCH");
        require(factory.predictKernel(WORLD_DEPLOYER) == KERNEL, "KERNEL_PREDICTION_MISMATCH");
        require(
            factory.predictHook(
                WORLD_DEPLOYER, HOOK_SALT, KERNEL, SwaputerToken(TOKEN), BYTE_GAS_PRICE, POOL_FEE, TICK_SPACING
            ) == HOOK,
            "HOOK_PREDICTION_MISMATCH"
        );
        require(uint160(HOOK) & Hooks.ALL_HOOK_MASK == 0x20cc, "HOOK_PERMISSION_BITS_MISMATCH");

        SwaputerWorldFactory.CreateWorldParams memory params = SwaputerWorldFactory.CreateWorldParams({
            tokenSalt: TOKEN_SALT,
            bootstrapSalt: BOOTSTRAP_SALT,
            hookSalt: HOOK_SALT,
            predictedKernel: KERNEL,
            predictedHook: HOOK,
            initialSupply: INITIAL_SUPPLY,
            initialHolder: DEPLOYER,
            distributionCommitment: DISTRIBUTION_COMMITMENT,
            byteGasPrice: BYTE_GAS_PRICE,
            poolFee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            initialSqrtPriceX96: INITIAL_SQRT_PRICE_X96
        });

        vm.startBroadcast(key);
        (bytes32 worldId, SwaputerToken token, SwaputerKernel kernel, SwaputerHook hook) = factory.createWorld(params);
        vm.stopBroadcast();

        SwaputerWorldFactory.WorldConfig memory config = factory.getWorldConfig(worldId);
        require(config.isSealed, "WORLD_NOT_SEALED");
        require(address(token) == TOKEN && address(kernel) == KERNEL && address(hook) == HOOK, "WORLD_ADDRESS_MISMATCH");
        require(kernel.hook() == HOOK && address(hook.kernel()) == KERNEL, "HOOK_KERNEL_BINDING_MISMATCH");
        require(address(hook.poolManager()) == address(MANAGER), "HOOK_MANAGER_BINDING_MISMATCH");
        require(hook.byteGasPrice() == BYTE_GAS_PRICE && kernel.byteGasPrice() == BYTE_GAS_PRICE, "BYTE_PRICE_MISMATCH");

        console2.log("STAGE7D_U2_FACTORY", address(factory));
        console2.log("STAGE7D_U2_ROUTER", ROUTER);
        console2.log("STAGE7D_U2_REGISTRY", REGISTRY);
        console2.log("STAGE7D_U2_WORLD_DEPLOYER", WORLD_DEPLOYER);
        console2.log("STAGE7D_U2_TOKEN", address(token));
        console2.log("STAGE7D_U2_KERNEL", address(kernel));
        console2.log("STAGE7D_U2_HOOK", address(hook));
        console2.log("STAGE7D_U2_WORLD_ID");
        console2.logBytes32(worldId);
        console2.log("STAGE7D_U2_CONFIG_HASH");
        console2.logBytes32(config.configHash);
    }
}
