// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {SwapVMCreationCodeStore} from "../src/SwapVMCreationCodeStore.sol";
import {SwapVMGasToken} from "../src/SwapVMGasToken.sol";
import {SwapVMHook} from "../src/SwapVMHook.sol";
import {SwapVMKernel} from "../src/SwapVMKernel.sol";
import {SwapVMRouter} from "../src/SwapVMRouter.sol";
import {SwapVMWorldFactory} from "../src/SwapVMWorldFactory.sol";

/// @dev Local-Anvil-only helper. It catches deliberately failing buys so their rollback can be asserted on-chain.
contract Stage7DU1FailureProbe {
    SwapVMRouter public immutable router;
    address public immutable operator;

    error OnlyOperator();

    constructor(SwapVMRouter target, address initialOperator) payable {
        router = target;
        operator = initialOperator;
    }

    function execute(bytes32 worldId, uint160 priceLimit, SwapVMKernel.VMEnvelope calldata envelope)
        external
        returns (bool success)
    {
        if (msg.sender != operator) revert OnlyOperator();
        try router.buyVMExactInput{value: 1 ether}(worldId, priceLimit, envelope) returns (BalanceDelta) {
            return true;
        } catch {
            return false;
        }
    }

    receive() external payable {}
}

/// @notice Executes one complete zero-value release rehearsal through production Factory and Router.
contract Stage7DU1RehearsalScript is Script {
    using PoolIdLibrary for PoolKey;
    using stdJson for string;

    uint256 private constant INITIAL_SUPPLY = 1e36;
    uint160 private constant SQRT_PRICE_1_1 = 1 << 96;
    uint32 private constant ACTION_LIMIT = 10_000;

    uint256 private actorKey;
    address private actor;
    uint256 private vector;
    uint128 private byteGasPrice;
    uint24 private poolFee;
    int24 private tickSpacing;
    PoolManager private manager;
    SwapVMWorldFactory private factory;
    SwapVMCreationCodeStore private kernelStore;
    SwapVMCreationCodeStore private hookStore;
    SwapVMRouter private router;
    SwapVMGasToken private token;
    SwapVMKernel private kernel;
    SwapVMHook private hook;
    PoolModifyLiquidityTest private liquidityRouter;
    Stage7DU1FailureProbe private failureProbe;
    PoolKey private key;
    bytes32 private worldId;
    bytes32 private miniToken;

    function run() external {
        actorKey = vm.envUint("STAGE7D_LOCAL_PRIVATE_KEY");
        actor = vm.addr(actorKey);
        vector = vm.envUint("STAGE7D_VECTOR");
        byteGasPrice = uint128(vm.envUint("STAGE7D_BYTE_GAS_PRICE"));
        poolFee = uint24(vm.envUint("STAGE7D_POOL_FEE"));
        tickSpacing = int24(vm.envInt("STAGE7D_TICK_SPACING"));
        require(block.chainid == 31337, "isolated Anvil only");
        require(vector != 0 && byteGasPrice != 0 && poolFee < 1_000_000 && tickSpacing > 0, "invalid vector");

        _deployAndSeal();
        _bootstrap();
        _nopBuy();
        _deployAndCallReference();
        _deployAndCallTinySol();
        _sell();
        _failureRollbacks();
        _withdrawProjectLiquidity();
        _report();
    }

    function _deployAndSeal() private {
        vm.startBroadcast(actorKey);
        manager = new PoolManager(actor);
        kernelStore = new SwapVMCreationCodeStore(type(SwapVMKernel).creationCode);
        hookStore = new SwapVMCreationCodeStore(type(SwapVMHook).creationCode);
        factory = new SwapVMWorldFactory(
            manager,
            address(manager).codehash,
            address(kernelStore),
            address(hookStore),
            vm.envAddress("SVM_PROTOCOL_FEE_ADMIN"),
            vm.envAddress("SVM_FEE_CONTROLLER")
        );
        router = SwapVMRouter(payable(factory.router()));
        liquidityRouter = new PoolModifyLiquidityTest(manager);
        failureProbe = new Stage7DU1FailureProbe{value: 3 ether}(router, actor);
        vm.stopBroadcast();

        bytes32 tokenSalt = keccak256(abi.encode("stage7d-token", vector, byteGasPrice, poolFee));
        bytes32 bootstrapSalt = keccak256(abi.encode("stage7d-bootstrap", vector, tickSpacing));
        address predictedToken = factory.predictGasToken(tokenSalt, INITIAL_SUPPLY, actor);
        address predictedDeployer = factory.predictWorldDeployer(bootstrapSalt);
        address predictedKernel = factory.predictKernel(predictedDeployer);
        bytes memory hookArgs = abi.encode(
            manager,
            SwapVMKernel(predictedKernel),
            predictedToken,
            factory.initialProtocolFeeAdmin(),
            factory.feeController(),
            factory.initialProtocolFeeBps(),
            byteGasPrice,
            poolFee,
            tickSpacing
        );
        (address predictedHook, bytes32 hookSalt) = HookMiner.find(
            predictedDeployer,
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG,
            type(SwapVMHook).creationCode,
            hookArgs
        );
        SwapVMWorldFactory.CreateWorldParams memory params = SwapVMWorldFactory.CreateWorldParams({
            tokenSalt: tokenSalt,
            bootstrapSalt: bootstrapSalt,
            hookSalt: hookSalt,
            predictedKernel: predictedKernel,
            predictedHook: predictedHook,
            initialSupply: INITIAL_SUPPLY,
            initialHolder: actor,
            distributionCommitment: keccak256(abi.encode("zero-value-test-distribution", vector)),
            byteGasPrice: byteGasPrice,
            poolFee: poolFee,
            tickSpacing: tickSpacing,
            initialSqrtPriceX96: SQRT_PRICE_1_1
        });
        vm.startBroadcast(actorKey);
        (worldId, token, kernel, hook) = factory.createWorld(params);
        vm.stopBroadcast();
        bool isSealed;
        (key, isSealed) = factory.getPoolKey(worldId);
        require(isSealed && PoolId.unwrap(key.toId()) == worldId, "world not sealed");
        require(kernel.hook() == address(hook) && address(hook.kernel()) == address(kernel), "binding mismatch");
    }

    function _bootstrap() private {
        int24 width = tickSpacing * 10;
        vm.startBroadcast(actorKey);
        token.approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity{value: 20_000 ether}(
            key,
            ModifyLiquidityParams({tickLower: -width, tickUpper: width, liquidityDelta: 1e23, salt: bytes32(0)}),
            bytes("")
        );
        vm.stopBroadcast();
    }

    function _nopBuy() private {
        vm.startBroadcast(actorKey);
        router.buyNOPExactInput{value: 1 ether}(worldId, 1, TickMath.MIN_SQRT_PRICE + 1, actor);
        vm.stopBroadcast();
    }

    function _deployAndCallReference() private {
        bytes memory packageBytes = _fixturePackage("reference/SRC20-v1.json");
        bytes32 actorId = kernel.eoaAccountId(actor);
        bytes memory constructorInput =
            abi.encode(bytes32("Stage7D Token"), bytes32("S7D"), uint256(18), uint256(1_000), actorId);
        bytes32 target = _nextContract(packageBytes);
        _executeBuy(
            SwapVMKernel.RootOp.DEPLOY,
            keccak256(packageBytes),
            _deployPayload(packageBytes, constructorInput),
            ACTION_LIMIT,
            actor
        );
        bytes memory transfer = abi.encodePacked(
            bytes4(keccak256("transfer(bytes32,uint256)")), abi.encode(kernel.eoaAccountId(address(0xCAFE)), uint256(7))
        );
        _executeBuy(SwapVMKernel.RootOp.CALL, target, transfer, ACTION_LIMIT, actor);
    }

    function _deployAndCallTinySol() private {
        bytes memory packageBytes = _fixturePackage("tooling/tinysol/fixtures/compiler/MiniToken.json");
        bytes32 actorId = kernel.eoaAccountId(actor);
        miniToken = _nextContract(packageBytes);
        _executeBuy(
            SwapVMKernel.RootOp.DEPLOY,
            keccak256(packageBytes),
            _deployPayload(packageBytes, abi.encode(uint256(1_000), actorId)),
            ACTION_LIMIT,
            actor
        );
        bytes memory transfer = abi.encodePacked(
            bytes4(keccak256("transfer(bytes32,uint256)")), abi.encode(kernel.eoaAccountId(address(0xBEEF)), uint256(9))
        );
        _executeBuy(SwapVMKernel.RootOp.CALL, miniToken, transfer, ACTION_LIMIT, actor);
    }

    function _sell() private {
        uint64 beforeHeight = kernel.executionHeight(worldId);
        uint256 beforeSupply = token.totalSupply();
        vm.startBroadcast(actorKey);
        token.approve(address(router), type(uint256).max);
        router.sellExactInput(worldId, uint128(1e15), 1, TickMath.MAX_SQRT_PRICE - 1, actor);
        vm.stopBroadcast();
        require(
            kernel.executionHeight(worldId) == beforeHeight && token.totalSupply() == beforeSupply, "sell entered VM"
        );
    }

    function _failureRollbacks() private {
        uint64 beforeHeight = kernel.executionHeight(worldId);
        uint64 nonce = kernel.nonces(worldId, kernel.eoaAccountId(actor));
        uint256 beforeSupply = token.totalSupply();
        bytes memory impossibleTransfer = abi.encodePacked(
            bytes4(keccak256("transfer(bytes32,uint256)")),
            abi.encode(kernel.eoaAccountId(address(0xDEAD)), type(uint256).max)
        );
        SwapVMKernel.VMEnvelope memory reverting = _signedAction(
            SwapVMKernel.RootOp.CALL, miniToken, impossibleTransfer, ACTION_LIMIT, nonce, address(failureProbe)
        );
        vm.startBroadcast(actorKey);
        bool revertUnexpectedlySucceeded = failureProbe.execute(worldId, TickMath.MIN_SQRT_PRICE + 1, reverting);
        vm.stopBroadcast();
        require(!revertUnexpectedlySucceeded, "revert buy succeeded");
        require(
            kernel.executionHeight(worldId) == beforeHeight && token.totalSupply() == beforeSupply, "revert committed"
        );

        bytes memory validTransfer = abi.encodePacked(
            bytes4(keccak256("transfer(bytes32,uint256)")), abi.encode(kernel.eoaAccountId(address(0xD00D)), uint256(1))
        );
        SwapVMKernel.VMEnvelope memory outOfBytes =
            _signedAction(SwapVMKernel.RootOp.CALL, miniToken, validTransfer, 1, nonce, address(failureProbe));
        vm.startBroadcast(actorKey);
        bool oogUnexpectedlySucceeded = failureProbe.execute(worldId, TickMath.MIN_SQRT_PRICE + 1, outOfBytes);
        vm.stopBroadcast();
        require(!oogUnexpectedlySucceeded, "OutOfByteGas buy succeeded");
        require(kernel.executionHeight(worldId) == beforeHeight && token.totalSupply() == beforeSupply, "OOG committed");
    }

    function _withdrawProjectLiquidity() private {
        int24 width = tickSpacing * 10;
        vm.startBroadcast(actorKey);
        liquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -width, tickUpper: width, liquidityDelta: -int256(1e23), salt: bytes32(0)
            }),
            bytes("")
        );
        vm.stopBroadcast();
    }

    function _executeBuy(SwapVMKernel.RootOp op, bytes32 target, bytes memory payload, uint32 limit, address executor)
        private
    {
        uint64 nonce = kernel.nonces(worldId, kernel.eoaAccountId(actor));
        SwapVMKernel.VMEnvelope memory action = _signedAction(op, target, payload, limit, nonce, executor);
        vm.startBroadcast(actorKey);
        router.buyVMExactInput{value: 1 ether}(worldId, TickMath.MIN_SQRT_PRICE + 1, action);
        vm.stopBroadcast();
    }

    function _signedAction(
        SwapVMKernel.RootOp op,
        bytes32 target,
        bytes memory payload,
        uint32 limit,
        uint64 nonce,
        address executor
    ) private view returns (SwapVMKernel.VMEnvelope memory action) {
        action = SwapVMKernel.VMEnvelope({
            op: op,
            worldId: worldId,
            actor: actor,
            targetOrCodeHash: target,
            payload: payload,
            byteGasLimit: limit,
            minNetTokenOut: 1,
            nonce: nonce,
            deadline: uint64(block.timestamp + 1 days),
            recipient: actor,
            authorizedExecutor: executor,
            signature: bytes("")
        });
        bytes32 structHash = keccak256(
            abi.encode(
                kernel.VM_ACTION_TYPEHASH(),
                uint8(action.op),
                action.worldId,
                action.actor,
                action.targetOrCodeHash,
                keccak256(action.payload),
                action.byteGasLimit,
                action.minNetTokenOut,
                uint128(1 ether),
                uint160(TickMath.MIN_SQRT_PRICE + 1),
                action.recipient,
                address(router),
                action.authorizedExecutor,
                action.nonce,
                action.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", kernel.domainSeparator(worldId), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(actorKey, digest);
        action.signature = abi.encodePacked(r, s, v);
    }

    function _nextContract(bytes memory packageBytes) private view returns (bytes32) {
        bytes32 actorId = kernel.eoaAccountId(actor);
        return
            kernel.contractAccountId(worldId, actorId, kernel.creatorNonce(worldId, actorId), keccak256(packageBytes));
    }

    function _deployPayload(bytes memory packageBytes, bytes memory constructorInput)
        private
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(bytes4(uint32(packageBytes.length)), packageBytes, constructorInput);
    }

    function _fixturePackage(string memory path) private view returns (bytes memory) {
        return vm.readFile(path).readBytes(".package");
    }

    function _report() private view {
        SwapVMWorldFactory.WorldConfig memory config = factory.getWorldConfig(worldId);
        console2.log("STAGE7D_VECTOR", vector);
        console2.log("STAGE7D_MANAGER", address(manager));
        console2.log("STAGE7D_FACTORY", address(factory));
        console2.log("STAGE7D_ROUTER", address(router));
        console2.log("STAGE7D_REGISTRY", address(factory.referenceRegistry()));
        console2.log("STAGE7D_KERNEL_STORE", address(kernelStore));
        console2.log("STAGE7D_HOOK_STORE", address(hookStore));
        console2.log("STAGE7D_WORLD_DEPLOYER", config.worldDeployer);
        console2.log("STAGE7D_TOKEN", address(token));
        console2.log("STAGE7D_KERNEL", address(kernel));
        console2.log("STAGE7D_HOOK", address(hook));
        console2.log("STAGE7D_WORLD_ID");
        console2.logBytes32(worldId);
        console2.log("STAGE7D_CONFIG_HASH");
        console2.logBytes32(config.configHash);
        console2.log("STAGE7D_HEIGHT", kernel.executionHeight(worldId));
        console2.log("STAGE7D_SEALED_BLOCK", config.sealedAtBlock);
        console2.log("STAGE7D_DISTRIBUTION_COMMITMENT");
        console2.logBytes32(config.distributionCommitment);
        console2.log("STAGE7D_SUPPLY", token.totalSupply());
        console2.log("STAGE7D_RELEASE_UNAUDITED", true);
        console2.log("STAGE7D_PROJECT_LP_WITHDRAWN", true);
    }
}
