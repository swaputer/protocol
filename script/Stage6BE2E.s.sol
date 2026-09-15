// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {SwaputerKernel} from "../src/SwaputerKernel.sol";

/// @dev Minimal bound-hook stand-in. It exercises the real Kernel receipt path without implementing a second AMM.
contract Stage6BKernelDriver {
    uint128 internal constant BYTE_GAS_PRICE = 1e12;
    uint128 internal constant GROSS_TOKEN_OUT = 1e30;
    uint128 internal constant ETH_AMOUNT_IN = 1 ether;
    uint160 internal constant PRICE_LIMIT = 1;

    address public immutable owner;
    SwaputerKernel public kernel;

    error OnlyOwner();
    error AlreadyBound();
    error InvalidKernel();

    constructor(address initialOwner) {
        owner = initialOwner;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    function bind(SwaputerKernel target) external onlyOwner {
        if (address(kernel) != address(0)) revert AlreadyBound();
        if (target.hook() != address(this)) revert InvalidKernel();
        kernel = target;
    }

    function executeNOP(bytes32 worldId) external onlyOwner {
        SwaputerKernel target = kernel;
        target.executeNOP(
            SwaputerKernel.BuyReceipt({
                worldId: worldId,
                executionHeight: target.executionHeight(worldId) + 1,
                actor: bytes32(0),
                ethAmountIn: ETH_AMOUNT_IN,
                grossTokenOut: GROSS_TOKEN_OUT,
                tokenGasBurned: BYTE_GAS_PRICE,
                tickAfter: 0,
                liquidityAfter: 0,
                chainBlockNumber: uint64(block.number),
                chainTimestamp: uint64(block.timestamp)
            })
        );
    }

    function execute(SwaputerKernel.VMEnvelope calldata action) external onlyOwner {
        SwaputerKernel target = kernel;
        target.executeCall(
            SwaputerKernel.BuyReceipt({
                worldId: action.worldId,
                executionHeight: target.executionHeight(action.worldId) + 1,
                actor: bytes32(0),
                ethAmountIn: ETH_AMOUNT_IN,
                grossTokenOut: GROSS_TOKEN_OUT,
                tokenGasBurned: 0,
                tickAfter: 0,
                liquidityAfter: 0,
                chainBlockNumber: uint64(block.number),
                chainTimestamp: uint64(block.timestamp)
            }),
            action,
            SwaputerKernel.ActionBinding({sqrtPriceLimitX96: PRICE_LIMIT, router: address(this)})
        );
    }
}

/// @notice Deterministic Stage 6B local-Anvil setup and receipt producer. Never use on a public network.
contract Stage6BE2EScript is Script {
    using stdJson for string;

    uint128 private constant BYTE_GAS_PRICE = 1e12;
    uint32 private constant ACTION_LIMIT = 5_000;
    uint128 private constant ETH_AMOUNT_IN = 1 ether;
    uint160 private constant PRICE_LIMIT = 1;
    uint256 private constant FEE_DENOMINATOR = 1_000_000;
    bytes32 private constant WORLD_ID = keccak256("SwapVM Stage6B ephemeral Anvil World");
    bytes private constant STATE_PROGRAM = hex"36601457602a60015560015460005260206000f35b60015460005260206000f3";

    uint256 private actorKey;
    address private actor;
    Stage6BKernelDriver private driver;
    SwaputerKernel private kernel;

    function setup() external {
        actorKey = vm.envUint("STAGE6B_PRIVATE_KEY");
        actor = vm.addr(actorKey);
        vm.startBroadcast(actorKey);
        driver = new Stage6BKernelDriver(actor);
        kernel = new SwaputerKernel(address(driver), BYTE_GAS_PRICE);
        driver.bind(kernel);
        vm.stopBroadcast();
        console2.log("STAGE6B_DRIVER", address(driver));
        console2.log("STAGE6B_KERNEL", address(kernel));
        console2.logBytes32(WORLD_ID);
    }

    function branchA() external {
        _load();
        bytes memory src20Package = _referencePackage("SRC20-v1");
        bytes memory cpammPackage = _referencePackage("CPAMM-v1");
        bytes32 actorId = kernel.eoaAccountId(actor);
        bytes32 recipientId = kernel.eoaAccountId(address(0xbeef));

        vm.startBroadcast(actorKey);
        driver.executeNOP(WORLD_ID);
        bytes32 state = _deploy(_package(0, 0, keccak256("Stage6B.State"), STATE_PROGRAM), bytes(""));
        _call(state, bytes(""));
        bytes32 src20 = _deploy(
            src20Package, abi.encode(bytes32("Stage6B Token"), bytes32("S6B"), uint256(18), uint256(1_000), actorId)
        );
        _call(src20, abi.encodePacked(bytes4(keccak256("transfer(bytes32,uint256)")), abi.encode(recipientId, 125)));

        bytes32 token0 = _deploy(
            src20Package, abi.encode(bytes32("Token Zero"), bytes32("TK0"), uint256(18), uint256(2_000_000), actorId)
        );
        bytes32 token1 = _deploy(
            src20Package, abi.encode(bytes32("Token One"), bytes32("TK1"), uint256(18), uint256(4_000_000), actorId)
        );
        bytes32 amm = _deploy(cpammPackage, bytes(""));
        _call(
            amm,
            abi.encodePacked(
                bytes4(keccak256("createPair(bytes32,bytes32,uint256)")), abi.encode(token0, token1, uint256(3000))
            )
        );
        _call(
            token0, abi.encodePacked(bytes4(keccak256("approve(bytes32,uint256)")), abi.encode(amm, type(uint128).max))
        );
        _call(
            token1, abi.encodePacked(bytes4(keccak256("approve(bytes32,uint256)")), abi.encode(amm, type(uint128).max))
        );
        _call(
            amm,
            abi.encodePacked(
                bytes4(keccak256("addLiquidity(uint256,uint256,uint256)")),
                abi.encode(uint256(100_000), uint256(200_000), uint256(100_000))
            )
        );
        uint256 adjusted = uint256(10_000) * 997_000 / FEE_DENOMINATOR;
        uint256 expectedOut = uint256(200_000) * adjusted / (100_000 + adjusted);
        _call(
            amm,
            abi.encodePacked(
                bytes4(keccak256("swapExactIn(bytes32,uint256,uint256)")),
                abi.encode(token0, uint256(10_000), expectedOut)
            )
        );
        vm.stopBroadcast();
    }

    function branchB() external {
        _load();
        vm.startBroadcast(actorKey);
        for (uint256 i; i < 13; ++i) {
            driver.executeNOP(WORLD_ID);
        }
        vm.stopBroadcast();
    }

    function _load() private {
        actorKey = vm.envUint("STAGE6B_PRIVATE_KEY");
        actor = vm.addr(actorKey);
        driver = Stage6BKernelDriver(vm.envAddress("STAGE6B_DRIVER"));
        kernel = SwaputerKernel(vm.envAddress("STAGE6B_KERNEL"));
    }

    function _deploy(bytes memory packageBytes, bytes memory constructorInput) private returns (bytes32 contractId) {
        bytes32 actorId = kernel.eoaAccountId(actor);
        bytes32 codeHash = keccak256(packageBytes);
        contractId = kernel.contractAccountId(WORLD_ID, actorId, kernel.creatorNonce(WORLD_ID, actorId), codeHash);
        bytes memory payload = abi.encodePacked(bytes4(uint32(packageBytes.length)), packageBytes, constructorInput);
        driver.execute(_signed(SwaputerKernel.RootOp.DEPLOY, codeHash, payload));
    }

    function _call(bytes32 target, bytes memory payload) private {
        driver.execute(_signed(SwaputerKernel.RootOp.CALL, target, payload));
    }

    function _signed(SwaputerKernel.RootOp op, bytes32 target, bytes memory payload)
        private
        view
        returns (SwaputerKernel.VMEnvelope memory action)
    {
        bytes32 actorId = kernel.eoaAccountId(actor);
        action = SwaputerKernel.VMEnvelope({
            op: op,
            worldId: WORLD_ID,
            actor: actor,
            targetOrCodeHash: target,
            payload: payload,
            byteGasLimit: ACTION_LIMIT,
            minNetTokenOut: 0,
            nonce: kernel.nonces(WORLD_ID, actorId),
            deadline: uint64(block.timestamp + 1 days),
            recipient: actor,
            authorizedExecutor: actor,
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
                ETH_AMOUNT_IN,
                PRICE_LIMIT,
                action.recipient,
                address(driver),
                action.authorizedExecutor,
                action.nonce,
                action.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", kernel.domainSeparator(WORLD_ID), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(actorKey, digest);
        action.signature = abi.encodePacked(r, s, v);
    }

    function _package(uint16 constructorEntry, uint16 runtimeEntry, bytes32 abiHash, bytes memory code)
        private
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(
            bytes4(0x53564d31),
            bytes2(uint16(1)),
            bytes2(constructorEntry),
            bytes2(runtimeEntry),
            bytes2(uint16(code.length)),
            abiHash,
            code
        );
    }

    function _referencePackage(string memory name) private view returns (bytes memory) {
        return vm.readFile(string.concat("reference/", name, ".json")).readBytes(".package");
    }
}
