// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {SwapVMGasToken} from "../src/SwapVMGasToken.sol";
import {SwapVMKernel} from "../src/SwapVMKernel.sol";
import {SwapVMRouter} from "../src/SwapVMRouter.sol";

/// @notice Deploys, constructor-mints and transfers a canonical SRC-20 on the Base Sepolia U2 World.
/// @dev Canonical SRC-20 v1 intentionally has no post-deployment mint function.
contract Stage7DU2SRC20Script is Script {
    using stdJson for string;

    uint256 private constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    uint256 private constant RELEASE_START_BALANCE = 12_413_260_640_785_848_061;
    uint256 private constant RELEASE_ETH_CAP = 0.5 ether;

    address private constant ACTOR = 0x590a77Ec892bB78206bcad2444B62d1bC31A2D03;
    address private constant RECIPIENT = 0x000000000000000000000000000000000000bEEF;
    SwapVMRouter private constant ROUTER = SwapVMRouter(payable(0xEDAbF849F3F74FE3C92FCEa50968332f77B06F07));
    SwapVMGasToken private constant GAS_TOKEN = SwapVMGasToken(0xe7bE2F5Af5281D81394c1ed22a27EDe5fdbb8775);
    SwapVMKernel private constant KERNEL = SwapVMKernel(0xA048C894A738185c24B4A5020Fb6708dAb160283);
    bytes32 private constant WORLD_ID = 0x9c414214b34b78217698b02c5b1a7af65f6d43c500ed2bd865ea4c54ed4360b9;

    uint128 private constant BUY_INPUT = 0.001 ether;
    uint32 private constant DEPLOY_BYTE_LIMIT = 200;
    uint32 private constant TRANSFER_BYTE_LIMIT = 350;
    uint256 private constant INITIAL_SUPPLY = 1_000_000 ether;
    uint256 private constant TRANSFER_AMOUNT = 123_456 ether;

    function run() external {
        require(block.chainid == BASE_SEPOLIA_CHAIN_ID, "BASE_SEPOLIA_ONLY");
        uint256 actorKey = vm.envUint("STAGE7A2_PRIVATE_KEY");
        require(vm.addr(actorKey) == ACTOR, "ACTOR_MISMATCH");
        _enforceReleaseCap();

        bytes memory packageBytes = vm.readFile("reference/SRC20-v1.json").readBytes(".package");
        bytes32 codeHash = keccak256(packageBytes);
        require(codeHash == 0x8699a93b015eb99ed1e30d713f1183f710eb92d6bbdb92fd7086490e84fde792, "SRC20_HASH");

        bytes32 actorId = KERNEL.eoaAccountId(ACTOR);
        bytes32 recipientId = KERNEL.eoaAccountId(RECIPIENT);
        uint64 creatorNonceBefore = KERNEL.creatorNonce(WORLD_ID, actorId);
        bytes32 contractId = KERNEL.contractAccountId(WORLD_ID, actorId, creatorNonceBefore, codeHash);
        uint64 actionNonceBefore = KERNEL.nonces(WORLD_ID, actorId);
        uint64 heightBefore = KERNEL.executionHeight(WORLD_ID);
        uint256 gasSupplyBefore = GAS_TOKEN.totalSupply();

        bytes memory constructorInput =
            abi.encode(bytes32("Swaputer Test SRC20"), bytes32("S20T"), uint256(18), INITIAL_SUPPLY, actorId);
        bytes memory deployPayload =
            abi.encodePacked(bytes4(uint32(packageBytes.length)), packageBytes, constructorInput);
        SwapVMKernel.VMEnvelope memory deployAction = _signedAction(
            actorKey, SwapVMKernel.RootOp.DEPLOY, codeHash, deployPayload, DEPLOY_BYTE_LIMIT, actionNonceBefore
        );

        vm.startBroadcast(actorKey);
        ROUTER.buyVMExactInput{value: BUY_INPUT}(WORLD_ID, TickMath.MIN_SQRT_PRICE + 1, deployAction);
        vm.stopBroadcast();

        require(KERNEL.creatorNonce(WORLD_ID, actorId) == creatorNonceBefore + 1, "CREATOR_NONCE");
        require(KERNEL.nonces(WORLD_ID, actorId) == actionNonceBefore + 1, "DEPLOY_ACTION_NONCE");
        require(KERNEL.executionHeight(WORLD_ID) == heightBefore + 1, "DEPLOY_HEIGHT");
        require(_queryUint(contractId, "totalSupply()", bytes("")) == INITIAL_SUPPLY, "TOTAL_SUPPLY");
        require(_balanceOf(contractId, actorId) == INITIAL_SUPPLY, "CONSTRUCTOR_MINT");
        require(_balanceOf(contractId, recipientId) == 0, "RECIPIENT_PREBALANCE");

        bytes memory transferPayload =
            abi.encodePacked(bytes4(keccak256("transfer(bytes32,uint256)")), abi.encode(recipientId, TRANSFER_AMOUNT));
        SwapVMKernel.VMEnvelope memory transferAction = _signedAction(
            actorKey, SwapVMKernel.RootOp.CALL, contractId, transferPayload, TRANSFER_BYTE_LIMIT, actionNonceBefore + 1
        );

        vm.startBroadcast(actorKey);
        ROUTER.buyVMExactInput{value: BUY_INPUT}(WORLD_ID, TickMath.MIN_SQRT_PRICE + 1, transferAction);
        vm.stopBroadcast();

        require(KERNEL.nonces(WORLD_ID, actorId) == actionNonceBefore + 2, "TRANSFER_ACTION_NONCE");
        require(KERNEL.executionHeight(WORLD_ID) == heightBefore + 2, "TRANSFER_HEIGHT");
        require(_balanceOf(contractId, actorId) == INITIAL_SUPPLY - TRANSFER_AMOUNT, "ACTOR_BALANCE");
        require(_balanceOf(contractId, recipientId) == TRANSFER_AMOUNT, "RECIPIENT_BALANCE");
        require(_queryUint(contractId, "totalSupply()", bytes("")) == INITIAL_SUPPLY, "SUPPLY_CHANGED");
        require(GAS_TOKEN.totalSupply() < gasSupplyBefore, "NO_VM_BURN");
        _enforceReleaseCap();

        console2.log("STAGE7D_U2_SRC20_CONTRACT_ID");
        console2.logBytes32(contractId);
        console2.log("STAGE7D_U2_SRC20_INITIAL_SUPPLY", INITIAL_SUPPLY);
        console2.log("STAGE7D_U2_SRC20_ACTOR_BALANCE", _balanceOf(contractId, actorId));
        console2.log("STAGE7D_U2_SRC20_RECIPIENT_BALANCE", _balanceOf(contractId, recipientId));
        console2.log("STAGE7D_U2_SRC20_HEIGHT", KERNEL.executionHeight(WORLD_ID));
        console2.log("STAGE7D_U2_SRC20_UNAUDITED", true);
    }

    function _signedAction(
        uint256 actorKey,
        SwapVMKernel.RootOp op,
        bytes32 target,
        bytes memory payload,
        uint32 byteLimit,
        uint64 nonce
    ) private view returns (SwapVMKernel.VMEnvelope memory action) {
        action = SwapVMKernel.VMEnvelope({
            op: op,
            worldId: WORLD_ID,
            actor: ACTOR,
            targetOrCodeHash: target,
            payload: payload,
            byteGasLimit: byteLimit,
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
                BUY_INPUT,
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

    function _balanceOf(bytes32 contractId, bytes32 accountId) private view returns (uint256) {
        return _queryUint(contractId, "balanceOf(bytes32)", abi.encode(accountId));
    }

    function _queryUint(bytes32 contractId, string memory signature, bytes memory arguments)
        private
        view
        returns (uint256 value)
    {
        (bytes memory output,) = KERNEL.staticCall(
            WORLD_ID, contractId, abi.encodePacked(bytes4(keccak256(bytes(signature))), arguments), 1_000
        );
        require(output.length == 32, "QUERY_WIDTH");
        value = abi.decode(output, (uint256));
    }

    function _enforceReleaseCap() private view {
        if (ACTOR.balance < RELEASE_START_BALANCE) {
            require(RELEASE_START_BALANCE - ACTOR.balance <= RELEASE_ETH_CAP, "RELEASE_ETH_CAP_EXCEEDED");
        }
    }
}
