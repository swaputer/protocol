// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {SwapVMKernel} from "../src/SwapVMKernel.sol";
import {SwapVMRouter} from "../src/SwapVMRouter.sol";
import {SwapVMSRC20Market} from "../src/SwapVMSRC20Market.sol";

/// @notice Exercises both sides of an already deployed local v1.2 escrow market.
/// @dev Local Anvil only. The script never reads repository wallet files.
contract LocalV12EscrowMarketExerciseScript is Script {
    uint128 private constant ORDER_AMOUNT = 1_000 ether;
    uint128 private constant UNIT_PRICE = 0.00001 ether;
    uint128 private constant ORDER_PRICE = 0.01 ether;
    uint128 private constant VM_INPUT = 0.25 ether;
    uint32 private constant TOKEN_LIMIT = 3_000;
    uint32 private constant ESCROW_LIMIT = 8_000;
    uint160 private constant SQRT_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;

    uint256 private sellerKey;
    uint256 private buyerKey;
    address private seller;
    address private buyer;
    SwapVMSRC20Market private market;
    SwapVMRouter private router;
    SwapVMKernel private kernel;
    bytes32 private worldId;
    bytes32 private token;
    bytes32 private escrow;

    function run() external {
        require(block.chainid == 31_337, "ANVIL_ONLY");
        sellerKey = vm.envUint("LOCAL_V12_PRIVATE_KEY");
        buyerKey = vm.envUint("LOCAL_V12_BUYER_PRIVATE_KEY");
        seller = vm.addr(sellerKey);
        buyer = vm.addr(buyerKey);
        market = SwapVMSRC20Market(payable(vm.envAddress("LOCAL_V12_MARKET_ADDRESS")));
        router = market.router();
        kernel = market.kernel();
        worldId = market.worldId();
        token = market.token();
        escrow = market.escrow();

        uint256 sellerStart = _balanceOf(seller);
        uint256 buyerStart = _balanceOf(buyer);

        _exerciseBuyOrder();
        require(_balanceOf(seller) == sellerStart - ORDER_AMOUNT, "BUY_SELLER_BALANCE");
        require(_balanceOf(buyer) == buyerStart + ORDER_AMOUNT, "BUY_BUYER_BALANCE");

        _approveEscrow(ORDER_AMOUNT);
        _exerciseSellOrder();
        require(_balanceOf(seller) == sellerStart - 2 * ORDER_AMOUNT, "SELL_SELLER_BALANCE");
        require(_balanceOf(buyer) == buyerStart + 2 * ORDER_AMOUNT, "SELL_BUYER_BALANCE");
        require(_balanceOfId(escrow) == 0, "ESCROW_BALANCE");
        require(market.lockedEth() == 0, "LOCKED_ETH");
        require(market.escrowedTokenAmount() == 0, "ESCROW_LIABILITY");
        require(address(market).balance == 0, "MARKET_RESIDUAL_ETH");

        console2.log("LOCAL_V12_MARKET_EXERCISE", "PASS");
        console2.log("BUY_ORDER_ID", uint256(1));
        console2.log("SELL_ORDER_ID", uint256(2));
        console2.log("SELLER_SRC20_FINAL", _balanceOf(seller));
        console2.log("BUYER_SRC20_FINAL", _balanceOf(buyer));
        console2.log("ESCROW_SRC20_FINAL", _balanceOfId(escrow));
        console2.log("MARKET_ETH_FINAL", address(market).balance);
    }

    function _exerciseBuyOrder() private {
        vm.startBroadcast(buyerKey);
        uint256 orderId = market.createBuyOrder{value: ORDER_PRICE + VM_INPUT}(
            ORDER_AMOUNT, UNIT_PRICE, VM_INPUT, uint64(block.timestamp + 1 days)
        );
        vm.stopBroadcast();
        require(orderId == 1, "BUY_ORDER_ID");

        SwapVMKernel.VMEnvelope memory transfer = _signedEnvelope(
            sellerKey,
            seller,
            token,
            abi.encodePacked(
                bytes4(keccak256("transfer(bytes32,uint256)")), abi.encode(kernel.eoaAccountId(buyer), ORDER_AMOUNT)
            ),
            TOKEN_LIMIT,
            buyer,
            address(market),
            VM_INPUT
        );
        vm.startBroadcast(sellerKey);
        market.fillBuyOrder(orderId, transfer, SQRT_PRICE_LIMIT);
        vm.stopBroadcast();
        require(uint8(market.getOrder(orderId).status) == uint8(SwapVMSRC20Market.Status.Filled), "BUY_STATUS");
    }

    function _approveEscrow(uint256 amount) private {
        SwapVMKernel.VMEnvelope memory approval = _signedEnvelope(
            sellerKey,
            seller,
            token,
            abi.encodePacked(bytes4(keccak256("approve(bytes32,uint256)")), abi.encode(escrow, amount)),
            TOKEN_LIMIT,
            seller,
            seller,
            VM_INPUT
        );
        vm.startBroadcast(sellerKey);
        router.buyVMExactInput{value: VM_INPUT}(worldId, SQRT_PRICE_LIMIT, approval);
        vm.stopBroadcast();
    }

    function _exerciseSellOrder() private {
        SwapVMKernel.VMEnvelope memory deposit = _signedEnvelope(
            sellerKey,
            seller,
            escrow,
            abi.encodePacked(
                bytes4(keccak256("deposit(bytes32,uint256)")), abi.encode(kernel.eoaAccountId(seller), ORDER_AMOUNT)
            ),
            ESCROW_LIMIT,
            seller,
            address(market),
            VM_INPUT
        );
        vm.startBroadcast(sellerKey);
        uint256 orderId = market.createSellOrder{value: VM_INPUT}(
            ORDER_AMOUNT, UNIT_PRICE, VM_INPUT, uint64(block.timestamp + 1 days), deposit, SQRT_PRICE_LIMIT
        );
        vm.stopBroadcast();
        require(orderId == 2, "SELL_ORDER_ID");
        require(_balanceOfId(escrow) == ORDER_AMOUNT, "SELL_NOT_ESCROWED");

        SwapVMKernel.VMEnvelope memory release = _signedEnvelope(
            buyerKey,
            buyer,
            escrow,
            abi.encodePacked(
                bytes4(keccak256("release(bytes32,uint256)")), abi.encode(kernel.eoaAccountId(buyer), ORDER_AMOUNT)
            ),
            ESCROW_LIMIT,
            buyer,
            address(market),
            VM_INPUT
        );
        vm.startBroadcast(buyerKey);
        market.settleSellOrder{value: ORDER_PRICE + VM_INPUT}(orderId, release, SQRT_PRICE_LIMIT);
        vm.stopBroadcast();
        require(uint8(market.getOrder(orderId).status) == uint8(SwapVMSRC20Market.Status.Filled), "SELL_STATUS");
    }

    function _signedEnvelope(
        uint256 key,
        address actor,
        bytes32 target,
        bytes memory payload,
        uint32 byteGasLimit,
        address recipient,
        address executor,
        uint128 ethIn
    ) private view returns (SwapVMKernel.VMEnvelope memory envelope) {
        bytes32 actorId = kernel.eoaAccountId(actor);
        envelope = SwapVMKernel.VMEnvelope({
            op: SwapVMKernel.RootOp.CALL,
            worldId: worldId,
            actor: actor,
            targetOrCodeHash: target,
            payload: payload,
            byteGasLimit: byteGasLimit,
            minNetTokenOut: 1,
            nonce: kernel.nonces(worldId, actorId),
            deadline: uint64(block.timestamp + 1 days),
            recipient: recipient,
            authorizedExecutor: executor,
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
                ethIn,
                SQRT_PRICE_LIMIT,
                envelope.recipient,
                address(router),
                envelope.authorizedExecutor,
                envelope.nonce,
                envelope.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", kernel.domainSeparator(worldId), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        envelope.signature = abi.encodePacked(r, s, v);
    }

    function _balanceOf(address account) private view returns (uint256) {
        return _balanceOfId(kernel.eoaAccountId(account));
    }

    function _balanceOfId(bytes32 account) private view returns (uint256 value) {
        bytes memory payload = abi.encodePacked(bytes4(keccak256("balanceOf(bytes32)")), abi.encode(account));
        (bytes memory output,) = kernel.staticCall(worldId, token, payload, 2_000);
        require(output.length == 32, "BALANCE_OUTPUT");
        value = abi.decode(output, (uint256));
    }
}
