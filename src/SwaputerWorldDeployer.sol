// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {SwaputerCreationCodeReader} from "./SwaputerCreationCodeStore.sol";
import {SwaputerToken} from "./SwaputerToken.sol";
import {SwaputerHook} from "./SwaputerHook.sol";
import {SwaputerKernel} from "./SwaputerKernel.sol";

/// @notice One-shot per-World deployer that deterministically breaks the Hook/Kernel address cycle.
contract SwaputerWorldDeployer {
    using SwaputerCreationCodeReader for address;

    address public immutable factory;
    address public immutable kernelCreationCodeStore;
    address public immutable hookCreationCodeStore;
    bytes32 public immutable kernelCreationCodeHash;
    bytes32 public immutable hookCreationCodeHash;
    bool public used;

    error OnlyFactory(address caller);
    error AlreadyUsed();
    error KernelCreationCodeMismatch(bytes32 expected, bytes32 actual);
    error HookCreationCodeMismatch(bytes32 expected, bytes32 actual);
    error KernelPredictionMismatch(address expected, address actual);
    error HookPredictionMismatch(address expected, address actual);
    error BindingMismatch();

    constructor(
        address factory_,
        address kernelCreationCodeStore_,
        address hookCreationCodeStore_,
        bytes32 kernelCreationCodeHash_,
        bytes32 hookCreationCodeHash_
    ) {
        factory = factory_;
        kernelCreationCodeStore = kernelCreationCodeStore_;
        hookCreationCodeStore = hookCreationCodeStore_;
        kernelCreationCodeHash = kernelCreationCodeHash_;
        hookCreationCodeHash = hookCreationCodeHash_;
    }

    function deploy(
        address predictedKernel,
        address predictedHook,
        IPoolManager manager,
        SwaputerToken token,
        address feeAdmin,
        address feeController,
        uint16 protocolFeeBps,
        uint128 byteGasPrice,
        uint24 fee,
        int24 tickSpacing,
        bytes32 hookSalt
    ) external returns (SwaputerKernel kernel, SwaputerHook hook) {
        if (msg.sender != factory) revert OnlyFactory(msg.sender);
        if (used) revert AlreadyUsed();
        used = true;

        bytes memory kernelCreationCode = kernelCreationCodeStore.read();
        bytes32 actualKernelCreationCodeHash = keccak256(kernelCreationCode);
        if (actualKernelCreationCodeHash != kernelCreationCodeHash) {
            revert KernelCreationCodeMismatch(kernelCreationCodeHash, actualKernelCreationCodeHash);
        }
        bytes memory kernelInitCode = abi.encodePacked(kernelCreationCode, abi.encode(predictedHook, byteGasPrice));
        address kernelAddress;
        assembly ("memory-safe") {
            kernelAddress := create(0, add(kernelInitCode, 0x20), mload(kernelInitCode))
        }
        if (kernelAddress != predictedKernel) revert KernelPredictionMismatch(predictedKernel, kernelAddress);
        kernel = SwaputerKernel(kernelAddress);

        bytes memory hookCreationCode = hookCreationCodeStore.read();
        bytes32 actualHookCreationCodeHash = keccak256(hookCreationCode);
        if (actualHookCreationCodeHash != hookCreationCodeHash) {
            revert HookCreationCodeMismatch(hookCreationCodeHash, actualHookCreationCodeHash);
        }
        bytes memory hookInitCode = abi.encodePacked(
            hookCreationCode,
            abi.encode(manager, kernel, token, feeAdmin, feeController, protocolFeeBps, byteGasPrice, fee, tickSpacing)
        );
        address hookAddress;
        assembly ("memory-safe") {
            hookAddress := create2(0, add(hookInitCode, 0x20), mload(hookInitCode), hookSalt)
        }
        if (hookAddress != predictedHook) revert HookPredictionMismatch(predictedHook, hookAddress);
        hook = SwaputerHook(payable(hookAddress));

        if (
            kernel.hook() != hookAddress || address(hook.kernel()) != kernelAddress
                || address(hook.poolManager()) != address(manager) || address(hook.gasToken()) != address(token)
                || hook.owner() != feeAdmin || hook.feeAdmin() != feeAdmin || hook.feeController() != feeController
                || hook.protocolFeeBps() != protocolFeeBps || hook.byteGasPrice() != byteGasPrice
                || kernel.byteGasPrice() != byteGasPrice || hook.poolFee() != fee
                || hook.poolTickSpacing() != tickSpacing || hook.tradingLive()
        ) revert BindingMismatch();
    }
}
