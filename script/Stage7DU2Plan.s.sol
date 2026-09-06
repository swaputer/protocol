// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {SwapVMCreationCodeStore} from "../src/SwapVMCreationCodeStore.sol";
import {SwapVMGasToken} from "../src/SwapVMGasToken.sol";
import {SwapVMHook} from "../src/SwapVMHook.sol";
import {SwapVMKernel} from "../src/SwapVMKernel.sol";
import {SwapVMWorldDeployer} from "../src/SwapVMWorldDeployer.sol";
import {SwapVMWorldFactory} from "../src/SwapVMWorldFactory.sol";

/// @notice Read-only address planner for the rc2 Base Sepolia release flow.
/// @dev It accepts only public data, has no broadcast call and never reads a key.
contract Stage7DU2PlanScript is Script {
    IPoolManager internal constant BASE_SEPOLIA_POOL_MANAGER = IPoolManager(0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408);
    bytes32 internal constant BASE_SEPOLIA_POOL_MANAGER_CODE_HASH =
        0x03c45db6d09b14da7c1f7239a5a49697f976d395277e6d2acb6fbed3f9e0249f;
    bytes32 internal constant TOKEN_SALT = 0x3759c435ce279ce074811ee5a2644fe5b2ef4bb873ca21ad5ee903565433faef;
    bytes32 internal constant BOOTSTRAP_SALT = 0xdf010f36bf156164481ba9fe4a254f6d5b826a38894ac0106bf86fd1ad573d5e;
    uint256 internal constant INITIAL_SUPPLY = 1_000_000_000 ether;
    uint128 internal constant BYTE_GAS_PRICE = 1_000_000_000_000;
    uint24 internal constant POOL_FEE = 3_000;
    int24 internal constant TICK_SPACING = 60;

    function run(
        address deployer,
        uint256 nextNonce,
        address protocolFeeAdmin,
        address feeController,
        uint16 initialProtocolFeeBps
    ) external view {
        require(deployer != address(0), "DEPLOYER_REQUIRED");
        require(protocolFeeAdmin != address(0), "FEE_ADMIN_REQUIRED");
        require(feeController != address(0), "FEE_CONTROLLER_REQUIRED");
        require(initialProtocolFeeBps <= 1_000, "FEE_BPS_TOO_HIGH");

        address kernelStore = vm.computeCreateAddress(deployer, nextNonce);
        address hookStore = vm.computeCreateAddress(deployer, nextNonce + 1);
        address factory = vm.computeCreateAddress(deployer, nextNonce + 2);
        address registry = vm.computeCreateAddress(factory, 1);
        address router = vm.computeCreateAddress(factory, 2);

        bytes32 tokenInitCodeHash =
            keccak256(abi.encodePacked(type(SwapVMGasToken).creationCode, abi.encode(INITIAL_SUPPLY, deployer)));
        address token = _create2(factory, TOKEN_SALT, tokenInitCodeHash);

        bytes32 worldDeployerInitCodeHash = keccak256(
            abi.encodePacked(
                type(SwapVMWorldDeployer).creationCode,
                abi.encode(
                    factory,
                    kernelStore,
                    hookStore,
                    keccak256(type(SwapVMKernel).creationCode),
                    keccak256(type(SwapVMHook).creationCode)
                )
            )
        );
        address worldDeployer = _create2(factory, BOOTSTRAP_SALT, worldDeployerInitCodeHash);
        address kernel = vm.computeCreateAddress(worldDeployer, 1);
        bytes memory hookArguments = abi.encode(
            BASE_SEPOLIA_POOL_MANAGER,
            SwapVMKernel(kernel),
            token,
            protocolFeeAdmin,
            feeController,
            initialProtocolFeeBps,
            BYTE_GAS_PRICE,
            POOL_FEE,
            TICK_SPACING
        );
        (address hook, bytes32 hookSalt) = HookMiner.find(
            worldDeployer,
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG,
            type(SwapVMHook).creationCode,
            hookArguments
        );
        bytes32 hookInitCodeHash = keccak256(abi.encodePacked(type(SwapVMHook).creationCode, hookArguments));

        bytes32 factoryInitCodeHash = keccak256(
            abi.encodePacked(
                type(SwapVMWorldFactory).creationCode,
                abi.encode(
                    BASE_SEPOLIA_POOL_MANAGER,
                    BASE_SEPOLIA_POOL_MANAGER_CODE_HASH,
                    kernelStore,
                    hookStore,
                    protocolFeeAdmin,
                    feeController,
                    initialProtocolFeeBps
                )
            )
        );
        bytes32 kernelStoreInitCodeHash = keccak256(
            abi.encodePacked(type(SwapVMCreationCodeStore).creationCode, abi.encode(type(SwapVMKernel).creationCode))
        );
        bytes32 hookStoreInitCodeHash = keccak256(
            abi.encodePacked(type(SwapVMCreationCodeStore).creationCode, abi.encode(type(SwapVMHook).creationCode))
        );

        console2.log("STAGE7D_U2_DEPLOYER", deployer);
        console2.log("STAGE7D_U2_NEXT_NONCE", nextNonce);
        console2.log("STAGE7D_U2_KERNEL_STORE", kernelStore);
        console2.log("STAGE7D_U2_HOOK_STORE", hookStore);
        console2.log("STAGE7D_U2_FACTORY", factory);
        console2.log("STAGE7D_U2_REGISTRY", registry);
        console2.log("STAGE7D_U2_ROUTER", router);
        console2.log("STAGE7D_U2_TOKEN", token);
        console2.log("STAGE7D_U2_WORLD_DEPLOYER", worldDeployer);
        console2.log("STAGE7D_U2_KERNEL", kernel);
        console2.log("STAGE7D_U2_HOOK", hook);
        console2.log("STAGE7D_U2_TOKEN_INIT_CODE_HASH");
        console2.logBytes32(tokenInitCodeHash);
        console2.log("STAGE7D_U2_WORLD_DEPLOYER_INIT_CODE_HASH");
        console2.logBytes32(worldDeployerInitCodeHash);
        console2.log("STAGE7D_U2_HOOK_INIT_CODE_HASH");
        console2.logBytes32(hookInitCodeHash);
        console2.log("STAGE7D_U2_HOOK_SALT");
        console2.logBytes32(hookSalt);
        console2.log("STAGE7D_U2_KERNEL_STORE_INIT_CODE_HASH");
        console2.logBytes32(kernelStoreInitCodeHash);
        console2.log("STAGE7D_U2_HOOK_STORE_INIT_CODE_HASH");
        console2.logBytes32(hookStoreInitCodeHash);
        console2.log("STAGE7D_U2_FACTORY_INIT_CODE_HASH");
        console2.logBytes32(factoryInitCodeHash);
    }

    function _create2(address deployer, bytes32 salt, bytes32 initCodeHash) private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }
}
