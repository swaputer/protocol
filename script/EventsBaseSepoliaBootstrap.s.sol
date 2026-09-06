// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {Plan, Planner} from "@uniswap/v4-periphery/test/shared/Planner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {SwapVMGasToken} from "../src/SwapVMGasToken.sol";
import {SwapVMHook} from "../src/SwapVMHook.sol";
import {SwapVMKernel} from "../src/SwapVMKernel.sol";
import {SwapVMRouter} from "../src/SwapVMRouter.sol";
import {SwapVMSRC20Market} from "../src/SwapVMSRC20Market.sol";
import {SwapVMWorldFactory} from "../src/SwapVMWorldFactory.sol";

interface IPositionManagerSingleSided {
    function poolManager() external view returns (address);
    function permit2() external view returns (address);
    function nextTokenId() external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128);
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
}

interface IPermit2SingleSided {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;

    function allowance(address owner, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);
}

/// @notice Bootstraps liquidity and reference applications for the Base Sepolia Events World.
contract EventsBaseSepoliaBootstrapScript is Script {
    using Planner for Plan;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 private constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    uint256 private constant RELEASE_ETH_CAP = 0.5 ether;
    address private constant ACTOR = 0x590a77Ec892bB78206bcad2444B62d1bC31A2D03;

    address private constant POOL_MANAGER = 0xf7F5aB3DcA35e17dE187b459159BC643853B3c67;
    bytes32 private constant POOL_MANAGER_CODE_HASH =
        0xd49bdfce86ce75c9927a3b7db8fae5b63c3f82ce75b099084bad315485e826cc;
    IPositionManagerSingleSided private constant POSITION_MANAGER =
        IPositionManagerSingleSided(0x0B32f74f8365d535783949E014B7754047B64e31);
    bytes32 private constant POSITION_MANAGER_CODE_HASH =
        0x3c87fb51995d3b4c4e0a49b22ed3a2497d0e9ba24c29419a56c88c926ad9cbb1;
    IPermit2SingleSided private constant PERMIT2 = IPermit2SingleSided(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    IPoolManager private constant MANAGER = IPoolManager(POOL_MANAGER);

    SwapVMWorldFactory private factory;
    SwapVMRouter private router;
    bytes32 private configuredWorldId;
    SwapVMGasToken private configuredGasToken;
    SwapVMKernel private configuredKernel;
    SwapVMHook private configuredHook;

    uint256 private constant INITIAL_SUPPLY = 1_000_000_000 ether;
    uint128 private constant BYTE_GAS_PRICE = 1_000_000_000_000;
    uint24 private constant POOL_FEE = 3_000;
    int24 private constant TICK_SPACING = 60;
    // sqrt(100_000 SVMG / ETH) * 2^96. Therefore 1 SVMG = 0.00001 ETH.
    uint160 private constant INITIAL_SQRT_PRICE_X96 = 25_054_144_837_504_793_118_641_380_156_960;
    int24 private constant TICK_LOWER = 110_040;
    int24 private constant TICK_UPPER = 115_080;
    uint128 private constant VM_INPUT = 0.000001 ether;
    uint128 private constant ORDER_AMOUNT = 100 ether;
    uint128 private constant UNIT_PRICE = 0.00001 ether;
    uint128 private constant ORDER_PRICE = 0.001 ether;
    uint32 private constant DEPLOY_LIMIT = 500;
    uint32 private constant TOKEN_LIMIT = 1_000;
    uint32 private constant ESCROW_LIMIT = 8_000;
    uint160 private constant SQRT_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;

    uint256 private actorKey;
    uint256 private releaseStartBalance;
    bytes32 private worldId;
    SwapVMGasToken private gasToken;
    SwapVMKernel private kernel;
    SwapVMHook private hook;
    bytes32 private token;
    bytes32 private tokenCodeHash;
    bytes32 private escrow;
    bytes32 private escrowCodeHash;
    SwapVMSRC20Market private market;
    uint256 private positionTokenId;
    uint128 private positionLiquidity;
    uint256 private oneSidedTokenDeposited;

    function run() external {
        _validateEnvironment();
        _loadWorld();
        _bootstrapAllSupplyOneSided();
        _proveTradableWithNopBuy();
        _deployProgramsAndMarket();
        _exerciseMarket();
        _validateFinalState();
        _enforceReleaseCap();
        _logResult();
    }

    function _validateEnvironment() private {
        require(block.chainid == BASE_SEPOLIA_CHAIN_ID, "BASE_SEPOLIA_ONLY");
        factory = SwapVMWorldFactory(vm.envAddress("SVM_FACTORY_ADDRESS"));
        router = SwapVMRouter(payable(vm.envAddress("SVM_ROUTER_ADDRESS")));
        configuredWorldId = vm.envBytes32("SVM_WORLD_ID");
        configuredGasToken = SwapVMGasToken(vm.envAddress("SVM_GAS_TOKEN_ADDRESS"));
        configuredKernel = SwapVMKernel(vm.envAddress("SVM_KERNEL_ADDRESS"));
        configuredHook = SwapVMHook(payable(vm.envAddress("SVM_HOOK_ADDRESS")));
        require(POOL_MANAGER.codehash == POOL_MANAGER_CODE_HASH, "POOL_MANAGER_CODE_HASH");
        require(address(POSITION_MANAGER).codehash == POSITION_MANAGER_CODE_HASH, "POSITION_MANAGER_CODE_HASH");
        require(POSITION_MANAGER.poolManager() == POOL_MANAGER, "POSITION_MANAGER_POOL_MANAGER");
        require(POSITION_MANAGER.permit2() == address(PERMIT2), "POSITION_MANAGER_PERMIT2");
        require(address(factory.poolManager()) == POOL_MANAGER, "FACTORY_POOL_MANAGER");
        require(factory.router() == address(router), "FACTORY_ROUTER");
        actorKey = vm.envUint("STAGE7A2_PRIVATE_KEY");
        require(vm.addr(actorKey) == ACTOR, "ACTOR_MISMATCH");
        releaseStartBalance = vm.envUint("V12_RELEASE_START_BALANCE");
        require(ACTOR.balance <= releaseStartBalance, "START_BALANCE_TOO_LOW");
        _enforceReleaseCap();
    }

    function _loadWorld() private {
        worldId = configuredWorldId;
        gasToken = configuredGasToken;
        kernel = configuredKernel;
        hook = configuredHook;
        (PoolKey memory key, bool isSealed) = factory.getPoolKey(worldId);
        require(isSealed && PoolId.unwrap(key.toId()) == worldId, "WORLD_NOT_SEALED");
        require(address(kernel.hook()) == address(hook), "KERNEL_HOOK");
        require(address(hook.kernel()) == address(kernel), "HOOK_KERNEL");
        require(address(hook.gasToken()) == address(gasToken), "HOOK_TOKEN");
        require(uint160(address(hook)) & Hooks.ALL_HOOK_MASK == 0x20cc, "HOOK_PERMISSION_BITS");
        (uint160 sqrtPriceX96, int24 tick,, uint24 lpFee) = MANAGER.getSlot0(key.toId());
        require(sqrtPriceX96 == INITIAL_SQRT_PRICE_X96, "INITIAL_PRICE");
        require(tick > TICK_UPPER, "POSITION_NOT_ONE_SIDED");
        require(lpFee == POOL_FEE, "LP_FEE");
    }

    function _bootstrapAllSupplyOneSided() private {
        (PoolKey memory key,) = factory.getPoolKey(worldId);
        uint160 lowerSqrtPriceX96 = TickMath.getSqrtPriceAtTick(TICK_LOWER);
        uint160 upperSqrtPriceX96 = TickMath.getSqrtPriceAtTick(TICK_UPPER);
        positionLiquidity =
            LiquidityAmounts.getLiquidityForAmount1(lowerSqrtPriceX96, upperSqrtPriceX96, INITIAL_SUPPLY);
        require(positionLiquidity != 0, "ZERO_LIQUIDITY");
        positionTokenId = POSITION_MANAGER.nextTokenId();
        require(gasToken.balanceOf(ACTOR) == INITIAL_SUPPLY, "INITIAL_HOLDER_BALANCE");

        vm.startBroadcast(actorKey);
        gasToken.approve(address(PERMIT2), INITIAL_SUPPLY);
        PERMIT2.approve(
            address(gasToken), address(POSITION_MANAGER), uint160(INITIAL_SUPPLY), uint48(block.timestamp + 1 hours)
        );
        POSITION_MANAGER.modifyLiquidities(_mintPlan(key), block.timestamp + 600);
        PERMIT2.approve(address(gasToken), address(POSITION_MANAGER), 0, 0);
        gasToken.approve(address(PERMIT2), 0);
        vm.stopBroadcast();

        oneSidedTokenDeposited = INITIAL_SUPPLY - gasToken.balanceOf(ACTOR);
        // One liquidity unit consumes about 70 token wei for this range. The maximal
        // non-reverting liquidity therefore leaves 42 wei, which cannot be added.
        require(INITIAL_SUPPLY - oneSidedTokenDeposited <= 100, "SUPPLY_DUST_TOO_LARGE");
        require(POSITION_MANAGER.ownerOf(positionTokenId) == ACTOR, "NEW_POSITION_OWNER");
        require(POSITION_MANAGER.getPositionLiquidity(positionTokenId) == positionLiquidity, "NEW_POSITION_LIQUIDITY");
        (uint128 managerLiquidity,,) = MANAGER.getPositionInfo(
            key.toId(), address(POSITION_MANAGER), TICK_LOWER, TICK_UPPER, bytes32(positionTokenId)
        );
        require(managerLiquidity == positionLiquidity, "POOL_POSITION_LIQUIDITY");
        require(gasToken.allowance(ACTOR, address(PERMIT2)) == 0, "ERC20_ALLOWANCE_REMAINS");
        (uint160 permitAmount,,) = PERMIT2.allowance(ACTOR, address(gasToken), address(POSITION_MANAGER));
        require(permitAmount == 0, "PERMIT2_ALLOWANCE_REMAINS");
    }

    function _proveTradableWithNopBuy() private {
        uint256 supplyBefore = gasToken.totalSupply();
        vm.startBroadcast(actorKey);
        router.buyNOPExactInput{value: VM_INPUT}(worldId, 1, SQRT_PRICE_LIMIT, ACTOR);
        vm.stopBroadcast();
        require(kernel.executionHeight(worldId) == 1, "NOP_HEIGHT");
        require(kernel.executedBytes(worldId) == 1, "NOP_BYTES");
        require(gasToken.totalSupply() == supplyBefore - BYTE_GAS_PRICE, "NOP_BURN");
    }

    function _deployProgramsAndMarket() private {
        bytes32 actorId = kernel.eoaAccountId(ACTOR);
        bytes memory tokenPackage = vm.readFileBinary("tooling/tinysol/programs/mintable-src20/MintableSRC20.svm");
        tokenCodeHash = keccak256(tokenPackage);
        require(tokenCodeHash == 0xaf15e40fe9fc1181a7143abb413562d69e1ab49a655209ac966204646c85c14b, "MINTABLE_HASH");
        token = kernel.contractAccountId(worldId, actorId, kernel.creatorNonce(worldId, actorId), tokenCodeHash);
        _executeDeploy(tokenCodeHash, abi.encodePacked(bytes4(uint32(tokenPackage.length)), tokenPackage));
        _executeCall(
            token, abi.encodePacked(bytes4(keccak256("mint(bytes32)")), abi.encode(actorId)), TOKEN_LIMIT, ACTOR, ACTOR
        );
        require(_tokenBalance(actorId) == 1_000 ether, "MINT_BALANCE");

        bytes memory escrowPackage = vm.readFileBinary("tooling/tinysol/programs/market-escrow/MarketEscrow.svm");
        escrowCodeHash = keccak256(escrowPackage);
        require(escrowCodeHash == 0x6da9921193ebfe79468ef74f5b94925b66bf8230e145234a77868f1e5a85614b, "ESCROW_HASH");
        escrow = kernel.contractAccountId(worldId, actorId, kernel.creatorNonce(worldId, actorId), escrowCodeHash);
        address predictedMarket = vm.computeCreateAddress(ACTOR, vm.getNonce(ACTOR) + 1);
        _executeDeploy(
            escrowCodeHash,
            abi.encodePacked(bytes4(uint32(escrowPackage.length)), escrowPackage, abi.encode(token, predictedMarket))
        );

        vm.startBroadcast(actorKey);
        market = new SwapVMSRC20Market(router, worldId, token, tokenCodeHash, escrow, escrowCodeHash);
        vm.stopBroadcast();
        require(address(market) == predictedMarket, "MARKET_PREDICTION");
    }

    function _exerciseMarket() private {
        uint64 expiry = uint64(block.timestamp + 1 days);
        vm.startBroadcast(actorKey);
        uint256 buyOrderId =
            market.createBuyOrder{value: ORDER_PRICE + VM_INPUT}(ORDER_AMOUNT, UNIT_PRICE, VM_INPUT, expiry);
        vm.stopBroadcast();
        SwapVMKernel.VMEnvelope memory transfer = _signedCall(
            token,
            abi.encodePacked(
                bytes4(keccak256("transfer(bytes32,uint256)")), abi.encode(kernel.eoaAccountId(ACTOR), ORDER_AMOUNT)
            ),
            TOKEN_LIMIT,
            ACTOR,
            address(market)
        );
        vm.startBroadcast(actorKey);
        market.fillBuyOrder(buyOrderId, transfer, SQRT_PRICE_LIMIT);
        vm.stopBroadcast();

        _executeCall(
            token,
            abi.encodePacked(bytes4(keccak256("approve(bytes32,uint256)")), abi.encode(escrow, ORDER_AMOUNT)),
            TOKEN_LIMIT,
            ACTOR,
            ACTOR
        );
        SwapVMKernel.VMEnvelope memory deposit = _signedCall(
            escrow,
            abi.encodePacked(
                bytes4(keccak256("deposit(bytes32,uint256)")), abi.encode(kernel.eoaAccountId(ACTOR), ORDER_AMOUNT)
            ),
            ESCROW_LIMIT,
            ACTOR,
            address(market)
        );
        vm.startBroadcast(actorKey);
        uint256 sellOrderId = market.createSellOrder{value: VM_INPUT}(
            ORDER_AMOUNT, UNIT_PRICE, VM_INPUT, expiry, deposit, SQRT_PRICE_LIMIT
        );
        vm.stopBroadcast();
        SwapVMKernel.VMEnvelope memory release = _signedCall(
            escrow,
            abi.encodePacked(
                bytes4(keccak256("release(bytes32,uint256)")), abi.encode(kernel.eoaAccountId(ACTOR), ORDER_AMOUNT)
            ),
            ESCROW_LIMIT,
            ACTOR,
            address(market)
        );
        vm.startBroadcast(actorKey);
        market.settleSellOrder{value: ORDER_PRICE + VM_INPUT}(sellOrderId, release, SQRT_PRICE_LIMIT);
        vm.stopBroadcast();
    }

    function _executeDeploy(bytes32 codeHash, bytes memory payload) private {
        SwapVMKernel.VMEnvelope memory envelope =
            _signed(SwapVMKernel.RootOp.DEPLOY, codeHash, payload, DEPLOY_LIMIT, ACTOR, ACTOR);
        vm.startBroadcast(actorKey);
        router.buyVMExactInput{value: VM_INPUT}(worldId, SQRT_PRICE_LIMIT, envelope);
        vm.stopBroadcast();
    }

    function _executeCall(bytes32 target, bytes memory payload, uint32 byteLimit, address recipient, address executor)
        private
    {
        SwapVMKernel.VMEnvelope memory envelope =
            _signed(SwapVMKernel.RootOp.CALL, target, payload, byteLimit, recipient, executor);
        vm.startBroadcast(actorKey);
        router.buyVMExactInput{value: VM_INPUT}(worldId, SQRT_PRICE_LIMIT, envelope);
        vm.stopBroadcast();
    }

    function _signedCall(bytes32 target, bytes memory payload, uint32 byteLimit, address recipient, address executor)
        private
        view
        returns (SwapVMKernel.VMEnvelope memory envelope)
    {
        return _signed(SwapVMKernel.RootOp.CALL, target, payload, byteLimit, recipient, executor);
    }

    function _signed(
        SwapVMKernel.RootOp op,
        bytes32 target,
        bytes memory payload,
        uint32 byteLimit,
        address recipient,
        address executor
    ) private view returns (SwapVMKernel.VMEnvelope memory envelope) {
        bytes32 actorId = kernel.eoaAccountId(ACTOR);
        envelope = SwapVMKernel.VMEnvelope({
            op: op,
            worldId: worldId,
            actor: ACTOR,
            targetOrCodeHash: target,
            payload: payload,
            byteGasLimit: byteLimit,
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

    function _mintPlan(PoolKey memory key) private view returns (bytes memory) {
        Plan memory plan = Planner.init();
        plan.add(
            Actions.MINT_POSITION,
            abi.encode(
                key,
                TICK_LOWER,
                TICK_UPPER,
                uint256(positionLiquidity),
                uint128(0),
                uint128(INITIAL_SUPPLY),
                ACTOR,
                bytes("")
            )
        );
        plan.add(Actions.CLOSE_CURRENCY, abi.encode(key.currency0));
        plan.add(Actions.CLOSE_CURRENCY, abi.encode(key.currency1));
        plan.add(Actions.SWEEP, abi.encode(key.currency0, ACTOR));
        return plan.encode();
    }

    function _validateFinalState() private view {
        require(market.orderCount() == 2, "ORDER_COUNT");
        require(market.lockedEth() == 0, "LOCKED_ETH");
        require(market.escrowedTokenAmount() == 0, "ESCROW_LIABILITY");
        require(market.activeSellAmount(ACTOR) == 0, "ACTIVE_SELL");
        require(address(market).balance == 0, "MARKET_ETH");
        require(_tokenBalance(escrow) == 0, "ESCROW_BALANCE");
        require(_tokenBalance(kernel.eoaAccountId(ACTOR)) == 1_000 ether, "ACTOR_TOKEN_BALANCE");
        require(kernel.executionHeight(worldId) == 8, "EXECUTION_HEIGHT");
        require(gasToken.totalSupply() == INITIAL_SUPPLY - 3_410 * uint256(BYTE_GAS_PRICE), "TOTAL_BURN");
    }

    function _tokenBalance(bytes32 accountId) private view returns (uint256 amount) {
        (bytes memory output,) = kernel.staticCall(
            worldId, token, abi.encodePacked(bytes4(keccak256("balanceOf(bytes32)")), abi.encode(accountId)), 3_000
        );
        require(output.length == 32, "BALANCE_WIDTH");
        amount = abi.decode(output, (uint256));
    }

    function _enforceReleaseCap() private view {
        if (ACTOR.balance < releaseStartBalance) {
            require(releaseStartBalance - ACTOR.balance <= RELEASE_ETH_CAP, "RELEASE_ETH_CAP_EXCEEDED");
        }
    }

    function _logResult() private view {
        console2.log("EVENTS_WORLD_ID");
        console2.logBytes32(worldId);
        console2.log("EVENTS_GAS_TOKEN", address(gasToken));
        console2.log("EVENTS_KERNEL", address(kernel));
        console2.log("EVENTS_HOOK", address(hook));
        console2.log("EVENTS_POSITION_TOKEN_ID", positionTokenId);
        console2.log("EVENTS_POSITION_LIQUIDITY", positionLiquidity);
        console2.log("EVENTS_TOKEN_DEPOSITED", oneSidedTokenDeposited);
        console2.log("EVENTS_INITIAL_SQRT_PRICE_X96", INITIAL_SQRT_PRICE_X96);
        console2.log("EVENTS_MARKET", address(market));
        console2.log("EVENTS_MINTABLE_SRC20_ID");
        console2.logBytes32(token);
        console2.log("EVENTS_MARKET_ESCROW_ID");
        console2.logBytes32(escrow);
        console2.log("EVENTS_EXECUTION_HEIGHT", kernel.executionHeight(worldId));
        console2.log("EVENTS_ACTOR_BALANCE_WEI", ACTOR.balance);
    }
}
