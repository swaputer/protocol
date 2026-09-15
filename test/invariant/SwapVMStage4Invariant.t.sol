// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
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

import {SwaputerToken} from "../../src/SwaputerToken.sol";
import {SwaputerHook} from "../../src/SwaputerHook.sol";
import {SwaputerKernel} from "../../src/SwaputerKernel.sol";
import {SwapVMKernelStage2Harness, SwapVMStage2Router} from "../SwapVMStage2.t.sol";

contract SwapVMStage4Handler is Test {
    uint256 private constant ACTOR_KEY = 0x51524320;
    uint256 private constant OPERATOR_KEY = 0x51524321;
    uint128 private constant ETH_IN = 0.1 ether;
    uint32 private constant LIMIT = 5_000;

    SwapVMStage2Router private immutable _router;
    SwaputerKernel private immutable _kernel;
    PoolKey private _key;
    bytes32 private immutable _worldId;
    bytes32 private immutable _tokenId;
    bytes32 private immutable _actorId;
    bytes32 private immutable _operatorId;

    uint256 public modelActor = 1_000_000;
    uint256 public modelOperator;
    uint64 public actorCalls;
    uint64 public operatorCalls;
    uint256 public totalExecutedBytes;

    constructor(
        SwapVMStage2Router router,
        SwaputerKernel kernel,
        PoolKey memory key_,
        bytes32 worldId_,
        bytes32 tokenId
    ) {
        _router = router;
        _kernel = kernel;
        _key = key_;
        _worldId = worldId_;
        _tokenId = tokenId;
        _actorId = kernel.eoaAccountId(vm.addr(ACTOR_KEY));
        _operatorId = kernel.eoaAccountId(vm.addr(OPERATOR_KEY));
    }

    function move(bool actorToOperator, uint32 rawAmount) external {
        uint256 available = actorToOperator ? modelActor : modelOperator;
        if (available == 0) return;
        uint256 amount = bound(uint256(rawAmount), 0, available);
        uint256 privateKey = actorToOperator ? ACTOR_KEY : OPERATOR_KEY;
        bytes32 recipientId = actorToOperator ? _operatorId : _actorId;
        uint64 nonce = actorToOperator ? 1 + actorCalls : operatorCalls;
        bytes memory payload =
            abi.encodePacked(bytes4(keccak256("transfer(bytes32,uint256)")), abi.encode(recipientId, amount));
        SwaputerKernel.VMEnvelope memory action = SwaputerKernel.VMEnvelope({
            op: SwaputerKernel.RootOp.CALL,
            worldId: _worldId,
            actor: vm.addr(privateKey),
            targetOrCodeHash: _tokenId,
            payload: payload,
            byteGasLimit: LIMIT,
            minNetTokenOut: 0,
            nonce: nonce,
            deadline: uint64(block.timestamp + 1 days),
            recipient: address(this),
            authorizedExecutor: address(this),
            signature: bytes("")
        });
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
                ETH_IN,
                TickMath.MIN_SQRT_PRICE + 1,
                action.recipient,
                address(_router),
                action.authorizedExecutor,
                action.nonce,
                action.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", _kernel.domainSeparator(_worldId), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        action.signature = abi.encodePacked(r, s, v);

        try _router.swap{value: ETH_IN}(
            _key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(uint256(ETH_IN)),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            address(this),
            abi.encode(action)
        ) {
            if (actorToOperator) {
                modelActor -= amount;
                modelOperator += amount;
                ++actorCalls;
            } else {
                modelOperator -= amount;
                modelActor += amount;
                ++operatorCalls;
            }
            totalExecutedBytes += _kernel.executedBytes(_worldId);
        } catch {}
    }

    receive() external payable {}
}

