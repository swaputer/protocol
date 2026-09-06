// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

import {SwapVMGasToken} from "../src/SwapVMGasToken.sol";
import {SwapVMHook} from "../src/SwapVMHook.sol";
import {SwapVMKernel} from "../src/SwapVMKernel.sol";
import {SwapVMRouter} from "../src/SwapVMRouter.sol";
import {SwapVMWorldFactory} from "../src/SwapVMWorldFactory.sol";

/// @notice Base Sepolia-only zero-value exercise of the sealed Stage 7D-U2 World.
/// @dev The official Uniswap test liquidity router is deliberately not a Swaputer production component.
contract Stage7DU2ExerciseScript is Script {
    using PoolIdLibrary for PoolKey;
    using stdJson for string;

    uint256 private constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    address private constant ACTOR = 0x590a77Ec892bB78206bcad2444B62d1bC31A2D03;
    SwapVMWorldFactory private constant FACTORY = SwapVMWorldFactory(0xF327e35FEA7EE7c92a765D1f00eD6A2A3db5b340);
    SwapVMRouter private constant ROUTER = SwapVMRouter(payable(0xEDAbF849F3F74FE3C92FCEa50968332f77B06F07));
    SwapVMGasToken private constant TOKEN = SwapVMGasToken(0xe7bE2F5Af5281D81394c1ed22a27EDe5fdbb8775);
    SwapVMKernel private constant KERNEL = SwapVMKernel(0xA048C894A738185c24B4A5020Fb6708dAb160283);
    SwapVMHook private constant HOOK = SwapVMHook(payable(0x8166eb00f52399Abdf725d1bB42A8344928A0044));
    PoolModifyLiquidityTest private constant LIQUIDITY_ROUTER =
        PoolModifyLiquidityTest(payable(0x37429cD17Cb1454C34E7F50b09725202Fd533039));
    bytes32 private constant LIQUIDITY_ROUTER_CODE_HASH =
        0x5d39a7244938a909f70906d72c9814c8024046513f5699cd6fb30d10d7e0a5db;
    bytes32 private constant WORLD_ID = 0x9c414214b34b78217698b02c5b1a7af65f6d43c500ed2bd865ea4c54ed4360b9;
    bytes32 private constant LP_SALT = keccak256("Swaputer Stage 7D-U2 Base Sepolia zero-value LP");
    uint128 private constant NOP_BUY_INPUT = 0.001 ether;
    uint128 private constant VM_BUY_INPUT = 0.002 ether;
    uint128 private constant SELL_INPUT = 0.0001 ether;
    uint32 private constant ACTION_LIMIT = 1_000;

    uint256 private actorKey;
    bytes32 private miniToken;

    function run() external {
        require(block.chainid == BASE_SEPOLIA_CHAIN_ID, "BASE_SEPOLIA_ONLY");
        require(address(LIQUIDITY_ROUTER).codehash == LIQUIDITY_ROUTER_CODE_HASH, "LIQUIDITY_ROUTER_MISMATCH");
        actorKey = vm.envUint("STAGE7A2_PRIVATE_KEY");
        require(vm.addr(actorKey) == ACTOR, "ACTOR_MISMATCH");
        require(address(FACTORY.poolManager()) == address(HOOK.poolManager()), "MANAGER_BINDING_MISMATCH");
        require(FACTORY.router() == address(ROUTER), "ROUTER_BINDING_MISMATCH");
        require(KERNEL.hook() == address(HOOK) && address(HOOK.kernel()) == address(KERNEL), "VM_BINDING_MISMATCH");

        (PoolKey memory key, bool isSealed) = FACTORY.getPoolKey(WORLD_ID);
        require(isSealed && PoolId.unwrap(key.toId()) == WORLD_ID, "WORLD_NOT_SEALED");

        _bootstrap(key);
        _nopBuy();
        _deployAndCallReference();
        _deployAndCallTinySol();
        _sell();

        console2.log("STAGE7D_U2_FINAL_HEIGHT", KERNEL.executionHeight(WORLD_ID));
        console2.log("STAGE7D_U2_FINAL_SUPPLY", TOKEN.totalSupply());
        console2.log("STAGE7D_U2_MINI_TOKEN");
        console2.logBytes32(miniToken);
        console2.log("STAGE7D_U2_UNAUDITED", true);
    }

    /// @notice Produces signed calldata for two transactions that must revert; it never broadcasts.
    function planFailures() external {
        require(block.chainid == BASE_SEPOLIA_CHAIN_ID, "BASE_SEPOLIA_ONLY");
        actorKey = vm.envUint("STAGE7A2_PRIVATE_KEY");
        require(vm.addr(actorKey) == ACTOR, "ACTOR_MISMATCH");
        miniToken = 0x015c8564aff561e136b5a382299364117c355580366c1992f5fceb79db6a7272;
        uint64 nonce = KERNEL.nonces(WORLD_ID, KERNEL.eoaAccountId(ACTOR));

        bytes memory impossibleTransfer = abi.encodePacked(
            bytes4(keccak256("transfer(bytes32,uint256)")),
            abi.encode(KERNEL.eoaAccountId(address(0xDEAD)), type(uint256).max)
        );
        SwapVMKernel.VMEnvelope memory reverting =
            _signedAction(SwapVMKernel.RootOp.CALL, miniToken, impossibleTransfer, ACTION_LIMIT, nonce);
        console2.log("STAGE7D_U2_REVERT_CALLDATA");
        console2.logBytes(
            abi.encodeCall(SwapVMRouter.buyVMExactInput, (WORLD_ID, TickMath.MIN_SQRT_PRICE + 1, reverting))
        );

        bytes memory validTransfer = abi.encodePacked(
            bytes4(keccak256("transfer(bytes32,uint256)")), abi.encode(KERNEL.eoaAccountId(address(0xD00D)), uint256(1))
        );
        SwapVMKernel.VMEnvelope memory outOfBytes =
            _signedAction(SwapVMKernel.RootOp.CALL, miniToken, validTransfer, 1, nonce);
        console2.log("STAGE7D_U2_OOG_CALLDATA");
        console2.logBytes(
            abi.encodeCall(SwapVMRouter.buyVMExactInput, (WORLD_ID, TickMath.MIN_SQRT_PRICE + 1, outOfBytes))
        );
    }

    function _bootstrap(PoolKey memory key) private {
        vm.startBroadcast(actorKey);
        TOKEN.approve(address(LIQUIDITY_ROUTER), type(uint256).max);
        LIQUIDITY_ROUTER.modifyLiquidity{value: 0.1 ether}(
            key,
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 3 ether, salt: LP_SALT}),
            bytes("")
        );
        TOKEN.approve(address(LIQUIDITY_ROUTER), 0);
        vm.stopBroadcast();
        require(TOKEN.allowance(ACTOR, address(LIQUIDITY_ROUTER)) == 0, "LIQUIDITY_ALLOWANCE_REMAINS");
    }

    function _nopBuy() private {
        vm.startBroadcast(actorKey);
        ROUTER.buyNOPExactInput{value: NOP_BUY_INPUT}(WORLD_ID, 1, TickMath.MIN_SQRT_PRICE + 1, ACTOR);
        vm.stopBroadcast();
        require(KERNEL.executionHeight(WORLD_ID) == 1 && KERNEL.executedBytes(WORLD_ID) == 1, "NOP_FAILED");
    }

    function _deployAndCallReference() private {
        bytes memory packageBytes = _fixturePackage("reference/SRC20-v1.json");
        bytes32 actorId = KERNEL.eoaAccountId(ACTOR);
        bytes memory constructorInput =
            abi.encode(bytes32("Stage7D Token"), bytes32("S7D"), uint256(18), uint256(1_000), actorId);
        bytes32 target = _nextContract(packageBytes);
        _executeBuy(
            SwapVMKernel.RootOp.DEPLOY,
            keccak256(packageBytes),
            _deployPayload(packageBytes, constructorInput),
            ACTION_LIMIT
        );
        bytes memory transfer = abi.encodePacked(
            bytes4(keccak256("transfer(bytes32,uint256)")), abi.encode(KERNEL.eoaAccountId(address(0xCAFE)), uint256(7))
        );
        _executeBuy(SwapVMKernel.RootOp.CALL, target, transfer, ACTION_LIMIT);
    }

    function _deployAndCallTinySol() private {
        bytes memory packageBytes = _fixturePackage("tooling/tinysol/fixtures/compiler/MiniToken.json");
        bytes32 actorId = KERNEL.eoaAccountId(ACTOR);
        miniToken = _nextContract(packageBytes);
        _executeBuy(
            SwapVMKernel.RootOp.DEPLOY,
            keccak256(packageBytes),
            _deployPayload(packageBytes, abi.encode(uint256(1_000), actorId)),
            ACTION_LIMIT
        );
        bytes memory transfer = abi.encodePacked(
            bytes4(keccak256("transfer(bytes32,uint256)")), abi.encode(KERNEL.eoaAccountId(address(0xBEEF)), uint256(9))
        );
        _executeBuy(SwapVMKernel.RootOp.CALL, miniToken, transfer, ACTION_LIMIT);
    }

    function _sell() private {
        uint64 beforeHeight = KERNEL.executionHeight(WORLD_ID);
        uint256 beforeSupply = TOKEN.totalSupply();
        vm.startBroadcast(actorKey);
        TOKEN.approve(address(ROUTER), SELL_INPUT);
        ROUTER.sellExactInput(WORLD_ID, SELL_INPUT, 1, TickMath.MAX_SQRT_PRICE - 1, ACTOR);
        TOKEN.approve(address(ROUTER), 0);
        vm.stopBroadcast();
        require(KERNEL.executionHeight(WORLD_ID) == beforeHeight, "SELL_EXECUTED_VM");
        require(TOKEN.totalSupply() == beforeSupply, "SELL_BURNED_TOKEN");
        require(TOKEN.allowance(ACTOR, address(ROUTER)) == 0, "ROUTER_ALLOWANCE_REMAINS");
    }

    function _failureRollbacks() private {
        uint64 beforeHeight = KERNEL.executionHeight(WORLD_ID);
        uint64 nonce = KERNEL.nonces(WORLD_ID, KERNEL.eoaAccountId(ACTOR));
        uint256 beforeSupply = TOKEN.totalSupply();
        bytes memory impossibleTransfer = abi.encodePacked(
            bytes4(keccak256("transfer(bytes32,uint256)")),
            abi.encode(KERNEL.eoaAccountId(address(0xDEAD)), type(uint256).max)
        );
        SwapVMKernel.VMEnvelope memory reverting =
            _signedAction(SwapVMKernel.RootOp.CALL, miniToken, impossibleTransfer, ACTION_LIMIT, nonce);
        vm.startBroadcast(actorKey);
        (bool revertUnexpectedlySucceeded,) = address(ROUTER).call{value: VM_BUY_INPUT}(
            abi.encodeCall(SwapVMRouter.buyVMExactInput, (WORLD_ID, TickMath.MIN_SQRT_PRICE + 1, reverting))
        );
        vm.stopBroadcast();
        require(!revertUnexpectedlySucceeded, "REVERT_BUY_SUCCEEDED");
        require(KERNEL.executionHeight(WORLD_ID) == beforeHeight, "REVERT_CHANGED_HEIGHT");
        require(TOKEN.totalSupply() == beforeSupply, "REVERT_CHANGED_SUPPLY");

        bytes memory validTransfer = abi.encodePacked(
            bytes4(keccak256("transfer(bytes32,uint256)")), abi.encode(KERNEL.eoaAccountId(address(0xD00D)), uint256(1))
        );
        SwapVMKernel.VMEnvelope memory outOfBytes =
            _signedAction(SwapVMKernel.RootOp.CALL, miniToken, validTransfer, 1, nonce);
        vm.startBroadcast(actorKey);
        (bool oogUnexpectedlySucceeded,) = address(ROUTER).call{value: VM_BUY_INPUT}(
            abi.encodeCall(SwapVMRouter.buyVMExactInput, (WORLD_ID, TickMath.MIN_SQRT_PRICE + 1, outOfBytes))
        );
        vm.stopBroadcast();
        require(!oogUnexpectedlySucceeded, "OUT_OF_BYTE_GAS_BUY_SUCCEEDED");
        require(KERNEL.executionHeight(WORLD_ID) == beforeHeight, "OOG_CHANGED_HEIGHT");
        require(TOKEN.totalSupply() == beforeSupply, "OOG_CHANGED_SUPPLY");
    }

    function _executeBuy(SwapVMKernel.RootOp op, bytes32 target, bytes memory payload, uint32 limit) private {
        uint64 nonce = KERNEL.nonces(WORLD_ID, KERNEL.eoaAccountId(ACTOR));
        SwapVMKernel.VMEnvelope memory action = _signedAction(op, target, payload, limit, nonce);
        vm.startBroadcast(actorKey);
        ROUTER.buyVMExactInput{value: VM_BUY_INPUT}(WORLD_ID, TickMath.MIN_SQRT_PRICE + 1, action);
        vm.stopBroadcast();
    }

    function _signedAction(SwapVMKernel.RootOp op, bytes32 target, bytes memory payload, uint32 limit, uint64 nonce)
        private
        view
        returns (SwapVMKernel.VMEnvelope memory action)
    {
        action = SwapVMKernel.VMEnvelope({
            op: op,
            worldId: WORLD_ID,
            actor: ACTOR,
            targetOrCodeHash: target,
            payload: payload,
            byteGasLimit: limit,
            minNetTokenOut: 1,
            nonce: nonce,
            deadline: uint64(block.timestamp + 1 days),
            recipient: ACTOR,
            authorizedExecutor: ACTOR,
            signature: bytes("")
        });
        bytes32 structHash = keccak256(
            abi.encode(
                KERNEL.VM_ACTION_TYPEHASH(),
                uint8(action.op),
                action.worldId,
                action.actor,
                action.targetOrCodeHash,
                keccak256(action.payload),
                action.byteGasLimit,
                action.minNetTokenOut,
                VM_BUY_INPUT,
                uint160(TickMath.MIN_SQRT_PRICE + 1),
                action.recipient,
                address(ROUTER),
                action.authorizedExecutor,
                action.nonce,
                action.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", KERNEL.domainSeparator(WORLD_ID), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(actorKey, digest);
        action.signature = abi.encodePacked(r, s, v);
    }

    function _nextContract(bytes memory packageBytes) private view returns (bytes32) {
        bytes32 actorId = KERNEL.eoaAccountId(ACTOR);
        return
            KERNEL.contractAccountId(WORLD_ID, actorId, KERNEL.creatorNonce(WORLD_ID, actorId), keccak256(packageBytes));
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
}
