// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {SwapVMKernel} from "../src/SwapVMKernel.sol";
import {SwapVMHook} from "../src/SwapVMHook.sol";
import {SwapVMGasToken} from "../src/SwapVMGasToken.sol";

error ProbeNotFactory();
error ProbeAlreadyUsed();
error ProbeKernelPredictionMismatch();
error ProbeHookPredictionMismatch();
error ProbeBindingMismatch();
error ProbeKernelCreationCodeMismatch();
error ProbeHookCreationCodeMismatch();

/// @notice Test-only one-shot deployer to break Hook↔Kernel cycle by first CREATE-kernel then CREATE2-hook.
contract WorldDeployerProbe {
    address public immutable factory;
    bytes32 public immutable kernelCreationCodeHash;
    bytes32 public immutable hookCreationCodeHash;
    bool public used;

    constructor(address factory_, bytes32 kernelCreationCodeHash_, bytes32 hookCreationCodeHash_) {
        factory = factory_;
        kernelCreationCodeHash = kernelCreationCodeHash_;
        hookCreationCodeHash = hookCreationCodeHash_;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert ProbeNotFactory();
        _;
    }

    modifier oneShot() {
        if (used) revert ProbeAlreadyUsed();
        used = true;
        _;
    }

    function deployKernelAndHook(
        address predictedKernel,
        address predictedHook,
        IPoolManager manager,
        SwapVMGasToken token,
        uint128 byteGasPrice,
        uint24 fee,
        int24 tickSpacing,
        bytes32 hookSalt,
        bytes calldata kernelCreationCode,
        bytes calldata hookCreationCode
    ) external onlyFactory oneShot returns (address kernel, address hook) {
        if (keccak256(kernelCreationCode) != kernelCreationCodeHash) {
            revert ProbeKernelCreationCodeMismatch();
        }
        if (keccak256(hookCreationCode) != hookCreationCodeHash) revert ProbeHookCreationCodeMismatch();

        bytes memory kernelInitCode = abi.encodePacked(kernelCreationCode, abi.encode(predictedHook, byteGasPrice));
        assembly ("memory-safe") {
            kernel := create(0, add(kernelInitCode, 0x20), mload(kernelInitCode))
        }
        if (kernel != predictedKernel) revert ProbeKernelPredictionMismatch();

        bytes memory hookInitCode = abi.encodePacked(
            hookCreationCode,
            abi.encode(
                manager,
                SwapVMKernel(kernel),
                token,
                address(this),
                address(this),
                uint16(0),
                byteGasPrice,
                fee,
                tickSpacing
            )
        );
        assembly ("memory-safe") {
            hook := create2(0, add(hookInitCode, 0x20), mload(hookInitCode), hookSalt)
        }
        if (hook != predictedHook) revert ProbeHookPredictionMismatch();

        if (SwapVMKernel(kernel).hook() != hook) revert ProbeBindingMismatch();
        SwapVMHook hookRef = SwapVMHook(payable(hook));
        if (address(hookRef.kernel()) != kernel) revert ProbeBindingMismatch();
        if (address(hookRef.poolManager()) != address(manager)) revert ProbeBindingMismatch();
        if (hookRef.byteGasPrice() != byteGasPrice) revert ProbeBindingMismatch();
    }
}

/// @notice Test-only helper factory that deterministically deploys one probe and keeps deployment immutable.
contract WorldDeployerProbeFactory {
    error ProbeAddressCollision(bytes32 bootstrapSalt);
    error ProbeAddressMismatch(bytes32 bootstrapSalt, address expected, address actual);

    bytes private kernelCreationCode;
    bytes private hookCreationCode;
    bytes32 public immutable kernelCreationCodeHash;
    bytes32 public immutable hookCreationCodeHash;

    constructor(bytes memory kernelCreationCode_, bytes memory hookCreationCode_) {
        kernelCreationCode = kernelCreationCode_;
        hookCreationCode = hookCreationCode_;
        kernelCreationCodeHash = keccak256(kernelCreationCode_);
        hookCreationCodeHash = keccak256(hookCreationCode_);
    }

    function probeInitCodeHash() public view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                type(WorldDeployerProbe).creationCode,
                abi.encode(address(this), kernelCreationCodeHash, hookCreationCodeHash)
            )
        );
    }

    function predictProbeAddress(bytes32 bootstrapSalt) public view returns (address predicted) {
        bytes memory initCodeWithArgs = abi.encodePacked(
            type(WorldDeployerProbe).creationCode,
            abi.encode(address(this), kernelCreationCodeHash, hookCreationCodeHash)
        );
        bytes32 initCodeHash = keccak256(initCodeWithArgs);
        predicted = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bootstrapSalt, initCodeHash))))
        );
    }

    function deployProbe(bytes32 bootstrapSalt) public returns (WorldDeployerProbe probe) {
        address expected = predictProbeAddress(bootstrapSalt);
        if (expected.code.length != 0) revert ProbeAddressCollision(bootstrapSalt);

        probe = new WorldDeployerProbe{salt: bootstrapSalt}(address(this), kernelCreationCodeHash, hookCreationCodeHash);
        if (address(probe) != expected) revert ProbeAddressMismatch(bootstrapSalt, expected, address(probe));
    }

    function deployWorldWithProbe(
        bytes32 bootstrapSalt,
        address predictedKernel,
        address predictedHook,
        bytes32 hookSalt,
        IPoolManager manager,
        SwapVMGasToken token,
        uint128 byteGasPrice,
        uint24 fee,
        int24 tickSpacing
    ) public returns (address probe, address kernel, address hook) {
        probe = address(deployProbe(bootstrapSalt));
        (kernel, hook) = WorldDeployerProbe(probe)
            .deployKernelAndHook(
                predictedKernel,
                predictedHook,
                manager,
                token,
                byteGasPrice,
                fee,
                tickSpacing,
                hookSalt,
                kernelCreationCode,
                hookCreationCode
            );
    }

    function reuseProbe(
        address probe,
        address predictedKernel,
        address predictedHook,
        bytes32 hookSalt,
        IPoolManager manager,
        SwapVMGasToken token,
        uint128 byteGasPrice,
        uint24 fee,
        int24 tickSpacing
    ) public {
        WorldDeployerProbe(probe)
            .deployKernelAndHook(
                predictedKernel,
                predictedHook,
                manager,
                token,
                byteGasPrice,
                fee,
                tickSpacing,
                hookSalt,
                kernelCreationCode,
                hookCreationCode
            );
    }
}
