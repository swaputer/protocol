// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {SwaputerToken} from "../src/SwaputerToken.sol";
import {SwaputerKernel} from "../src/SwaputerKernel.sol";
import {SwaputerAppRouter} from "../src/SwaputerAppRouter.sol";

/// @notice Deploys and exercises the experimental MintableSRC20 package on the Base Sepolia U2 World.
contract Stage7DU2MintableSRC20Script is Script {
    uint256 private constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    uint256 private constant RELEASE_START_BALANCE = 12_413_260_640_785_848_061;
    uint256 private constant RELEASE_ETH_CAP = 0.5 ether;

    address private constant ACTOR = 0x590a77Ec892bB78206bcad2444B62d1bC31A2D03;
    address private constant RECIPIENT = 0x000000000000000000000000000000000000bEEF;
    SwaputerAppRouter private constant ROUTER = SwaputerAppRouter(payable(0xEDAbF849F3F74FE3C92FCEa50968332f77B06F07));
    SwaputerToken private constant GAS_TOKEN = SwaputerToken(0xe7bE2F5Af5281D81394c1ed22a27EDe5fdbb8775);
    SwaputerKernel private constant KERNEL = SwaputerKernel(0xA048C894A738185c24B4A5020Fb6708dAb160283);
    bytes32 private constant WORLD_ID = 0x9c414214b34b78217698b02c5b1a7af65f6d43c500ed2bd865ea4c54ed4360b9;
    bytes32 private constant EXPECTED_CODE_HASH = 0x1a049200e47e150864788daeba7b106628283d0d6219ddf7be80f89ebb691b2e;

    uint128 private constant BUY_INPUT = 0.001 ether;
    uint32 private constant DEPLOY_BYTE_LIMIT = 100;
    uint32 private constant MINT_BYTE_LIMIT = 400;
    uint32 private constant TRANSFER_BYTE_LIMIT = 500;
    uint256 private constant MINT_AMOUNT = 1_000 ether;
    uint256 private constant TRANSFER_AMOUNT = 250 ether;
    uint256 private constant SUPPLY_CAP = 10_000_000 ether;

    function run() external {
        require(block.chainid == BASE_SEPOLIA_CHAIN_ID, "BASE_SEPOLIA_ONLY");
        uint256 actorKey = vm.envUint("STAGE7A2_PRIVATE_KEY");
        require(vm.addr(actorKey) == ACTOR, "ACTOR_MISMATCH");
        _enforceReleaseCap();

        bytes memory packageBytes = vm.readFileBinary("tooling/tinysol/programs/mintable-src20/MintableSRC20.svm");
        bytes32 codeHash = keccak256(packageBytes);
        require(codeHash == EXPECTED_CODE_HASH, "MINTABLE_SRC20_HASH");

        bytes32 actorId = KERNEL.eoaAccountId(ACTOR);
        bytes32 recipientId = KERNEL.eoaAccountId(RECIPIENT);
        uint64 creatorNonceBefore = KERNEL.creatorNonce(WORLD_ID, actorId);
        bytes32 contractId = KERNEL.contractAccountId(WORLD_ID, actorId, creatorNonceBefore, codeHash);
        uint64 actionNonceBefore = KERNEL.nonces(WORLD_ID, actorId);
        uint64 heightBefore = KERNEL.executionHeight(WORLD_ID);
        uint256 gasSupplyBefore = GAS_TOKEN.totalSupply();

        bytes memory deployPayload = abi.encodePacked(bytes4(uint32(packageBytes.length)), packageBytes);
        SwaputerKernel.VMEnvelope memory deployAction = _signedAction(
            actorKey, SwaputerKernel.RootOp.DEPLOY, codeHash, deployPayload, DEPLOY_BYTE_LIMIT, actionNonceBefore
        );
        vm.startBroadcast(actorKey);
        ROUTER.buyVMExactInput{value: BUY_INPUT}(WORLD_ID, TickMath.MIN_SQRT_PRICE + 1, deployAction);
        vm.stopBroadcast();

        require(KERNEL.creatorNonce(WORLD_ID, actorId) == creatorNonceBefore + 1, "CREATOR_NONCE");
        require(KERNEL.nonces(WORLD_ID, actorId) == actionNonceBefore + 1, "DEPLOY_ACTION_NONCE");
        require(KERNEL.executionHeight(WORLD_ID) == heightBefore + 1, "DEPLOY_HEIGHT");
        require(KERNEL.executedBytes(WORLD_ID) == 13, "DEPLOY_BYTES");
        require(_queryUint(contractId, "totalSupply()", bytes("")) == 0, "INITIAL_SUPPLY");

        bytes memory mintPayload = abi.encodePacked(bytes4(keccak256("mint(bytes32)")), abi.encode(actorId));
        SwaputerKernel.VMEnvelope memory mintAction = _signedAction(
            actorKey, SwaputerKernel.RootOp.CALL, contractId, mintPayload, MINT_BYTE_LIMIT, actionNonceBefore + 1
        );
        vm.startBroadcast(actorKey);
        ROUTER.buyVMExactInput{value: BUY_INPUT}(WORLD_ID, TickMath.MIN_SQRT_PRICE + 1, mintAction);
        vm.stopBroadcast();

        require(KERNEL.nonces(WORLD_ID, actorId) == actionNonceBefore + 2, "MINT_ACTION_NONCE");
        require(KERNEL.executionHeight(WORLD_ID) == heightBefore + 2, "MINT_HEIGHT");
        require(KERNEL.executedBytes(WORLD_ID) == 278, "MINT_BYTES");
        require(_queryUint(contractId, "totalSupply()", bytes("")) == MINT_AMOUNT, "MINT_SUPPLY");
        require(_balanceOf(contractId, actorId) == MINT_AMOUNT, "MINT_BALANCE");
        require(_balanceOf(contractId, recipientId) == 0, "RECIPIENT_PREBALANCE");

        bytes memory transferPayload =
            abi.encodePacked(bytes4(keccak256("transfer(bytes32,uint256)")), abi.encode(recipientId, TRANSFER_AMOUNT));
        SwaputerKernel.VMEnvelope memory transferAction = _signedAction(
            actorKey,
            SwaputerKernel.RootOp.CALL,
            contractId,
            transferPayload,
            TRANSFER_BYTE_LIMIT,
            actionNonceBefore + 2
        );
        vm.startBroadcast(actorKey);
        ROUTER.buyVMExactInput{value: BUY_INPUT}(WORLD_ID, TickMath.MIN_SQRT_PRICE + 1, transferAction);
        vm.stopBroadcast();

        uint256 actorBalance = _balanceOf(contractId, actorId);
        uint256 recipientBalance = _balanceOf(contractId, recipientId);
        uint256 totalSupply = _queryUint(contractId, "totalSupply()", bytes(""));
        require(KERNEL.nonces(WORLD_ID, actorId) == actionNonceBefore + 3, "TRANSFER_ACTION_NONCE");
        require(KERNEL.executionHeight(WORLD_ID) == heightBefore + 3, "TRANSFER_HEIGHT");
        require(KERNEL.executedBytes(WORLD_ID) == 396, "TRANSFER_BYTES");
        require(actorBalance == MINT_AMOUNT - TRANSFER_AMOUNT, "ACTOR_BALANCE");
        require(recipientBalance == TRANSFER_AMOUNT, "RECIPIENT_BALANCE");
        require(totalSupply == MINT_AMOUNT, "SUPPLY_CHANGED");
        require(_queryUint(contractId, "mintAmount()", bytes("")) == MINT_AMOUNT, "MINT_AMOUNT");
        require(_queryUint(contractId, "cap()", bytes("")) == SUPPLY_CAP, "SUPPLY_CAP");
        require(gasSupplyBefore - GAS_TOKEN.totalSupply() == 687 * uint256(KERNEL.byteGasPrice()), "BURN_TOTAL");
        _enforceReleaseCap();

        console2.log("STAGE7D_U2_MINTABLE_SRC20_CODE_HASH");
        console2.logBytes32(codeHash);
        console2.log("STAGE7D_U2_MINTABLE_SRC20_CONTRACT_ID");
        console2.logBytes32(contractId);
        console2.log("STAGE7D_U2_MINTABLE_SRC20_TOTAL_SUPPLY", totalSupply);
        console2.log("STAGE7D_U2_MINTABLE_SRC20_ACTOR_BALANCE", actorBalance);
        console2.log("STAGE7D_U2_MINTABLE_SRC20_RECIPIENT_BALANCE", recipientBalance);
        console2.log("STAGE7D_U2_MINTABLE_SRC20_HEIGHT", KERNEL.executionHeight(WORLD_ID));
        console2.log("STAGE7D_U2_MINTABLE_SRC20_UNAUDITED", true);
    }

    function _signedAction(
        uint256 actorKey,
        SwaputerKernel.RootOp op,
        bytes32 target,
        bytes memory payload,
        uint32 byteLimit,
        uint64 nonce
    ) private view returns (SwaputerKernel.VMEnvelope memory action) {
        action = SwaputerKernel.VMEnvelope({
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
            WORLD_ID, contractId, abi.encodePacked(bytes4(keccak256(bytes(signature))), arguments), 2_000
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
