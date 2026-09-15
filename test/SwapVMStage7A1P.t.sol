// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {SwaputerToken} from "../src/SwaputerToken.sol";
import {SwaputerHook} from "../src/SwaputerHook.sol";
import {SwaputerKernel} from "../src/SwaputerKernel.sol";
import {
    WorldDeployerProbe,
    WorldDeployerProbeFactory,
    ProbeNotFactory,
    ProbeKernelPredictionMismatch,
    ProbeHookPredictionMismatch,
    ProbeAlreadyUsed
} from "./WorldDeployerProbe.sol";

error ProbeFactoryProbeMissing(address predictedProbe);

contract SwapVMStage7A1PTest is Test {
    uint128 internal constant BYTE_GAS_PRICE = 1e12;
    uint24 internal constant POOL_FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    uint160 internal constant V4_PERMISSION_BITS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    PoolManager internal manager;
    SwaputerToken internal token;
    WorldDeployerProbeFactory internal probeFactory;

    function setUp() public {
        manager = new PoolManager(address(this));
        token = new SwaputerToken(1e36, address(this));
        probeFactory = new WorldDeployerProbeFactory(type(SwaputerKernel).creationCode, type(SwaputerHook).creationCode);
    }

    function test_naiveHookKernelCreate2PredictionCannotResolveCycleInOnePass() public view {
        address[3] memory fakeKernelGuesses = [
            address(0x1111111111111111111111111111111111111111),
            address(0x2222),
            address(0x3333333333333333333333333333333333333333)
        ];
        bytes32 kernelSalt = bytes32(uint256(0xBEEF));
        bytes32 hookSalt = bytes32(uint256(0xCAFE));

        for (uint256 i; i < fakeKernelGuesses.length; ++i) {
            // A fixed salt is sufficient to demonstrate the CREATE2 dependency cycle. Mining the
            // permission bits here would only add an unbounded search to a pure address proof.
            address hookFromFakeKernel =
                vm.computeCreate2Address(hookSalt, _hookInitCodeHash(fakeKernelGuesses[i]), address(this));

            bytes32 kernelInitCodeHash = _kernelInitCodeHash(hookFromFakeKernel);
            address kernelFromHookGuess = vm.computeCreate2Address(kernelSalt, kernelInitCodeHash, address(this));

            address hookFromKernelFormula =
                vm.computeCreate2Address(hookSalt, _hookInitCodeHash(kernelFromHookGuess), address(this));

            assertTrue(hookFromFakeKernel != hookFromKernelFormula, "naive single-pass prediction is not a fixed point");
        }
    }

    function test_naiveTwoPassDeploymentFailsAtHookBinding() public {
        address fakeKernel = address(0x1111111111111111111111111111111111111111);
        bytes32 kernelSalt = bytes32(uint256(0xC0FFEE));

        (address hookByFakeKernel, bytes32 hookSalt) =
            HookMiner.find(address(this), V4_PERMISSION_BITS, type(SwaputerHook).creationCode, _hookArgs(fakeKernel));
        bytes32 kernelInitCodeHash = _kernelInitCodeHash(hookByFakeKernel);
        address kernelByFormula = vm.computeCreate2Address(kernelSalt, kernelInitCodeHash, address(this));
        (address hookByDerivedKernel,) = HookMiner.find(
            address(this), V4_PERMISSION_BITS, type(SwaputerHook).creationCode, _hookArgs(kernelByFormula)
        );

        assertTrue(
            hookByFakeKernel != hookByDerivedKernel,
            "kernel->hook->kernel loop must be solved jointly, not sequentially"
        );

        SwaputerKernel kernel = new SwaputerKernel{salt: kernelSalt}(hookByFakeKernel, BYTE_GAS_PRICE);
        vm.expectRevert(SwaputerHook.InvalidBinding.selector);
        new SwaputerHook{salt: hookSalt}(
            manager, kernel, token, address(this), address(this), 0, BYTE_GAS_PRICE, POOL_FEE, TICK_SPACING
        );
    }

    function test_worldDeployerProbeBreaksHookKernelCycle() public {
        bytes32 bootstrapSalt = bytes32(uint256(1));

        WorldDeployerProbeBootstrapResult memory bootstrap = _predictWorldDeployment(bootstrapSalt);
        (address probe, address kernel, address hook) = probeFactory.deployWorldWithProbe(
            bootstrapSalt,
            bootstrap.predictedKernel,
            bootstrap.predictedHook,
            bootstrap.hookSalt,
            manager,
            token,
            BYTE_GAS_PRICE,
            POOL_FEE,
            TICK_SPACING
        );

        assertEq(probe, bootstrap.predictedProbe, "probe address deterministic");
        assertEq(kernel, bootstrap.predictedKernel, "kernel address deterministic");
        assertEq(hook, bootstrap.predictedHook, "hook address deterministic");
        assertEq(address(probe), bootstrap.predictedProbe, "probe canary");
        assertEq(SwaputerKernel(kernel).hook(), hook);
        assertEq(address(SwaputerHook(payable(hook)).kernel()), kernel);
        assertEq(address(SwaputerHook(payable(hook)).poolManager()), address(manager));
        assertEq(SwaputerHook(payable(hook)).byteGasPrice(), BYTE_GAS_PRICE);
        assertEq(SwaputerKernel(kernel).byteGasPrice(), BYTE_GAS_PRICE);
        assertEq(
            uint160(hook) & Hooks.ALL_HOOK_MASK, V4_PERMISSION_BITS, "hook address bits must satisfy v4 permission mask"
        );
        assertEq(WorldDeployerProbe(probe).used(), true, "probe must be one-shot consumed");
    }

    function test_worldDeployerProbeRejectsKernelPredictionMismatchAndRollsBack() public {
        bytes32 bootstrapSalt = bytes32(uint256(2));
        WorldDeployerProbeBootstrapResult memory bootstrap = _predictWorldDeployment(bootstrapSalt);
        address wrongKernel = address(uint160(uint160(bootstrap.predictedKernel) + 1));

        vm.expectRevert(ProbeKernelPredictionMismatch.selector);
        probeFactory.deployWorldWithProbe(
            bootstrapSalt,
            wrongKernel,
            bootstrap.predictedHook,
            bootstrap.hookSalt,
            manager,
            token,
            BYTE_GAS_PRICE,
            POOL_FEE,
            TICK_SPACING
        );

        assertEq(bootstrap.predictedProbe.code.length, 0, "probe never partially remains");
        assertEq(bootstrap.predictedKernel.code.length, 0, "kernel never partially remains");
        assertEq(bootstrap.predictedHook.code.length, 0, "hook never partially remains");
    }

    function test_worldDeployerProbeExistingProbeRollsBackInternalDeployment() public {
        bytes32 bootstrapSalt = bytes32(uint256(21));
        WorldDeployerProbeBootstrapResult memory bootstrap = _predictWorldDeployment(bootstrapSalt);
        WorldDeployerProbe probe = probeFactory.deployProbe(bootstrapSalt);
        address wrongKernel = address(uint160(uint160(bootstrap.predictedKernel) + 1));

        vm.expectRevert(ProbeKernelPredictionMismatch.selector);
        probeFactory.reuseProbe(
            address(probe),
            wrongKernel,
            bootstrap.predictedHook,
            bootstrap.hookSalt,
            manager,
            token,
            BYTE_GAS_PRICE,
            POOL_FEE,
            TICK_SPACING
        );

        assertEq(address(probe).code.length > 0, true, "pre-existing probe remains");
        assertEq(probe.used(), false, "one-shot flag rolls back");
        assertEq(bootstrap.predictedKernel.code.length, 0, "created kernel rolls back");
        assertEq(bootstrap.predictedHook.code.length, 0, "hook was not deployed");
    }

    function test_worldDeployerProbeRejectsHookPredictionMismatchAndRollsBack() public {
        bytes32 bootstrapSalt = bytes32(uint256(3));
        WorldDeployerProbeBootstrapResult memory bootstrap = _predictWorldDeployment(bootstrapSalt);
        bytes32 wrongHookSalt =
            bootstrap.hookSalt == bytes32(0) ? bytes32(uint256(1)) : bootstrap.hookSalt ^ bytes32(uint256(1));

        vm.expectRevert(ProbeHookPredictionMismatch.selector);
        probeFactory.deployWorldWithProbe(
            bootstrapSalt,
            bootstrap.predictedKernel,
            bootstrap.predictedHook,
            wrongHookSalt,
            manager,
            token,
            BYTE_GAS_PRICE,
            POOL_FEE,
            TICK_SPACING
        );

        assertEq(bootstrap.predictedProbe.code.length, 0, "probe never partially remains");
        assertEq(bootstrap.predictedKernel.code.length, 0, "kernel never partially remains");
        assertEq(bootstrap.predictedHook.code.length, 0, "hook never partially remains");
    }

    function test_worldDeployerProbeIsOneShotPerProbe() public {
        bytes32 bootstrapSalt = bytes32(uint256(4));
        WorldDeployerProbeBootstrapResult memory bootstrap = _predictWorldDeployment(bootstrapSalt);

        (address probe,,) = probeFactory.deployWorldWithProbe(
            bootstrapSalt,
            bootstrap.predictedKernel,
            bootstrap.predictedHook,
            bootstrap.hookSalt,
            manager,
            token,
            BYTE_GAS_PRICE,
            POOL_FEE,
            TICK_SPACING
        );

        vm.expectRevert(ProbeAlreadyUsed.selector);
        probeFactory.reuseProbe(
            probe,
            bootstrap.predictedKernel,
            bootstrap.predictedHook,
            bootstrap.hookSalt,
            manager,
            token,
            BYTE_GAS_PRICE,
            POOL_FEE,
            TICK_SPACING
        );
    }

    function test_worldDeployerProbeRejectsBootstrapCollisionOnSecondDeploy() public {
        bytes32 bootstrapSalt = bytes32(uint256(5));
        WorldDeployerProbeBootstrapResult memory bootstrap = _predictWorldDeployment(bootstrapSalt);

        (address firstProbe,,) = probeFactory.deployWorldWithProbe(
            bootstrapSalt,
            bootstrap.predictedKernel,
            bootstrap.predictedHook,
            bootstrap.hookSalt,
            manager,
            token,
            BYTE_GAS_PRICE,
            POOL_FEE,
            TICK_SPACING
        );
        assertEq(firstProbe, bootstrap.predictedProbe, "first world probe");

        vm.expectRevert();
        probeFactory.deployWorldWithProbe(
            bootstrapSalt,
            bootstrap.predictedKernel,
            bootstrap.predictedHook,
            bootstrap.hookSalt,
            manager,
            token,
            BYTE_GAS_PRICE,
            POOL_FEE,
            TICK_SPACING
        );
    }

    function test_worldDeployerProbeRejectsOccupiedHookTargetAndRollsBack() public {
        bytes32 bootstrapSalt = bytes32(uint256(6));
        WorldDeployerProbeBootstrapResult memory bootstrap = _predictWorldDeployment(bootstrapSalt);
        vm.etch(bootstrap.predictedHook, hex"00");

        vm.expectRevert();
        probeFactory.deployWorldWithProbe(
            bootstrapSalt,
            bootstrap.predictedKernel,
            bootstrap.predictedHook,
            bootstrap.hookSalt,
            manager,
            token,
            BYTE_GAS_PRICE,
            POOL_FEE,
            TICK_SPACING
        );

        assertEq(bootstrap.predictedProbe.code.length, 0, "probe rolls back");
        assertEq(bootstrap.predictedKernel.code.length, 0, "kernel rolls back");
        assertEq(bootstrap.predictedHook.code.length, 1, "pre-existing target remains unchanged");
    }

    function test_worldDeployerProbeOnlyFactory() public {
        bytes32 bootstrapSalt = bytes32(uint256(7));
        WorldDeployerProbeBootstrapResult memory bootstrap = _predictWorldDeployment(bootstrapSalt);
        WorldDeployerProbe probe = probeFactory.deployProbe(bootstrapSalt);

        vm.expectRevert(ProbeNotFactory.selector);
        probe.deployKernelAndHook(
            bootstrap.predictedKernel,
            bootstrap.predictedHook,
            manager,
            token,
            BYTE_GAS_PRICE,
            POOL_FEE,
            TICK_SPACING,
            bootstrap.hookSalt,
            hex"",
            hex""
        );
        assertEq(probe.used(), false, "unauthorized call cannot consume probe");
    }

    function _predictWorldDeployment(bytes32 bootstrapSalt)
        internal
        view
        returns (WorldDeployerProbeBootstrapResult memory bootstrap)
    {
        bootstrap.predictedProbe = probeFactory.predictProbeAddress(bootstrapSalt);
        if (bootstrap.predictedProbe.code.length != 0) revert ProbeFactoryProbeMissing(bootstrap.predictedProbe);
        bootstrap.predictedKernel = vm.computeCreateAddress(bootstrap.predictedProbe, 1);
        (bootstrap.predictedHook, bootstrap.hookSalt) = HookMiner.find(
            bootstrap.predictedProbe,
            V4_PERMISSION_BITS,
            type(SwaputerHook).creationCode,
            _hookArgs(bootstrap.predictedKernel, bootstrap.predictedProbe)
        );
    }

    function _kernelInitCodeHash(address hook) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(type(SwaputerKernel).creationCode, abi.encode(hook, BYTE_GAS_PRICE)));
    }

    function _hookInitCodeHash(address kernel) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(type(SwaputerHook).creationCode, _hookArgs(kernel)));
    }

    function _hookArgs(address kernel) internal view returns (bytes memory) {
        return _hookArgs(kernel, address(this));
    }

    function _hookArgs(address kernel, address feeAuthority) internal view returns (bytes memory) {
        return abi.encode(
            IPoolManager(manager),
            kernel,
            token,
            feeAuthority,
            feeAuthority,
            uint16(0),
            BYTE_GAS_PRICE,
            POOL_FEE,
            TICK_SPACING
        );
    }
}

struct WorldDeployerProbeBootstrapResult {
    address predictedProbe;
    address predictedKernel;
    address predictedHook;
    bytes32 hookSalt;
}
