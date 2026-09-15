// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";

import {SwaputerToken} from "../../src/SwaputerToken.sol";
import {SwaputerKernel} from "../../src/SwaputerKernel.sol";
import {SwaputerAppRouter} from "../../src/SwaputerAppRouter.sol";
import {SwaputerWorldFactory} from "../../src/SwaputerWorldFactory.sol";
import {SwapVMStage7A2Test} from "../SwapVMStage7A2.t.sol";

contract SwapVMStage7BRouterHandler is Test {
    SwaputerAppRouter private immutable _router;
    SwaputerToken private immutable _token;
    SwaputerKernel private immutable _kernel;
    bytes32 private immutable _worldId;
    address[3] private _actors;
    uint256[3] private _actorKeys;
    bytes32[3][3] private _targets;
    uint256 public successfulBuys;
    uint256 public totalBurn;
    uint256 public forcedEth;
    uint256 public accidentalToken;

    constructor(SwaputerAppRouter router_, SwaputerToken token_, SwaputerKernel kernel_, bytes32 worldId_) {
        _router = router_;
        _token = token_;
        _kernel = kernel_;
        _worldId = worldId_;
        for (uint256 i; i < _actors.length; i++) {
            uint256 key = 0x7000 + i;
            address actor = vm.addr(key);
            _actorKeys[i] = key;
            _actors[i] = actor;
            vm.deal(actor, 1_000 ether);
            vm.prank(actor);
            token_.approve(address(router_), type(uint256).max);
        }
    }

    function buy(uint8 actorIndex, uint96 rawInput) external {
        address actor = _actors[actorIndex % _actors.length];
        uint256 input = bound(uint256(rawInput), 1e14, 2 ether);
        uint256 supplyBefore = _token.totalSupply();
        vm.prank(actor);
        try _router.buyNOPExactInput{value: input}(_worldId, 1, TickMath.MIN_SQRT_PRICE + 1, actor) {
            successfulBuys += 1;
            totalBurn += supplyBefore - _token.totalSupply();
        } catch {
            assertEq(_token.totalSupply(), supplyBefore);
        }
    }

    function sell(uint8 actorIndex, uint96 rawAmount) external {
        address actor = _actors[actorIndex % _actors.length];
        uint256 balance = _token.balanceOf(actor);
        if (balance == 0) return;
        uint128 amount =
            uint128(bound(uint256(rawAmount), 1, balance > type(uint128).max ? type(uint128).max : balance));
        uint256 supplyBefore = _token.totalSupply();
        vm.prank(actor);
        try _router.sellExactInput(_worldId, amount, 0, TickMath.MAX_SQRT_PRICE - 1, actor) {} catch {}
        assertEq(_token.totalSupply(), supplyBefore);
    }

    function failingSlippage(uint8 actorIndex, uint96 rawInput) external {
        address actor = _actors[actorIndex % _actors.length];
        uint256 input = bound(uint256(rawInput), 1e14, 1 ether);
        uint256 supplyBefore = _token.totalSupply();
        vm.prank(actor);
        try _router.buyNOPExactInput{value: input}(_worldId, type(uint128).max, TickMath.MIN_SQRT_PRICE + 1, actor) {}
            catch {}
        assertEq(_token.totalSupply(), supplyBefore);
    }

    function forceEth(uint64 rawAmount) external {
        uint256 amount = bound(uint256(rawAmount), 1, 1 ether);
        forcedEth += amount;
        vm.deal(address(_router), address(_router).balance + amount);
    }

    function accidentalTokenTransfer(uint8 actorIndex, uint64 rawAmount) external {
        address actor = _actors[actorIndex % _actors.length];
        uint256 balance = _token.balanceOf(actor);
        if (balance == 0) return;
        uint256 amount = bound(uint256(rawAmount), 1, balance);
        vm.prank(actor);
        _token.transfer(address(_router), amount);
        accidentalToken += amount;
    }

    function directCallback(bytes32 mutation) external {
        try _router.unlockCallback(abi.encode(mutation)) {
            fail();
        } catch {}
    }

    function signedDeploy(uint8 rawActor, uint8 rawKind) external {
        uint256 actorIndex = rawActor % _actors.length;
        uint256 kind = rawKind % 3;
        if (_targets[actorIndex][kind] != bytes32(0)) return;
        address actor = _actors[actorIndex];
        bytes memory code;
        if (kind == 0) code = hex"00";
        else if (kind == 1) code = hex"0060006000fd";
        else code = hex"00600100";
        bytes memory packageBytes = _package(0, kind == 0 ? 0 : 1, keccak256(abi.encode("stage7b", kind)), code);
        bytes32 codeHash = keccak256(packageBytes);
        bytes32 actorId = _kernel.eoaAccountId(actor);
        bytes32 target = _kernel.contractAccountId(_worldId, actorId, _kernel.creatorNonce(_worldId, actorId), codeHash);
        bytes memory payload = abi.encodePacked(bytes4(uint32(packageBytes.length)), packageBytes);
        SwaputerKernel.VMEnvelope memory action = _signedAction(
            actorIndex,
            SwaputerKernel.RootOp.DEPLOY,
            _worldId,
            codeHash,
            payload,
            32,
            _kernel.nonces(_worldId, actorId),
            block.timestamp + 1 days,
            actor,
            actor,
            0.25 ether,
            TickMath.MIN_SQRT_PRICE + 1,
            address(_router)
        );
        uint256 supplyBefore = _token.totalSupply();
        uint64 heightBefore = _kernel.executionHeight(_worldId);
        vm.prank(actor);
        try _router.buyVMExactInput{value: 0.25 ether}(_worldId, TickMath.MIN_SQRT_PRICE + 1, action) {
            _recordSuccess(supplyBefore, heightBefore);
            _targets[actorIndex][kind] = target;
        } catch {
            assertEq(_token.totalSupply(), supplyBefore);
            assertEq(_kernel.executionHeight(_worldId), heightBefore);
        }
    }

    function signedCallRevertOrOutOfByteGas(uint8 rawActor, uint8 rawKind) external {
        uint256 actorIndex = rawActor % _actors.length;
        uint256 kind = rawKind % 3;
        bytes32 target = _targets[actorIndex][kind];
        if (target == bytes32(0)) return;
        address actor = _actors[actorIndex];
        bytes32 actorId = _kernel.eoaAccountId(actor);
        SwaputerKernel.VMEnvelope memory action = _signedAction(
            actorIndex,
            SwaputerKernel.RootOp.CALL,
            _worldId,
            target,
            bytes(""),
            kind == 2 ? 1 : 32,
            _kernel.nonces(_worldId, actorId),
            block.timestamp + 1 days,
            actor,
            actor,
            0.25 ether,
            TickMath.MIN_SQRT_PRICE + 1,
            address(_router)
        );
        uint256 supplyBefore = _token.totalSupply();
        uint64 heightBefore = _kernel.executionHeight(_worldId);
        vm.prank(actor);
        try _router.buyVMExactInput{value: 0.25 ether}(_worldId, TickMath.MIN_SQRT_PRICE + 1, action) {
            assertEq(kind, 0, "revert/OOB call unexpectedly committed");
            _recordSuccess(supplyBefore, heightBefore);
        } catch {
            assertTrue(kind != 0, "STOP call unexpectedly failed");
            assertEq(_token.totalSupply(), supplyBefore);
            assertEq(_kernel.executionHeight(_worldId), heightBefore);
        }
    }

    function invalidSignedMutation(uint8 rawActor, uint8 rawMode) external {
        uint256 actorIndex = rawActor % _actors.length;
        uint256 mode = rawMode % 11;
        address actor = _actors[actorIndex];
        bytes32 actorId = _kernel.eoaAccountId(actor);
        uint128 signedInput = 0.25 ether;
        uint160 signedPrice = TickMath.MIN_SQRT_PRICE + 1;
        SwaputerKernel.VMEnvelope memory action = _signedAction(
            actorIndex,
            SwaputerKernel.RootOp.CALL,
            _worldId,
            bytes32(uint256(1)),
            hex"00",
            32,
            _kernel.nonces(_worldId, actorId),
            block.timestamp + 1 days,
            actor,
            actor,
            signedInput,
            signedPrice,
            mode == 4 ? address(0xBAD0) : address(_router)
        );
        if (mode == 0) action.signature[0] ^= 0x01;
        if (mode == 1) {
            action.nonce += 1;
            action = _resign(actorIndex, action, signedInput, signedPrice, address(_router));
        }
        if (mode == 2) {
            action.deadline = uint64(block.timestamp - 1);
            action = _resign(actorIndex, action, signedInput, signedPrice, address(_router));
        }
        if (mode == 3) {
            action.worldId = keccak256(abi.encode(_worldId, "cross-world"));
            action = _resign(actorIndex, action, signedInput, signedPrice, address(_router));
        }
        if (mode == 5) action.recipient = address(0xBAD5);
        if (mode == 6) action.authorizedExecutor = address(0xBAD6);
        if (mode == 7) action.payload[0] = 0x01;
        if (mode == 8) action.op = SwaputerKernel.RootOp.DEPLOY;
        uint128 actualInput = mode == 9 ? uint128(0.2 ether) : signedInput;
        uint160 actualPrice = mode == 10 ? TickMath.MIN_SQRT_PRICE + 2 : signedPrice;
        uint256 supplyBefore = _token.totalSupply();
        uint64 heightBefore = _kernel.executionHeight(_worldId);
        vm.prank(actor);
        try _router.buyVMExactInput{value: actualInput}(_worldId, actualPrice, action) {
            fail();
        } catch {
            assertEq(_token.totalSupply(), supplyBefore);
            assertEq(_kernel.executionHeight(_worldId), heightBefore);
        }
    }

    function approvalMode(uint8 rawActor, bool revoke) external {
        address actor = _actors[rawActor % _actors.length];
        vm.prank(actor);
        _token.approve(address(_router), revoke ? 0 : type(uint256).max);
    }

    function _recordSuccess(uint256 supplyBefore, uint64 heightBefore) private {
        uint256 burned = supplyBefore - _token.totalSupply();
        assertEq(_kernel.executionHeight(_worldId), heightBefore + 1);
        successfulBuys += 1;
        totalBurn += burned;
    }

    function _signedAction(
        uint256 actorIndex,
        SwaputerKernel.RootOp op,
        bytes32 actionWorldId,
        bytes32 target,
        bytes memory payload,
        uint32 byteLimit,
        uint64 nonce,
        uint256 deadline,
        address recipient,
        address executor,
        uint128 exactEthInput,
        uint160 priceLimit,
        address routerBinding
    ) private view returns (SwaputerKernel.VMEnvelope memory action) {
        action = SwaputerKernel.VMEnvelope({
            op: op,
            worldId: actionWorldId,
            actor: _actors[actorIndex],
            targetOrCodeHash: target,
            payload: payload,
            byteGasLimit: byteLimit,
            minNetTokenOut: 0,
            nonce: nonce,
            deadline: uint64(deadline),
            recipient: recipient,
            authorizedExecutor: executor,
            signature: bytes("")
        });
        return _resign(actorIndex, action, exactEthInput, priceLimit, routerBinding);
    }

    function _resign(
        uint256 actorIndex,
        SwaputerKernel.VMEnvelope memory action,
        uint128 exactEthInput,
        uint160 priceLimit,
        address routerBinding
    ) private view returns (SwaputerKernel.VMEnvelope memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                _kernel.VM_ACTION_TYPEHASH(),
                uint8(action.op),
                action.worldId,
                action.actor,
                action.targetOrCodeHash,
                keccak256(action.payload),
                action.byteGasLimit,
                action.minNetTokenOut,
                exactEthInput,
                priceLimit,
                action.recipient,
                routerBinding,
                action.authorizedExecutor,
                action.nonce,
                action.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", _kernel.domainSeparator(action.worldId), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_actorKeys[actorIndex], digest);
        action.signature = abi.encodePacked(r, s, v);
        return action;
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
}

contract SwapVMStage7BRouterInvariantTest is StdInvariant, SwapVMStage7A2Test {
    using TransientStateLibrary for PoolManager;

    SwapVMStage7BRouterHandler private handler;
    uint256 private initialSupply;

    function setUp() public override {
        super.setUp();
        handler = new SwapVMStage7BRouterHandler(router, token, kernel, worldId);
        initialSupply = token.totalSupply();
        targetContract(address(handler));
    }

    function invariant_assetConservationHeightBurnAndSettlement() public view {
        assertEq(kernel.executionHeight(worldId), handler.successfulBuys());
        assertEq(initialSupply - token.totalSupply(), handler.totalBurn());
        assertEq(handler.totalBurn(), handler.successfulBuys() * BYTE_GAS_PRICE);
        assertEq(address(router).balance, handler.forcedEth());
        assertEq(token.balanceOf(address(router)), handler.accidentalToken());
        assertEq(manager.getNonzeroDeltaCount(), 0);
    }

    function invariant_factoryBindingsRemainImmutable() public view {
        SwaputerWorldFactory.WorldConfig memory config = factory.getWorldConfig(worldId);
        assertTrue(config.isSealed);
        assertEq(config.kernel, address(kernel));
        assertEq(config.hook, address(hook));
        assertEq(config.gasToken, address(token));
        assertEq(config.configHash, _worldConfigHash(worldId, config));
        assertEq(address(factory.poolManager()), address(manager));
        assertEq(factory.poolManagerCodeHash(), address(manager).codehash);
    }
}
