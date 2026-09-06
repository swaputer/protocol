// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {SwapVMCreationCodeStore} from "../src/SwapVMCreationCodeStore.sol";
import {SwapVMGasToken} from "../src/SwapVMGasToken.sol";
import {SwapVMHook} from "../src/SwapVMHook.sol";
import {SwapVMKernel} from "../src/SwapVMKernel.sol";
import {SwapVMRouter} from "../src/SwapVMRouter.sol";
import {SwapVMSRC20Market} from "../src/SwapVMSRC20Market.sol";
import {SwapVMWorldFactory} from "../src/SwapVMWorldFactory.sol";

/// @notice Deploys the complete v1.2 escrow market onto an isolated Anvil chain.
/// @dev The liquidity helper is test-only. Public releases must bootstrap with the official PositionManager.
contract LocalV12EscrowMarketScript is Script {
    uint256 private constant INITIAL_GAS_TOKEN_SUPPLY = 1e36;
    uint128 private constant BYTE_GAS_PRICE = 1e12;
    uint24 private constant POOL_FEE = 3_000;
    int24 private constant TICK_SPACING = 60;
    uint160 private constant INITIAL_SQRT_PRICE_X96 = 1 << 96;
    uint128 private constant VM_INPUT = 0.25 ether;
    uint32 private constant DEPLOY_BYTE_LIMIT = 10_000;
    uint32 private constant CALL_BYTE_LIMIT = 3_000;
    bytes32 private constant TOKEN_SALT = keccak256("SwapVM.v1.2.local.token");
    bytes32 private constant BOOTSTRAP_SALT = keccak256("SwapVM.v1.2.local.bootstrap");

    uint256 private actorKey;
    address private actor;
    PoolManager private manager;
    SwapVMWorldFactory private factory;
    SwapVMRouter private router;
    SwapVMGasToken private gasToken;
    SwapVMKernel private kernel;
    bytes32 private worldId;

    function run() external {
        require(block.chainid == 31_337, "ANVIL_ONLY");
        actorKey = vm.envUint("LOCAL_V12_PRIVATE_KEY");
        actor = vm.addr(actorKey);

        _deployWorldAndLiquidity();
        bytes32 src20 = _deployMintableSRC20();
        (bytes32 escrow, bytes32 escrowCodeHash, address predictedMarket) = _deployEscrow(src20);

        bytes32 src20CodeHash = kernel.programCodeHash(worldId, src20);
        vm.startBroadcast(actorKey);
        SwapVMSRC20Market market = new SwapVMSRC20Market(router, worldId, src20, src20CodeHash, escrow, escrowCodeHash);
        vm.stopBroadcast();
        require(address(market) == predictedMarket, "MARKET_PREDICTION");

        console2.log("VITE_SWAPVM_PROTOCOL_VERSION=1.2");
        console2.log("VITE_SWAPVM_WORLD_ID", vm.toString(worldId));
        console2.log("VITE_SWAPVM_KERNEL_ADDRESS", address(kernel));
        console2.log("VITE_SWAPVM_ROUTER_ADDRESS", address(router));
        console2.log("VITE_SWAPVM_SRC20_ID", vm.toString(src20));
        console2.log("VITE_SWAPVM_MARKET_ADDRESS", address(market));
        console2.log("VITE_SWAPVM_MARKET_ESCROW_ID", vm.toString(escrow));
        console2.log("VITE_SWAPVM_MARKET_ESCROW_CODE_HASH", vm.toString(escrowCodeHash));
        console2.log("LOCAL_V12_POOL_MANAGER", address(manager));
        console2.log("LOCAL_V12_GAS_TOKEN", address(gasToken));
        console2.log("LOCAL_V12_FACTORY", address(factory));
        console2.log("LOCAL_V12_UNAUDITED", true);
    }

    function _deployWorldAndLiquidity() private {
        vm.startBroadcast(actorKey);
        manager = new PoolManager(actor);
        SwapVMCreationCodeStore kernelStore = new SwapVMCreationCodeStore(type(SwapVMKernel).creationCode);
        SwapVMCreationCodeStore hookStore = new SwapVMCreationCodeStore(type(SwapVMHook).creationCode);
        factory = new SwapVMWorldFactory(
            manager,
            address(manager).codehash,
            address(kernelStore),
            address(hookStore),
            vm.envAddress("SVM_PROTOCOL_FEE_ADMIN"),
            vm.envAddress("SVM_FEE_CONTROLLER"),
            uint16(vm.envUint("SVM_INITIAL_PROTOCOL_FEE_BPS"))
        );
        vm.stopBroadcast();
        router = SwapVMRouter(payable(factory.router()));

        address predictedToken = factory.predictGasToken(TOKEN_SALT, INITIAL_GAS_TOKEN_SUPPLY, actor);
        address predictedWorldDeployer = factory.predictWorldDeployer(BOOTSTRAP_SALT);
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
            type(SwapVMHook).creationCode,
            hookArgs
        );
        SwapVMWorldFactory.CreateWorldParams memory params = SwapVMWorldFactory.CreateWorldParams({
            tokenSalt: TOKEN_SALT,
            bootstrapSalt: BOOTSTRAP_SALT,
            hookSalt: hookSalt,
            predictedKernel: predictedKernel,
            predictedHook: predictedHook,
            initialSupply: INITIAL_GAS_TOKEN_SUPPLY,
            initialHolder: actor,
            distributionCommitment: keccak256("SwapVM.v1.2.local.zero-value"),
            byteGasPrice: BYTE_GAS_PRICE,
            poolFee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            initialSqrtPriceX96: INITIAL_SQRT_PRICE_X96
        });

        vm.startBroadcast(actorKey);
        (worldId, gasToken, kernel,) = factory.createWorld(params);
        (PoolKey memory poolKey, bool isSealed) = factory.getPoolKey(worldId);
        require(isSealed, "WORLD_NOT_SEALED");
        PoolModifyLiquidityTest liquidityRouter = new PoolModifyLiquidityTest(manager);
        gasToken.approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity{value: 100 ether}(
            poolKey,
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e20, salt: bytes32(0)}),
            bytes("")
        );
        vm.stopBroadcast();
    }

    function _deployMintableSRC20() private returns (bytes32 src20) {
        bytes memory packageBytes = vm.readFileBinary("tooling/tinysol/programs/mintable-src20/MintableSRC20.svm");
        bytes32 codeHash = keccak256(packageBytes);
        bytes32 actorId = kernel.eoaAccountId(actor);
        src20 = kernel.contractAccountId(worldId, actorId, kernel.creatorNonce(worldId, actorId), codeHash);
        _executeDeploy(codeHash, abi.encodePacked(bytes4(uint32(packageBytes.length)), packageBytes));
        require(kernel.programCodeHash(worldId, src20) == codeHash, "SRC20_DEPLOY");

        bytes memory mintPayload = abi.encodePacked(bytes4(keccak256("mint(bytes32)")), abi.encode(actorId));
        _executeCall(src20, mintPayload);
        _executeCall(src20, mintPayload);
    }

    function _deployEscrow(bytes32 src20)
        private
        returns (bytes32 escrow, bytes32 escrowCodeHash, address predictedMarket)
    {
        bytes memory packageBytes = vm.readFileBinary("tooling/tinysol/programs/market-escrow/MarketEscrow.svm");
        escrowCodeHash = keccak256(packageBytes);
        bytes32 actorId = kernel.eoaAccountId(actor);
        escrow = kernel.contractAccountId(worldId, actorId, kernel.creatorNonce(worldId, actorId), escrowCodeHash);
        // The escrow DEPLOY is the actor's next transaction. The market is then
        // created by the actor's following transaction with ordinary CREATE.
        // Avoid Foundry's special CREATE2 deployer so the prediction exactly
        // matches both script simulation and broadcast execution.
        predictedMarket = vm.computeCreateAddress(actor, vm.getNonce(actor) + 1);
        bytes memory constructorInput = abi.encode(src20, predictedMarket);
        _executeDeploy(
            escrowCodeHash, abi.encodePacked(bytes4(uint32(packageBytes.length)), packageBytes, constructorInput)
        );
        require(kernel.programCodeHash(worldId, escrow) == escrowCodeHash, "ESCROW_DEPLOY");
    }

    function _executeDeploy(bytes32 codeHash, bytes memory payload) private {
        SwapVMKernel.VMEnvelope memory envelope = _signedDeploy(codeHash, payload);
        vm.startBroadcast(actorKey);
        router.buyVMExactInput{value: VM_INPUT}(worldId, TickMath.MIN_SQRT_PRICE + 1, envelope);
        vm.stopBroadcast();
    }

    function _executeCall(bytes32 target, bytes memory payload) private {
        SwapVMKernel.VMEnvelope memory envelope = _signedCall(target, payload);
        vm.startBroadcast(actorKey);
        router.buyVMExactInput{value: VM_INPUT}(worldId, TickMath.MIN_SQRT_PRICE + 1, envelope);
        vm.stopBroadcast();
    }

    function _signedDeploy(bytes32 codeHash, bytes memory payload)
        private
        view
        returns (SwapVMKernel.VMEnvelope memory envelope)
    {
        bytes32 actorId = kernel.eoaAccountId(actor);
        envelope = SwapVMKernel.VMEnvelope({
            op: SwapVMKernel.RootOp.DEPLOY,
            worldId: worldId,
            actor: actor,
            targetOrCodeHash: codeHash,
            payload: payload,
            byteGasLimit: DEPLOY_BYTE_LIMIT,
            minNetTokenOut: 1,
            nonce: kernel.nonces(worldId, actorId),
            deadline: uint64(block.timestamp + 1 days),
            recipient: actor,
            authorizedExecutor: actor,
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
                uint160(TickMath.MIN_SQRT_PRICE + 1),
                envelope.recipient,
                address(router),
                envelope.authorizedExecutor,
                envelope.nonce,
                envelope.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", kernel.domainSeparator(worldId), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(actorKey, digest);
        envelope.signature = abi.encodePacked(r, s, v);
    }

    function _signedCall(bytes32 target, bytes memory payload)
        private
        view
        returns (SwapVMKernel.VMEnvelope memory envelope)
    {
        bytes32 actorId = kernel.eoaAccountId(actor);
        envelope = SwapVMKernel.VMEnvelope({
            op: SwapVMKernel.RootOp.CALL,
            worldId: worldId,
            actor: actor,
            targetOrCodeHash: target,
            payload: payload,
            byteGasLimit: CALL_BYTE_LIMIT,
            minNetTokenOut: 1,
            nonce: kernel.nonces(worldId, actorId),
            deadline: uint64(block.timestamp + 1 days),
            recipient: actor,
            authorizedExecutor: actor,
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
                uint160(TickMath.MIN_SQRT_PRICE + 1),
                envelope.recipient,
                address(router),
                envelope.authorizedExecutor,
                envelope.nonce,
                envelope.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", kernel.domainSeparator(worldId), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(actorKey, digest);
        envelope.signature = abi.encodePacked(r, s, v);
    }
}
