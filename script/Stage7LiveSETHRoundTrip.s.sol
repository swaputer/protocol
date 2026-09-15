// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {SwaputerKernel} from "../src/SwaputerKernel.sol";
import {SwaputerAppRouter} from "../src/SwaputerAppRouter.sol";
import {SwapVMSETHVault} from "../src/SwapVMSETHVault.sol";

/// @notice Exercises the active Base Sepolia sETH vault without leaving a test liability behind.
contract Stage7LiveSETHRoundTripScript is Script {
    uint256 private constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    address private constant DEFAULT_ACTOR = 0x590a77Ec892bB78206bcad2444B62d1bC31A2D03;

    uint128 private constant VM_INPUT = 0.000001 ether;
    uint128 private constant BRIDGE_AMOUNT = 0.00001 ether;
    uint32 private constant SETH_LIMIT = 8_000;
    uint160 private constant SQRT_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint256 private constant MAX_NET_OUTFLOW = 0.01 ether;

    uint256 private actorKey;
    address private actor;
    uint256 private actorEthBefore;
    uint256 private actorSethBefore;
    uint256 private lockedBefore;
    uint256 private supplyBefore;
    uint256 private vaultBalanceBefore;
    uint256 private surplusBefore;
    SwaputerAppRouter private router;
    SwaputerKernel private kernel;
    SwapVMSETHVault private vault;
    bytes32 private worldId;
    bytes32 private actorId;
    bytes32 private seth;
    bytes32 private sethCodeHash;

    function run() external {
        _loadAndValidateEnvironment();
        _snapshotState();
        _deposit();
        _redeem();
        _validateRoundTrip();
        _logResult();
    }

    function _loadAndValidateEnvironment() private {
        require(block.chainid == BASE_SEPOLIA_CHAIN_ID, "BASE_SEPOLIA_ONLY");
        actorKey = vm.envUint("STAGE7A2_PRIVATE_KEY");
        actor = vm.envOr("STAGE7A2_ACTOR", DEFAULT_ACTOR);
        require(vm.addr(actorKey) == actor, "ACTOR_MISMATCH");

        router = SwaputerAppRouter(payable(vm.envAddress("SVM_ROUTER_ADDRESS")));
        kernel = SwaputerKernel(vm.envAddress("SVM_KERNEL_ADDRESS"));
        vault = SwapVMSETHVault(payable(vm.envAddress("SVM_SETH_VAULT_ADDRESS")));
        worldId = vm.envBytes32("SVM_WORLD_ID");
        seth = vm.envBytes32("SVM_SETH_PROGRAM_ID");
        sethCodeHash = vm.envBytes32("SVM_SETH_CODE_HASH");

        require(address(router).code.length != 0, "ROUTER_NOT_DEPLOYED");
        require(address(kernel).code.length != 0, "KERNEL_NOT_DEPLOYED");
        require(address(vault).code.length != 0, "VAULT_NOT_DEPLOYED");
        require(address(vault.router()) == address(router), "VAULT_ROUTER");
        require(address(vault.kernel()) == address(kernel), "VAULT_KERNEL");
        require(vault.worldId() == worldId, "VAULT_WORLD");
        require(vault.seth() == seth, "VAULT_SETH");
        require(vault.sethCodeHash() == sethCodeHash, "VAULT_CODE_HASH");
        require(kernel.programCodeHash(worldId, seth) == sethCodeHash, "PROGRAM_CODE_HASH");
        require(_queryAddress("vault()") == address(vault), "PROGRAM_VAULT");

        actorId = kernel.eoaAccountId(actor);
        actorEthBefore = actor.balance;
        require(actorEthBefore >= MAX_NET_OUTFLOW, "INSUFFICIENT_TEST_ETH");
    }

    function _snapshotState() private {
        actorSethBefore = _balanceOf(actorId);
        lockedBefore = vault.lockedEth();
        supplyBefore = vault.totalSupply();
        vaultBalanceBefore = address(vault).balance;
        surplusBefore = vault.backingSurplus();
        require(vault.isSolvent(), "INITIAL_INSOLVENCY");
        require(supplyBefore == lockedBefore, "INITIAL_SUPPLY");
        require(vaultBalanceBefore >= lockedBefore, "INITIAL_BACKING");
    }

    function _deposit() private {
        uint64 nonce = kernel.nonces(worldId, actorId);
        bytes memory payload =
            abi.encodePacked(bytes4(keccak256("bridgeMint(bytes32,uint256)")), abi.encode(actorId, BRIDGE_AMOUNT));
        SwaputerKernel.VMEnvelope memory envelope = _signedEnvelope(payload, actor, nonce);

        vm.startBroadcast(actorKey);
        vault.deposit{value: BRIDGE_AMOUNT + VM_INPUT}(BRIDGE_AMOUNT, VM_INPUT, envelope, SQRT_PRICE_LIMIT);
        vm.stopBroadcast();

        require(kernel.nonces(worldId, actorId) == nonce + 1, "DEPOSIT_NONCE");
        require(_balanceOf(actorId) == actorSethBefore + BRIDGE_AMOUNT, "DEPOSIT_BALANCE");
        require(vault.totalSupply() == supplyBefore + BRIDGE_AMOUNT, "DEPOSIT_SUPPLY");
        require(vault.lockedEth() == lockedBefore + BRIDGE_AMOUNT, "DEPOSIT_LIABILITY");
        require(address(vault).balance == vaultBalanceBefore + BRIDGE_AMOUNT, "DEPOSIT_BACKING");
        require(vault.backingSurplus() == surplusBefore, "DEPOSIT_SURPLUS");
        require(vault.isSolvent(), "DEPOSIT_INSOLVENCY");
    }

    function _redeem() private {
        uint64 nonce = kernel.nonces(worldId, actorId);
        bytes memory payload = abi.encodePacked(bytes4(keccak256("bridgeBurn(uint256)")), abi.encode(BRIDGE_AMOUNT));
        SwaputerKernel.VMEnvelope memory envelope = _signedEnvelope(payload, actor, nonce);

        vm.startBroadcast(actorKey);
        vault.redeem{value: VM_INPUT}(BRIDGE_AMOUNT, VM_INPUT, actor, envelope, SQRT_PRICE_LIMIT);
        vm.stopBroadcast();
        require(kernel.nonces(worldId, actorId) == nonce + 1, "REDEEM_NONCE");
    }

    function _signedEnvelope(bytes memory payload, address recipient, uint64 nonce)
        private
        view
        returns (SwaputerKernel.VMEnvelope memory envelope)
    {
        envelope = SwaputerKernel.VMEnvelope({
            op: SwaputerKernel.RootOp.CALL,
            worldId: worldId,
            actor: actor,
            targetOrCodeHash: seth,
            payload: payload,
            byteGasLimit: SETH_LIMIT,
            minNetTokenOut: 1,
            nonce: nonce,
            deadline: uint64(block.timestamp + 1 days),
            recipient: recipient,
            authorizedExecutor: address(vault),
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

    function _balanceOf(bytes32 owner) private view returns (uint256 amount) {
        (bytes memory output,) = kernel.staticCall(
            worldId, seth, abi.encodePacked(bytes4(keccak256("balanceOf(bytes32)")), abi.encode(owner)), 2_000
        );
        require(output.length == 32, "BALANCE_WIDTH");
        amount = abi.decode(output, (uint256));
    }

    function _queryAddress(string memory signature) private view returns (address value) {
        (bytes memory output,) =
            kernel.staticCall(worldId, seth, abi.encodePacked(bytes4(keccak256(bytes(signature)))), 2_000);
        require(output.length == 32, "ADDRESS_WIDTH");
        value = address(uint160(abi.decode(output, (uint256))));
    }

    function _validateRoundTrip() private view {
        require(_balanceOf(actorId) == actorSethBefore, "FINAL_ACTOR_BALANCE");
        require(vault.totalSupply() == supplyBefore, "FINAL_SUPPLY");
        require(vault.lockedEth() == lockedBefore, "FINAL_LIABILITY");
        require(address(vault).balance == vaultBalanceBefore, "FINAL_BACKING");
        require(vault.backingSurplus() == surplusBefore, "FINAL_SURPLUS");
        require(vault.isSolvent(), "FINAL_INSOLVENCY");
        if (actor.balance < actorEthBefore) {
            require(actorEthBefore - actor.balance <= MAX_NET_OUTFLOW, "OUTFLOW_CAP");
        }
    }

    function _logResult() private view {
        console2.log("LIVE_SETH_PROGRAM_ID");
        console2.logBytes32(seth);
        console2.log("LIVE_SETH_VAULT", address(vault));
        console2.log("LIVE_SETH_DEPOSIT_AMOUNT_WEI", BRIDGE_AMOUNT);
        console2.log("LIVE_SETH_LOCKED_BEFORE_WEI", lockedBefore);
        console2.log("LIVE_SETH_LOCKED_AFTER_WEI", vault.lockedEth());
        console2.log("LIVE_SETH_SUPPLY_BEFORE_WEI", supplyBefore);
        console2.log("LIVE_SETH_SUPPLY_AFTER_WEI", vault.totalSupply());
        console2.log("LIVE_SETH_FINAL_SOLVENT", vault.isSolvent());
    }
}
