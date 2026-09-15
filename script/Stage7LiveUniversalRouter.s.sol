// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";

import {SwaputerToken} from "../src/SwaputerToken.sol";
import {SwaputerHook} from "../src/SwaputerHook.sol";
import {SwaputerKernel} from "../src/SwaputerKernel.sol";
import {SwaputerWorldFactory} from "../src/SwaputerWorldFactory.sol";

interface ILiveOfficialUniversalRouter {
    function poolManager() external view returns (address);
    function V4_POSITION_MANAGER() external view returns (address);
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface ILiveOfficialPositionManager {
    function poolManager() external view returns (address);
    function permit2() external view returns (address);
}

/// @notice Recurring Base Sepolia proof that the official Universal Router can directly DEPLOY and CALL SVM.
contract Stage7LiveUniversalRouterScript is Script {
    using stdJson for string;

    uint256 private constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    address private constant DEFAULT_ACTOR = 0x590a77Ec892bB78206bcad2444B62d1bC31A2D03;
    uint128 private constant VM_INPUT = 0.000001 ether;
    uint32 private constant ACTION_LIMIT = 2_000;
    uint32 private constant DEPLOY_EXECUTED_BYTES = 73;
    uint32 private constant CALL_EXECUTED_BYTES = 191;
    uint160 private constant SQRT_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;

    SwaputerWorldFactory private factory;
    SwaputerKernel private kernel;
    SwaputerHook private hook;
    SwaputerToken private gasToken;
    ILiveOfficialUniversalRouter private universalRouter;
    PoolKey private poolKey;
    bytes32 private worldId;
    address private actor;
    uint256 private actorKey;

    function run() external {
        _loadAndValidateBindings();

        string memory compilerFixture = vm.readFile("tooling/tinysol/fixtures/compiler/Conformance.json");
        bytes memory packageBytes = compilerFixture.readBytes(".package");
        bytes32 codeHash = compilerFixture.readBytes32(".codeHash");
        require(keccak256(packageBytes) == codeHash, "UNIVERSAL_ROUTER_PACKAGE_HASH");

        bytes32 actorId = kernel.eoaAccountId(actor);
        uint64 heightBefore = kernel.executionHeight(worldId);
        uint64 nonceBefore = kernel.nonces(worldId, actorId);
        uint64 creatorNonceBefore = kernel.creatorNonce(worldId, actorId);
        bytes32 programId = kernel.contractAccountId(worldId, actorId, creatorNonceBefore, codeHash);
        uint256 supplyBefore = gasToken.totalSupply();
        uint256 feesBefore = hook.accruedProtocolFees();
        uint256 feePerSwap = hook.protocolFee(VM_INPUT);
        require(feePerSwap > 0, "UNIVERSAL_ROUTER_FEE_DISABLED");

        bytes memory deployPayload =
            abi.encodePacked(bytes4(uint32(packageBytes.length)), packageBytes, abi.encode(uint256(5)));
        _execute(_signedAction(SwaputerKernel.RootOp.DEPLOY, codeHash, deployPayload, nonceBefore));

        require(kernel.executionHeight(worldId) == heightBefore + 1, "UNIVERSAL_ROUTER_DEPLOY_HEIGHT");
        require(kernel.nonces(worldId, actorId) == nonceBefore + 1, "UNIVERSAL_ROUTER_DEPLOY_NONCE");
        require(kernel.creatorNonce(worldId, actorId) == creatorNonceBefore + 1, "UNIVERSAL_ROUTER_CREATOR_NONCE");
        require(kernel.programCodeHash(worldId, programId) == codeHash, "UNIVERSAL_ROUTER_DEPLOY_CODE_HASH");
        require(kernel.executedBytes(worldId) == DEPLOY_EXECUTED_BYTES, "UNIVERSAL_ROUTER_DEPLOY_BYTES");
        require(_queryUint(programId, "getScalar()", bytes("")) == 5, "UNIVERSAL_ROUTER_CONSTRUCTOR_STATE");
        require(
            supplyBefore - gasToken.totalSupply() == uint256(DEPLOY_EXECUTED_BYTES) * kernel.byteGasPrice(),
            "UNIVERSAL_ROUTER_DEPLOY_BURN"
        );
        require(hook.accruedProtocolFees() == feesBefore + feePerSwap, "UNIVERSAL_ROUTER_DEPLOY_FEE");

        bytes memory callPayload =
            abi.encodePacked(bytes4(keccak256("controlFlow(uint256,bool)")), abi.encode(uint256(4), true));
        _execute(_signedAction(SwaputerKernel.RootOp.CALL, programId, callPayload, nonceBefore + 1));

        uint256 expectedBurn = uint256(DEPLOY_EXECUTED_BYTES + CALL_EXECUTED_BYTES) * kernel.byteGasPrice();
        require(kernel.executionHeight(worldId) == heightBefore + 2, "UNIVERSAL_ROUTER_CALL_HEIGHT");
        require(kernel.nonces(worldId, actorId) == nonceBefore + 2, "UNIVERSAL_ROUTER_CALL_NONCE");
        require(kernel.executedBytes(worldId) == CALL_EXECUTED_BYTES, "UNIVERSAL_ROUTER_CALL_BYTES");
        require(_queryUint(programId, "getScalar()", bytes("")) == 14, "UNIVERSAL_ROUTER_CALL_STATE");
        require(supplyBefore - gasToken.totalSupply() == expectedBurn, "UNIVERSAL_ROUTER_TOTAL_BURN");
        require(hook.accruedProtocolFees() == feesBefore + (feePerSwap * 2), "UNIVERSAL_ROUTER_TOTAL_FEE");
        require(
            IPoolManager(address(factory.poolManager())).balanceOf(address(hook), Currency.wrap(address(0)).toId())
                == hook.accruedProtocolFees(),
            "UNIVERSAL_ROUTER_FEE_CLAIM"
        );

        console2.log("LIVE_UNIVERSAL_ROUTER", address(universalRouter));
        console2.log("LIVE_UNIVERSAL_ROUTER_PROGRAM_ID");
        console2.logBytes32(programId);
        console2.log("LIVE_UNIVERSAL_ROUTER_HEIGHT_BEFORE", heightBefore);
        console2.log("LIVE_UNIVERSAL_ROUTER_HEIGHT_AFTER", kernel.executionHeight(worldId));
        console2.log("LIVE_UNIVERSAL_ROUTER_NONCE_BEFORE", nonceBefore);
        console2.log("LIVE_UNIVERSAL_ROUTER_NONCE_AFTER", kernel.nonces(worldId, actorId));
        console2.log("LIVE_UNIVERSAL_ROUTER_DEPLOY_EXECUTED_BYTES", DEPLOY_EXECUTED_BYTES);
        console2.log("LIVE_UNIVERSAL_ROUTER_CALL_EXECUTED_BYTES", CALL_EXECUTED_BYTES);
        console2.log(
            "LIVE_UNIVERSAL_ROUTER_DEPLOY_GAS_TOKEN_BURNED", uint256(DEPLOY_EXECUTED_BYTES) * kernel.byteGasPrice()
        );
        console2.log(
            "LIVE_UNIVERSAL_ROUTER_CALL_GAS_TOKEN_BURNED", uint256(CALL_EXECUTED_BYTES) * kernel.byteGasPrice()
        );
        console2.log("LIVE_UNIVERSAL_ROUTER_GAS_TOKEN_BURNED", expectedBurn);
        console2.log("LIVE_UNIVERSAL_ROUTER_BYTE_GAS_PRICE", kernel.byteGasPrice());
        console2.log("LIVE_UNIVERSAL_ROUTER_PROTOCOL_FEE_BPS", hook.protocolFeeBps());
        console2.log("LIVE_UNIVERSAL_ROUTER_PROTOCOL_FEE_WEI", feePerSwap * 2);
        console2.log("LIVE_UNIVERSAL_ROUTER_FINAL_SCALAR", _queryUint(programId, "getScalar()", bytes("")));
    }

    function _loadAndValidateBindings() private {
        require(block.chainid == BASE_SEPOLIA_CHAIN_ID, "BASE_SEPOLIA_ONLY");
        actorKey = vm.envUint("STAGE7A2_PRIVATE_KEY");
        actor = vm.envOr("STAGE7A2_ACTOR", DEFAULT_ACTOR);
        require(vm.addr(actorKey) == actor, "ACTOR_MISMATCH");

        address poolManager = vm.envAddress("SVM_UNISWAP_POOL_MANAGER_ADDRESS");
        address positionManager = vm.envAddress("SVM_UNISWAP_POSITION_MANAGER_ADDRESS");
        address permit2 = vm.envAddress("SVM_UNISWAP_PERMIT2_ADDRESS");
        address universalRouterAddress = vm.envAddress("SVM_UNISWAP_UNIVERSAL_ROUTER_ADDRESS");
        require(
            poolManager.codehash == vm.envBytes32("SVM_UNISWAP_POOL_MANAGER_CODE_HASH"),
            "UNIVERSAL_ROUTER_POOL_MANAGER_CODE_HASH"
        );
        require(
            positionManager.codehash == vm.envBytes32("SVM_UNISWAP_POSITION_MANAGER_CODE_HASH"),
            "UNIVERSAL_ROUTER_POSITION_MANAGER_CODE_HASH"
        );
        require(
            permit2.codehash == vm.envBytes32("SVM_UNISWAP_PERMIT2_CODE_HASH"), "UNIVERSAL_ROUTER_PERMIT2_CODE_HASH"
        );
        require(
            universalRouterAddress.codehash == vm.envBytes32("SVM_UNISWAP_UNIVERSAL_ROUTER_CODE_HASH"),
            "UNIVERSAL_ROUTER_CODE_HASH"
        );

        universalRouter = ILiveOfficialUniversalRouter(universalRouterAddress);
        require(universalRouter.poolManager() == poolManager, "UNIVERSAL_ROUTER_POOL_MANAGER");
        require(universalRouter.V4_POSITION_MANAGER() == positionManager, "UNIVERSAL_ROUTER_POSITION_MANAGER");
        require(ILiveOfficialPositionManager(positionManager).poolManager() == poolManager, "POSITION_POOL_MANAGER");
        require(ILiveOfficialPositionManager(positionManager).permit2() == permit2, "POSITION_PERMIT2");

        factory = SwaputerWorldFactory(vm.envAddress("SVM_FACTORY_ADDRESS"));
        kernel = SwaputerKernel(vm.envAddress("SVM_KERNEL_ADDRESS"));
        hook = SwaputerHook(payable(vm.envAddress("SVM_HOOK_ADDRESS")));
        gasToken = SwaputerToken(vm.envAddress("SVM_GAS_TOKEN_ADDRESS"));
        worldId = vm.envBytes32("SVM_WORLD_ID");
        bool isSealed;
        (poolKey, isSealed) = factory.getPoolKey(worldId);

        require(isSealed, "WORLD_NOT_SEALED");
        require(address(factory.poolManager()) == poolManager, "FACTORY_POOL_MANAGER");
        require(address(hook.poolManager()) == poolManager, "HOOK_POOL_MANAGER");
        require(address(poolKey.hooks) == address(hook), "POOL_HOOK");
        require(Currency.unwrap(poolKey.currency0) == address(0), "POOL_NATIVE_CURRENCY");
        require(Currency.unwrap(poolKey.currency1) == address(gasToken), "POOL_GAS_TOKEN");
        require(poolKey.fee == vm.envUint("SVM_UNISWAP_POOL_FEE"), "POOL_FEE");
        require(uint256(uint24(poolKey.tickSpacing)) == vm.envUint("SVM_UNISWAP_TICK_SPACING"), "POOL_TICK_SPACING");
        require(address(kernel.hook()) == address(hook), "KERNEL_HOOK");
        require(address(hook.gasToken()) == address(gasToken), "HOOK_GAS_TOKEN");
    }

    function _execute(SwaputerKernel.VMEnvelope memory envelope) private {
        bytes[] memory actionParams = new bytes[](3);
        actionParams[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: true,
                amountIn: VM_INPUT,
                amountOutMinimum: envelope.minNetTokenOut,
                minHopPriceX36: 0,
                hookData: abi.encode(envelope)
            })
        );
        actionParams[1] = abi.encode(Currency.wrap(address(0)), uint256(VM_INPUT));
        actionParams[2] = abi.encode(poolKey.currency1, uint256(envelope.minNetTokenOut));

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(hex"060c0f", actionParams);
        vm.startBroadcast(actorKey);
        universalRouter.execute{value: VM_INPUT}(hex"10", inputs, envelope.deadline);
        vm.stopBroadcast();
    }

    function _signedAction(SwaputerKernel.RootOp op, bytes32 target, bytes memory payload, uint64 nonce)
        private
        view
        returns (SwaputerKernel.VMEnvelope memory envelope)
    {
        envelope = SwaputerKernel.VMEnvelope({
            op: op,
            worldId: worldId,
            actor: actor,
            targetOrCodeHash: target,
            payload: payload,
            byteGasLimit: ACTION_LIMIT,
            minNetTokenOut: 1,
            nonce: nonce,
            deadline: uint64(block.timestamp + 10 minutes),
            recipient: actor,
            authorizedExecutor: address(0),
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
                SQRT_PRICE_LIMIT,
                envelope.recipient,
                address(universalRouter),
                envelope.authorizedExecutor,
                envelope.nonce,
                envelope.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", kernel.domainSeparator(worldId), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(actorKey, digest);
        envelope.signature = abi.encodePacked(r, s, v);
    }

    function _queryUint(bytes32 programId, string memory signature, bytes memory arguments)
        private
        view
        returns (uint256 value)
    {
        (bytes memory output,) = kernel.staticCall(
            worldId, programId, abi.encodePacked(bytes4(keccak256(bytes(signature))), arguments), ACTION_LIMIT
        );
        require(output.length == 32, "UNIVERSAL_ROUTER_QUERY_WIDTH");
        value = abi.decode(output, (uint256));
    }
}