contract SwapVMStage4InvariantTest is StdInvariant, Test {
    using stdJson for string;
    using TransientStateLibrary for IPoolManager;

    uint256 private constant INITIAL_SUPPLY = 1e36;
    uint128 private constant BYTE_GAS_PRICE = 1e12;
    uint24 private constant POOL_FEE = 3000;
    int24 private constant TICK_SPACING = 60;
    uint256 private constant ACTOR_KEY = 0x51524320;
    uint32 private constant LIMIT = 5_000;

    PoolManager private manager;
    SwaputerToken private token;
    SwapVMKernelStage2Harness private kernel;
    SwaputerHook private hook;
    SwapVMStage2Router private router;
    PoolKey private key;
    bytes32 private worldId;
    bytes32 private src20;
    bytes32 private actorId;
    bytes32 private operatorId;
    uint256 private supplyAfterDeploy;
    SwapVMStage4Handler private handler;

    function setUp() public {
        vm.deal(address(this), 1e30);
        address actor = vm.addr(ACTOR_KEY);
        vm.deal(actor, 100 ether);
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

        actorId = kernel.eoaAccountId(actor);
        operatorId = kernel.eoaAccountId(vm.addr(0x51524321));
        string memory json = vm.readFile("reference/SRC20-v1.json");
        bytes memory packageBytes = json.readBytes(".package");
        bytes32 codeHash = keccak256(packageBytes);
        src20 = kernel.contractAccountId(worldId, actorId, 0, codeHash);
        bytes memory constructorInput =
            abi.encode(bytes32("Invariant"), bytes32("I20"), uint256(18), uint256(1_000_000), actorId);
        _deploy(actor, packageBytes, constructorInput, codeHash);
        supplyAfterDeploy = token.totalSupply();

        handler = new SwapVMStage4Handler(router, kernel, key, worldId, src20);
        vm.deal(address(handler), 1e28);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = SwapVMStage4Handler.move.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_src20SupplyAndModelBalancesReconcile() public view {
        uint256 actorBalance = _balance(actorId);
        uint256 operatorBalance = _balance(operatorId);
        assertEq(actorBalance, handler.modelActor());
        assertEq(operatorBalance, handler.modelOperator());
        assertEq(actorBalance + operatorBalance, 1_000_000);
        assertEq(uint256(_query("totalSupply()", bytes(""))), 1_000_000);
    }

    function invariant_nonceHeightBurnAndSettlementReconcile() public view {
        uint256 calls = uint256(handler.actorCalls()) + handler.operatorCalls();
        assertEq(kernel.executionHeight(worldId), 1 + calls);
        assertEq(kernel.nonces(worldId, actorId), 1 + handler.actorCalls());
        assertEq(kernel.nonces(worldId, operatorId), handler.operatorCalls());
        assertEq(token.totalSupply(), supplyAfterDeploy - handler.totalExecutedBytes() * BYTE_GAS_PRICE);
        assertEq(token.balanceOf(address(hook)), 0);
        IPoolManager poolManager = IPoolManager(address(manager));
        assertEq(poolManager.getNonzeroDeltaCount(), 0);
        assertEq(poolManager.currencyDelta(address(router), key.currency0), 0);
        assertEq(poolManager.currencyDelta(address(router), key.currency1), 0);
        assertEq(poolManager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(poolManager.currencyDelta(address(hook), key.currency1), 0);
    }

    function _deploy(address actor, bytes memory packageBytes, bytes memory constructorInput, bytes32 codeHash)
        private
    {
        bytes memory payload = abi.encodePacked(bytes4(uint32(packageBytes.length)), packageBytes, constructorInput);
        SwaputerKernel.VMEnvelope memory action = SwaputerKernel.VMEnvelope({
            op: SwaputerKernel.RootOp.DEPLOY,
            worldId: worldId,
            actor: actor,
            targetOrCodeHash: codeHash,
            payload: payload,
            byteGasLimit: LIMIT,
            minNetTokenOut: 0,
            nonce: 0,
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
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ACTOR_KEY, digest);
        action.signature = abi.encodePacked(r, s, v);
        vm.prank(actor);
        router.swap{value: 1 ether}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            actor,
            abi.encode(action)
        );
    }

    function _balance(bytes32 owner) private view returns (uint256) {
        return uint256(_query("balanceOf(bytes32)", abi.encode(owner)));
    }

    function _query(string memory signature, bytes memory arguments) private view returns (bytes32 result) {
        bytes memory input = abi.encodePacked(bytes4(keccak256(bytes(signature))), arguments);
        (bytes memory output,) = kernel.staticCall(worldId, src20, input, LIMIT);
        result = abi.decode(output, (bytes32));
    }

    receive() external payable {}
}
