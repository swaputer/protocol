// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {SwaputerToken} from "../src/SwaputerToken.sol";
import {SwaputerHook} from "../src/SwaputerHook.sol";
import {SwaputerKernel} from "../src/SwaputerKernel.sol";
import {SwaputerProgramRegistry} from "../src/SwaputerProgramRegistry.sol";
import {SwapVMKernelStage2Harness, SwapVMStage2Router} from "./SwapVMStage2.t.sol";
import {ReceiptFixture} from "./utils/ReceiptFixture.sol";

contract SwapVMStage4Test is Test {
    using stdJson for string;
    using TransientStateLibrary for IPoolManager;

    uint256 private constant INITIAL_SUPPLY = 1e36;
    uint128 private constant BYTE_GAS_PRICE = 1e12;
    uint24 private constant POOL_FEE = 3000;
    int24 private constant TICK_SPACING = 60;
    uint256 private constant ACTOR_KEY = 0xA11CE;
    uint256 private constant OPERATOR_KEY = 0xB0B;
    uint32 private constant ACTION_LIMIT = 5_000;
    bytes32 private constant EVENTS_TOPIC = keccak256("Events(bytes32,uint64,bytes)");
    bytes32 private constant TRANSFER_TOPIC = keccak256("Transfer(bytes32,bytes32,uint256)");
    bytes32 private constant APPROVAL_TOPIC = keccak256("Approval(bytes32,bytes32,uint256)");
    bytes32 private constant APPROVAL_FOR_ALL_TOPIC = keccak256("ApprovalForAll(bytes32,bytes32,bool)");
    bytes32 private constant TRANSFER_SINGLE_TOPIC =
        keccak256("TransferSingle(bytes32,bytes32,bytes32,uint256,uint256)");

    PoolManager private manager;
    SwaputerToken private token;
    SwapVMKernelStage2Harness private kernel;
    SwaputerHook private hook;
    SwapVMStage2Router private router;
    PoolKey private key;
    bytes32 private worldId;
    address private actor;
    address private operator;

    function setUp() public {
        actor = vm.addr(ACTOR_KEY);
        operator = vm.addr(OPERATOR_KEY);
        vm.deal(address(this), 1e30);
        vm.deal(actor, 100 ether);
        vm.deal(operator, 100 ether);

        manager = new PoolManager(address(this));
        token = new SwaputerToken(INITIAL_SUPPLY, address(this));
        PoolModifyLiquidityTest liquidityRouter = new PoolModifyLiquidityTest(manager);
        router = new SwapVMStage2Router(manager);

        uint64 nextNonce = vm.getNonce(address(this));
        address predictedKernel = vm.computeCreateAddress(address(this), nextNonce);
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        bytes memory args = abi.encode(
            manager,
            SwaputerKernel(predictedKernel),
            token,
            address(this),
            address(this),
            uint16(0),
            BYTE_GAS_PRICE,
            POOL_FEE,
            TICK_SPACING
        );
        (address expectedHook, bytes32 salt) =
            HookMiner.find(address(this), flags, type(SwaputerHook).creationCode, args);
        kernel = new SwapVMKernelStage2Harness(expectedHook, BYTE_GAS_PRICE);
        hook = new SwaputerHook{salt: salt}(
            manager, kernel, token, address(this), address(this), 0, BYTE_GAS_PRICE, POOL_FEE, TICK_SPACING
        );

        key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        worldId = PoolId.unwrap(key.toId());
        manager.initialize(key, 1 << 96);
        token.approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity{value: 1e25}(
            key,
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e24, salt: bytes32(0)}),
            bytes("")
        );
        hook.live();
    }

    function test_referenceRegistryPinsExactPackagesAndRejectsMutation() public {
        SwaputerProgramRegistry registry = new SwaputerProgramRegistry();
        bytes memory src20 = _package("SRC20-v1");
        bytes memory src721 = _package("SRC721-v1");
        bytes memory src1155 = _package("SRC1155-v1");

        assertTrue(registry.verifyPackage(registry.SRC20_INTERFACE_ID(), src20));
        assertTrue(registry.verifyPackage(registry.SRC721_INTERFACE_ID(), src721));
        assertTrue(registry.verifyPackage(registry.SRC1155_INTERFACE_ID(), src1155));
        assertEq(keccak256(src20), registry.SRC20_CODE_HASH());
        assertEq(keccak256(src721), registry.SRC721_CODE_HASH());
        assertEq(keccak256(src1155), registry.SRC1155_CODE_HASH());

        src20[src20.length - 1] = bytes1(uint8(src20[src20.length - 1]) ^ 1);
        assertFalse(registry.verifyPackage(registry.SRC20_INTERFACE_ID(), src20));
        assertFalse(registry.isVerified(registry.SRC20_INTERFACE_ID(), registry.SRC721_ABI_HASH(), keccak256(src20)));
    }

    function test_stage6A_fixture_nestedSrc20Transfer() public {
        bytes32 actorId = kernel.eoaAccountId(actor);
        bytes32 operatorId = kernel.eoaAccountId(operator);
        bytes32 contractId = _deploy(
            ACTOR_KEY,
            _package("SRC20-v1"),
            abi.encode(bytes32("Fixture Token"), bytes32("FIX20"), uint256(18), uint256(1_000), actorId),
            0
        );
        vm.recordLogs();
        _call(ACTOR_KEY, contractId, "transfer(bytes32,uint256)", abi.encode(operatorId, uint256(125)), 1);
        ReceiptFixture.assertOrWrite(vm, "src20-transfer", address(kernel), vm.getRecordedLogs());
    }

    function test_stage6A_fixture_src721Transfer() public {
        bytes32 actorId = kernel.eoaAccountId(actor);
        bytes32 operatorId = kernel.eoaAccountId(operator);
        bytes32 contractId = _deploy(
            ACTOR_KEY,
            _package("SRC721-v1"),
            abi.encode(bytes32("Fixture NFT"), bytes32("FIX721"), uint256(7), actorId, keccak256("fixture-uri")),
            0
        );
        vm.recordLogs();
        _call(
            ACTOR_KEY,
            contractId,
            "transferFrom(bytes32,bytes32,uint256)",
            abi.encode(actorId, operatorId, uint256(7)),
            1
        );
        ReceiptFixture.assertOrWrite(vm, "src721-transfer", address(kernel), vm.getRecordedLogs());
    }

    function test_src20ConformanceAuthorizationLogsAndRollback() public {
        SwaputerProgramRegistry registry = new SwaputerProgramRegistry();
        bytes memory packageBytes = _package("SRC20-v1");
        bytes32 actorId = kernel.eoaAccountId(actor);
        bytes32 operatorId = kernel.eoaAccountId(operator);
        bytes32 name = bytes32("SwapVM Reference");
        bytes32 symbol = bytes32("SRC20");

        vm.recordLogs();
        bytes32 contractId =
            _deploy(ACTOR_KEY, packageBytes, abi.encode(name, symbol, uint256(18), uint256(1_000), actorId), 0);
        _assertConstructorReceipt(vm.getRecordedLogs(), contractId, TRANSFER_TOPIC, 3);

        assertEq(
            _queryWord(contractId, "supportsInterface(bytes4)", abi.encode(registry.SRC165_INTERFACE_ID())),
            bytes32(uint256(1))
        );
        assertEq(
            _queryWord(contractId, "supportsInterface(bytes4)", abi.encode(registry.SRC20_INTERFACE_ID())),
            bytes32(uint256(1))
        );
        assertEq(_queryWord(contractId, "name()", bytes("")), name);
        assertEq(_queryWord(contractId, "symbol()", bytes("")), symbol);
        assertEq(uint256(_queryWord(contractId, "decimals()", bytes(""))), 18);
        assertEq(uint256(_queryWord(contractId, "totalSupply()", bytes(""))), 1_000);
        assertEq(_balance20(contractId, actorId), 1_000);

        vm.recordLogs();
        _call(ACTOR_KEY, contractId, "transfer(bytes32,uint256)", abi.encode(operatorId, uint256(125)), 1);
        _assertApplicationReceipt(vm.getRecordedLogs(), contractId, TRANSFER_TOPIC, actorId, operatorId, 125);
        assertEq(_balance20(contractId, actorId), 875);
        assertEq(_balance20(contractId, operatorId), 125);

        vm.recordLogs();
        _call(ACTOR_KEY, contractId, "approve(bytes32,uint256)", abi.encode(operatorId, uint256(200)), 2);
        _assertApplicationReceipt(vm.getRecordedLogs(), contractId, APPROVAL_TOPIC, actorId, operatorId, 200);
        assertEq(_allowance20(contractId, actorId, operatorId), 200);

        _call(
            OPERATOR_KEY,
            contractId,
            "transferFrom(bytes32,bytes32,uint256)",
            abi.encode(actorId, contractId, uint256(75)),
            0
        );
        assertEq(_balance20(contractId, actorId), 800);
        assertEq(_balance20(contractId, contractId), 75);
        assertEq(_allowance20(contractId, actorId, operatorId), 125);

        uint64 heightBefore = kernel.executionHeight(worldId);
        uint64 nonceBefore = kernel.nonces(worldId, operatorId);
        uint256 supplyBefore = token.totalSupply();
        vm.recordLogs();
        _callReverts(
            OPERATOR_KEY,
            contractId,
            "transferFrom(bytes32,bytes32,uint256)",
            abi.encode(actorId, operatorId, uint256(10_000)),
            1
        );
        assertEq(_countEvents(vm.getRecordedLogs()), 0);
        assertEq(kernel.executionHeight(worldId), heightBefore);
        assertEq(kernel.nonces(worldId, operatorId), nonceBefore);
        assertEq(token.totalSupply(), supplyBefore);
        assertEq(_balance20(contractId, actorId), 800);

        vm.prank(actor);
        vm.expectRevert();
        kernel.staticCall(
            worldId,
            contractId,
            abi.encodePacked(bytes4(keccak256("transfer(bytes32,uint256)")), abi.encode(operatorId, uint256(1))),
            ACTION_LIMIT
        );
        _assertSettled();
    }

    function testFuzz_src20TransfersConserveSupply(uint16 rawAmount) public {
        uint256 amount = bound(uint256(rawAmount), 0, 1_000);
        bytes32 actorId = kernel.eoaAccountId(actor);
        bytes32 operatorId = kernel.eoaAccountId(operator);
        bytes32 contractId = _deploy(
            ACTOR_KEY,
            _package("SRC20-v1"),
            abi.encode(bytes32("Fuzz"), bytes32("F20"), uint256(18), uint256(1_000), actorId),
            0
        );
        _call(ACTOR_KEY, contractId, "transfer(bytes32,uint256)", abi.encode(operatorId, amount), 1);
        assertEq(_balance20(contractId, actorId) + _balance20(contractId, operatorId), 1_000);
        assertEq(uint256(_queryWord(contractId, "totalSupply()", bytes(""))), 1_000);
    }

    function test_src721ConformanceApprovalContractOwnershipAndLogs() public {
        SwaputerProgramRegistry registry = new SwaputerProgramRegistry();
        bytes32 actorId = kernel.eoaAccountId(actor);
        bytes32 operatorId = kernel.eoaAccountId(operator);
        uint256 tokenId = 7;
        bytes32 uriHash = keccak256("ipfs://swapvm/src721/7");
        vm.recordLogs();
        bytes32 contractId = _deploy(
            ACTOR_KEY,
            _package("SRC721-v1"),
            abi.encode(bytes32("Reference NFT"), bytes32("S721"), tokenId, actorId, uriHash),
            0
        );
        _assertConstructorReceipt(vm.getRecordedLogs(), contractId, TRANSFER_TOPIC, 3);
        assertEq(
            _queryWord(contractId, "supportsInterface(bytes4)", abi.encode(registry.SRC721_INTERFACE_ID())),
            bytes32(uint256(1))
        );
        assertEq(_queryWord(contractId, "ownerOf(uint256)", abi.encode(tokenId)), actorId);
        assertEq(uint256(_queryWord(contractId, "balanceOf(bytes32)", abi.encode(actorId))), 1);
        assertEq(_queryWord(contractId, "tokenURI(uint256)", abi.encode(tokenId)), uriHash);

        vm.recordLogs();
        _call(ACTOR_KEY, contractId, "approve(bytes32,uint256)", abi.encode(operatorId, tokenId), 1);
        _assertApplicationReceipt(vm.getRecordedLogs(), contractId, APPROVAL_TOPIC, actorId, operatorId, tokenId);
        vm.recordLogs();
        _call(
            OPERATOR_KEY,
            contractId,
            "transferFrom(bytes32,bytes32,uint256)",
            abi.encode(actorId, contractId, tokenId),
            0
        );
        _assertApplicationReceipt(vm.getRecordedLogs(), contractId, TRANSFER_TOPIC, actorId, contractId, tokenId);
        assertEq(_queryWord(contractId, "ownerOf(uint256)", abi.encode(tokenId)), contractId);
        assertEq(uint256(_queryWord(contractId, "balanceOf(bytes32)", abi.encode(actorId))), 0);
        assertEq(uint256(_queryWord(contractId, "balanceOf(bytes32)", abi.encode(contractId))), 1);
        _assertSettled();
    }

    function test_src1155ConformanceOperatorTransferContractOwnershipAndLogs() public {
        SwaputerProgramRegistry registry = new SwaputerProgramRegistry();
        bytes32 actorId = kernel.eoaAccountId(actor);
        bytes32 operatorId = kernel.eoaAccountId(operator);
        uint256 id = 9;
        bytes32 uriHash = keccak256("ipfs://swapvm/src1155/{id}");
        vm.recordLogs();
        bytes32 contractId =
            _deploy(ACTOR_KEY, _package("SRC1155-v1"), abi.encode(uriHash, id, uint256(500), actorId), 0);
        _assertConstructorReceipt(vm.getRecordedLogs(), contractId, TRANSFER_SINGLE_TOPIC, 3);
        assertEq(
            _queryWord(contractId, "supportsInterface(bytes4)", abi.encode(registry.SRC1155_INTERFACE_ID())),
            bytes32(uint256(1))
        );
        assertEq(_balance1155(contractId, actorId, id), 500);
        assertEq(_queryWord(contractId, "uri(uint256)", abi.encode(id)), uriHash);

        vm.recordLogs();
        _call(ACTOR_KEY, contractId, "setApprovalForAll(bytes32,bool)", abi.encode(operatorId, true), 1);
        _assertApplicationReceipt(vm.getRecordedLogs(), contractId, APPROVAL_FOR_ALL_TOPIC, actorId, operatorId, 1);
        assertEq(
            uint256(_queryWord(contractId, "isApprovedForAll(bytes32,bytes32)", abi.encode(actorId, operatorId))), 1
        );

        vm.recordLogs();
        _call(
            OPERATOR_KEY,
            contractId,
            "safeTransferFrom(bytes32,bytes32,uint256,uint256)",
            abi.encode(actorId, contractId, id, uint256(125)),
            0
        );
        bytes memory payload = _eventPayload(vm.getRecordedLogs());
        assertEq(uint8(payload[3]), 2);
        assertEq(_word(payload, 8), contractId);
        assertEq(_word(payload, 41), TRANSFER_SINGLE_TOPIC);
        assertEq(_word(payload, 73), operatorId);
        assertEq(_word(payload, 105), actorId);
        assertEq(_word(payload, 137), contractId);
        assertEq(_balance1155(contractId, actorId, id), 375);
        assertEq(_balance1155(contractId, contractId, id), 125);
        _assertSettled();
    }

    function test_nestedVirtualLogsPreserveExecutionOrderAndEmitter() public {
        bytes32 child = 0x0100000000000000000000000000000000000000000000000000000000004101;
        bytes32 parent = 0x0100000000000000000000000000000000000000000000000000000000004102;
        bytes32 childTopic = keccak256("Stage4.Child");
        bytes32 parentTopic = keccak256("Stage4.Parent");
        kernel.install(worldId, child, abi.encodePacked(hex"5f5f", bytes1(0x7f), childTopic, hex"a100"));
        kernel.install(
            worldId,
            parent,
            abi.encodePacked(bytes1(0x7f), child, hex"5f5f5f5ff1505f5f", bytes1(0x7f), parentTopic, hex"a100")
        );

        vm.recordLogs();
        _call(ACTOR_KEY, parent, "ignored()", bytes(""), 0);
        bytes memory payload = _eventPayload(vm.getRecordedLogs());
        assertEq(uint8(payload[3]), 3);
        assertEq(_word(payload, 8), child);
        assertEq(_word(payload, 41), childTopic);
        assertEq(_word(payload, 81), parent);
        assertEq(_word(payload, 114), parentTopic);
    }

    function test_virtualLogDataRecordAndPayloadBoundsRollback() public {
        bytes32 actorId = kernel.eoaAccountId(actor);
        bytes32 oversizedData = 0x0100000000000000000000000000000000000000000000000000000000004201;
        kernel.install(worldId, oversizedData, hex"6110015fa000");
        _assertLogProgramReverts(oversizedData, 0, actorId);

        bytes32 tooMany = 0x0100000000000000000000000000000000000000000000000000000000004202;
        bytes memory manyCode;
        for (uint256 i; i < 64; ++i) {
            manyCode = bytes.concat(manyCode, hex"5f5fa0");
        }
        manyCode = bytes.concat(manyCode, hex"00");
        kernel.install(worldId, tooMany, manyCode);
        _assertLogProgramReverts(tooMany, 0, actorId);

        bytes32 oversizedPayload = 0x0100000000000000000000000000000000000000000000000000000000004203;
        bytes memory payloadCode;
        for (uint256 i; i < 16; ++i) {
            payloadCode = bytes.concat(payloadCode, hex"6110005fa0");
        }
        payloadCode = bytes.concat(payloadCode, hex"00");
        kernel.install(worldId, oversizedPayload, payloadCode);
        _assertLogProgramReverts(oversizedPayload, 0, actorId);

        vm.prank(actor);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("StaticViolation(uint8)")), uint8(0xa0)));
        kernel.staticCall(worldId, oversizedData, bytes(""), ACTION_LIMIT);
    }

    function _deploy(uint256 privateKey, bytes memory packageBytes, bytes memory constructorInput, uint64 nonce)
        private
        returns (bytes32 contractId)
    {
        address signer = vm.addr(privateKey);
        bytes32 actorId = kernel.eoaAccountId(signer);
        bytes32 codeHash = keccak256(packageBytes);
        contractId = kernel.contractAccountId(worldId, actorId, kernel.creatorNonce(worldId, actorId), codeHash);
        bytes memory payload = abi.encodePacked(bytes4(uint32(packageBytes.length)), packageBytes, constructorInput);
        SwaputerKernel.VMEnvelope memory action =
            _signedAction(SwaputerKernel.RootOp.DEPLOY, privateKey, codeHash, payload, nonce, signer);
        vm.prank(signer);
        router.swap{value: 1 ether}(key, _buyParams(), signer, abi.encode(action));
    }

    function _callReverts(
        uint256 privateKey,
        bytes32 target,
        string memory signature,
        bytes memory arguments,
        uint64 nonce
    ) private {
        address signer = vm.addr(privateKey);
        bytes memory payload = abi.encodePacked(bytes4(keccak256(bytes(signature))), arguments);
        SwaputerKernel.VMEnvelope memory action =
            _signedAction(SwaputerKernel.RootOp.CALL, privateKey, target, payload, nonce, signer);
        vm.prank(signer);
        vm.expectRevert();
        router.swap{value: 1 ether}(key, _buyParams(), signer, abi.encode(action));
    }

    function _assertLogProgramReverts(bytes32 target, uint64 nonce, bytes32 actorId) private {
        uint64 heightBefore = kernel.executionHeight(worldId);
        uint256 supplyBefore = token.totalSupply();
        vm.recordLogs();
        _callReverts(ACTOR_KEY, target, "ignored()", bytes(""), nonce);
        assertEq(_countEvents(vm.getRecordedLogs()), 0);
        assertEq(kernel.executionHeight(worldId), heightBefore);
        assertEq(kernel.nonces(worldId, actorId), nonce);
        assertEq(token.totalSupply(), supplyBefore);
    }

    function _call(uint256 privateKey, bytes32 target, string memory signature, bytes memory arguments, uint64 nonce)
        private
    {
        address signer = vm.addr(privateKey);
        bytes memory payload = abi.encodePacked(bytes4(keccak256(bytes(signature))), arguments);
        SwaputerKernel.VMEnvelope memory action =
            _signedAction(SwaputerKernel.RootOp.CALL, privateKey, target, payload, nonce, signer);
        vm.prank(signer);
        router.swap{value: 1 ether}(key, _buyParams(), signer, abi.encode(action));
    }

    function _signedAction(
        SwaputerKernel.RootOp op,
        uint256 privateKey,
        bytes32 target,
        bytes memory payload,
        uint64 nonce,
        address recipient
    ) private view returns (SwaputerKernel.VMEnvelope memory action) {
        action = SwaputerKernel.VMEnvelope({
            op: op,
            worldId: worldId,
            actor: vm.addr(privateKey),
            targetOrCodeHash: target,
            payload: payload,
            byteGasLimit: ACTION_LIMIT,
            minNetTokenOut: 0,
            nonce: nonce,
            deadline: uint64(block.timestamp + 1 days),
            recipient: recipient,
            authorizedExecutor: recipient,
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
                TickMath.MIN_SQRT_PRICE + 1,
                action.recipient,
                address(router),
                action.authorizedExecutor,
                action.nonce,
                action.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", kernel.domainSeparator(worldId), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        action.signature = abi.encodePacked(r, s, v);
    }

    function _queryWord(bytes32 target, string memory signature, bytes memory arguments)
        private
        view
        returns (bytes32 result)
    {
        bytes memory input = abi.encodePacked(bytes4(keccak256(bytes(signature))), arguments);
        (bytes memory output,) = kernel.staticCall(worldId, target, input, ACTION_LIMIT);
        assertEq(output.length, 32);
        result = abi.decode(output, (bytes32));
    }

    function _balance20(bytes32 target, bytes32 owner) private view returns (uint256) {
        return uint256(_queryWord(target, "balanceOf(bytes32)", abi.encode(owner)));
    }

    function _allowance20(bytes32 target, bytes32 owner, bytes32 spender) private view returns (uint256) {
        return uint256(_queryWord(target, "allowance(bytes32,bytes32)", abi.encode(owner, spender)));
    }

    function _balance1155(bytes32 target, bytes32 owner, uint256 id) private view returns (uint256) {
        return uint256(_queryWord(target, "balanceOf(bytes32,uint256)", abi.encode(owner, id)));
    }

    function _package(string memory name) private view returns (bytes memory) {
        string memory json = vm.readFile(string.concat("reference/", name, ".json"));
        return json.readBytes(".package");
    }

    function _buyParams() private pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
    }

    function _assertConstructorReceipt(Vm.Log[] memory logs, bytes32 contractId, bytes32 topic, uint8 count)
        private
        view
    {
        bytes memory payload = _eventPayload(logs);
        assertEq(uint8(payload[0]), 1);
        assertEq(uint8(payload[1]), 0);
        assertEq(uint8(payload[3]), count);
        assertEq(_word(payload, 8), contractId);
        assertEq(_word(payload, 41), topic);
    }

    function _assertApplicationReceipt(
        Vm.Log[] memory logs,
        bytes32 emitter,
        bytes32 topic,
        bytes32 indexed1,
        bytes32 indexed2,
        uint256 data
    ) private view {
        bytes memory payload = _eventPayload(logs);
        assertEq(uint8(payload[3]), 2);
        assertEq(_word(payload, 8), emitter);
        assertEq(uint8(payload[40]), 3);
        assertEq(_word(payload, 41), topic);
        assertEq(_word(payload, 73), indexed1);
        assertEq(_word(payload, 105), indexed2);
        assertEq(uint256(_word(payload, 141)), data);
    }

    function _eventPayload(Vm.Log[] memory logs) private view returns (bytes memory payload) {
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(kernel) && logs[i].topics[0] == EVENTS_TOPIC) {
                payload = abi.decode(logs[i].data, (bytes));
                ++count;
            }
        }
        assertEq(count, 1);
    }

    function _countEvents(Vm.Log[] memory logs) private view returns (uint256 count) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(kernel) && logs[i].topics[0] == EVENTS_TOPIC) ++count;
        }
    }

    function _word(bytes memory data, uint256 offset) private pure returns (bytes32 value) {
        assembly ("memory-safe") {
            value := mload(add(add(data, 0x20), offset))
        }
    }

    function _assertSettled() private view {
        IPoolManager poolManager = IPoolManager(address(manager));
        assertEq(poolManager.getNonzeroDeltaCount(), 0);
        assertEq(poolManager.currencyDelta(address(router), key.currency0), 0);
        assertEq(poolManager.currencyDelta(address(router), key.currency1), 0);
        assertEq(poolManager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(poolManager.currencyDelta(address(hook), key.currency1), 0);
    }

    receive() external payable {}
}
