// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";

import {SwapVMGasToken} from "../src/SwapVMGasToken.sol";
import {SwapVMHook} from "../src/SwapVMHook.sol";
import {SwapVMKernel} from "../src/SwapVMKernel.sol";
import {SwapVMWorldFactory} from "../src/SwapVMWorldFactory.sol";

interface IOfficialUniversalRouter {
    function poolManager() external view returns (address);
    function V4_POSITION_MANAGER() external view returns (address);
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IOfficialPositionManager {
    function poolManager() external view returns (address);
    function permit2() external view returns (address);
}

/// @notice Proves that the latest official Uniswap Universal Router can execute an authenticated SVM action.
contract EventsBaseSepoliaUniversalRouterScript is Script {
    uint256 private constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    address private constant ACTOR = 0x590a77Ec892bB78206bcad2444B62d1bC31A2D03;
    address private constant POOL_MANAGER = 0xf7F5aB3DcA35e17dE187b459159BC643853B3c67;
    address private constant POSITION_MANAGER = 0x0B32f74f8365d535783949E014B7754047B64e31;
    address private constant UNIVERSAL_ROUTER = 0x8B844f885672f333Bc0042cB669255f93a4C1E6b;
    address private constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    bytes32 private constant POOL_MANAGER_CODE_HASH =
        0xd49bdfce86ce75c9927a3b7db8fae5b63c3f82ce75b099084bad315485e826cc;
    bytes32 private constant POSITION_MANAGER_CODE_HASH =
        0x3c87fb51995d3b4c4e0a49b22ed3a2497d0e9ba24c29419a56c88c926ad9cbb1;
    bytes32 private constant UNIVERSAL_ROUTER_CODE_HASH =
        0x01577a50bc57965c0eb0e4081ff096f02924449a8954b75323517f83c7d6ca2b;

    uint128 private constant VM_INPUT = 0.000001 ether;
    uint32 private constant TOKEN_LIMIT = 1_000;
    uint160 private constant SQRT_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;

    SwapVMWorldFactory private factory;
    SwapVMKernel private kernel;
    SwapVMHook private hook;
    SwapVMGasToken private gasToken;
    bytes32 private worldId;
    bytes32 private token;
    uint256 private actorKey;

    function run() external {
        _loadAndValidateBindings();
        (uint64 heightBefore, uint64 nonceBefore, uint256 balanceBefore, uint256 supplyBefore, uint256 feesBefore) =
            _snapshot();

        SwapVMKernel.VMEnvelope memory envelope = _signedMintEnvelope(nonceBefore);
        bytes[] memory inputs = _universalRouterInputs(envelope);

        vm.startBroadcast(actorKey);
        IOfficialUniversalRouter(UNIVERSAL_ROUTER).execute{value: VM_INPUT}(
            hex"10", inputs, block.timestamp + 10 minutes
        );
        vm.stopBroadcast();

        require(kernel.executionHeight(worldId) == heightBefore + 1, "UNIVERSAL_ROUTER_HEIGHT");
        require(kernel.nonces(worldId, kernel.eoaAccountId(ACTOR)) == nonceBefore + 1, "UNIVERSAL_ROUTER_NONCE");
        require(_tokenBalance(kernel.eoaAccountId(ACTOR)) == balanceBefore + 1_000 ether, "UNIVERSAL_ROUTER_MINT");
        require(gasToken.totalSupply() < supplyBefore, "UNIVERSAL_ROUTER_BURN");
        require(hook.accruedProtocolFees() == feesBefore + hook.protocolFee(VM_INPUT), "UNIVERSAL_ROUTER_FEE");
        require(
            IPoolManager(POOL_MANAGER).balanceOf(address(hook), Currency.wrap(address(0)).toId())
                == hook.accruedProtocolFees(),
            "UNIVERSAL_ROUTER_FEE_CLAIM"
        );

        console2.log("OFFICIAL_UNIVERSAL_ROUTER", UNIVERSAL_ROUTER);
        console2.log("OFFICIAL_UNIVERSAL_ROUTER_EXECUTION_HEIGHT", kernel.executionHeight(worldId));
        console2.log("OFFICIAL_UNIVERSAL_ROUTER_PROTOCOL_FEE_WEI", hook.protocolFee(VM_INPUT));
        console2.log("OFFICIAL_UNIVERSAL_ROUTER_GAS_TOKEN_BURNED", supplyBefore - gasToken.totalSupply());
    }

    function _loadAndValidateBindings() private {
        require(block.chainid == BASE_SEPOLIA_CHAIN_ID, "BASE_SEPOLIA_ONLY");
        require(POOL_MANAGER.codehash == POOL_MANAGER_CODE_HASH, "POOL_MANAGER_CODE_HASH");
        require(POSITION_MANAGER.codehash == POSITION_MANAGER_CODE_HASH, "POSITION_MANAGER_CODE_HASH");
        require(UNIVERSAL_ROUTER.codehash == UNIVERSAL_ROUTER_CODE_HASH, "UNIVERSAL_ROUTER_CODE_HASH");
        require(IOfficialUniversalRouter(UNIVERSAL_ROUTER).poolManager() == POOL_MANAGER, "ROUTER_POOL_MANAGER");
        require(
            IOfficialUniversalRouter(UNIVERSAL_ROUTER).V4_POSITION_MANAGER() == POSITION_MANAGER,
            "ROUTER_POSITION_MANAGER"
        );
        require(IOfficialPositionManager(POSITION_MANAGER).poolManager() == POOL_MANAGER, "POSITION_POOL_MANAGER");
        require(IOfficialPositionManager(POSITION_MANAGER).permit2() == PERMIT2, "POSITION_PERMIT2");

        actorKey = vm.envUint("STAGE7A2_PRIVATE_KEY");
        require(vm.addr(actorKey) == ACTOR, "ACTOR_MISMATCH");
        factory = SwapVMWorldFactory(vm.envAddress("SVM_FACTORY_ADDRESS"));
        kernel = SwapVMKernel(vm.envAddress("SVM_KERNEL_ADDRESS"));
        hook = SwapVMHook(payable(vm.envAddress("SVM_HOOK_ADDRESS")));
        gasToken = SwapVMGasToken(vm.envAddress("SVM_GAS_TOKEN_ADDRESS"));
        worldId = vm.envBytes32("SVM_WORLD_ID");
        token = vm.envBytes32("SVM_DEFAULT_SRC20_ID");

        require(address(factory.poolManager()) == POOL_MANAGER, "FACTORY_POOL_MANAGER");
        require(address(hook.poolManager()) == POOL_MANAGER, "HOOK_POOL_MANAGER");
        require(address(kernel.hook()) == address(hook), "KERNEL_HOOK");
        require(address(hook.gasToken()) == address(gasToken), "HOOK_GAS_TOKEN");
        require(kernel.programCodeHash(worldId, token) != bytes32(0), "SRC20_NOT_DEPLOYED");
    }

    function _snapshot()
        private
        view
        returns (uint64 height, uint64 nonce, uint256 balance, uint256 supply, uint256 fees)
    {
        bytes32 actorId = kernel.eoaAccountId(ACTOR);
        height = kernel.executionHeight(worldId);
        nonce = kernel.nonces(worldId, actorId);
        balance = _tokenBalance(actorId);
        supply = gasToken.totalSupply();
        fees = hook.accruedProtocolFees();
    }

    function _signedMintEnvelope(uint64 nonce) private view returns (SwapVMKernel.VMEnvelope memory envelope) {
        bytes32 actorId = kernel.eoaAccountId(ACTOR);
        envelope = SwapVMKernel.VMEnvelope({
            op: SwapVMKernel.RootOp.CALL,
            worldId: worldId,
            actor: ACTOR,
            targetOrCodeHash: token,
            payload: abi.encodePacked(bytes4(keccak256("mint(bytes32)")), abi.encode(actorId)),
            byteGasLimit: TOKEN_LIMIT,
            minNetTokenOut: 1,
            nonce: nonce,
            deadline: uint64(block.timestamp + 10 minutes),
            recipient: ACTOR,
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
                UNIVERSAL_ROUTER,
                envelope.authorizedExecutor,
                envelope.nonce,
                envelope.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", kernel.domainSeparator(worldId), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(actorKey, digest);
        envelope.signature = abi.encodePacked(r, s, v);
    }

    function _universalRouterInputs(SwapVMKernel.VMEnvelope memory envelope)
        private
        view
        returns (bytes[] memory inputs)
    {
        (PoolKey memory key, bool isSealed) = factory.getPoolKey(worldId);
        require(isSealed, "WORLD_NOT_SEALED");

        bytes[] memory actionParams = new bytes[](3);
        actionParams[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: VM_INPUT,
                amountOutMinimum: envelope.minNetTokenOut,
                minHopPriceX36: 0,
                hookData: abi.encode(envelope)
            })
        );
        actionParams[1] = abi.encode(Currency.wrap(address(0)), uint256(VM_INPUT));
        actionParams[2] = abi.encode(key.currency1, uint256(envelope.minNetTokenOut));

        inputs = new bytes[](1);
        inputs[0] = abi.encode(hex"060c0f", actionParams);
    }

    function _tokenBalance(bytes32 owner) private view returns (uint256 amount) {
        (bytes memory output,) = kernel.staticCall(
            worldId, token, abi.encodePacked(bytes4(keccak256("balanceOf(bytes32)")), abi.encode(owner)), 2_000
        );
        require(output.length == 32, "BALANCE_WIDTH");
        amount = abi.decode(output, (uint256));
    }
}
