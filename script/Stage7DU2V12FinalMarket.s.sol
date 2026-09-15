// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {Plan, Planner} from "@uniswap/v4-periphery/test/shared/Planner.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {SwaputerCreationCodeStore} from "../src/SwaputerCreationCodeStore.sol";
import {SwaputerToken} from "../src/SwaputerToken.sol";
import {SwaputerHook} from "../src/SwaputerHook.sol";
import {SwaputerKernel} from "../src/SwaputerKernel.sol";
import {SwaputerAppRouter} from "../src/SwaputerAppRouter.sol";
import {SwapVMSRC20Market} from "../src/SwapVMSRC20Market.sol";
import {SwaputerWorldFactory} from "../src/SwaputerWorldFactory.sol";

interface IPositionManagerV12 {
    function poolManager() external view returns (address);
    function permit2() external view returns (address);
    function nextTokenId() external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128);
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
}

interface IPermit2V12 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;

    function allowance(address owner, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);
}

/// @notice Base Sepolia-only deployment of the unaudited v1.2 final escrow market.
/// @dev Uses the official v4 PoolManager and PositionManager. It has no mainnet path.
contract Stage7DU2V12FinalMarketScript is Script {
    using Planner for Plan;

    uint256 private constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    uint256 private constant RELEASE_ETH_CAP = 0.5 ether;
    address private constant EXPECTED_ACTOR = 0x590a77Ec892bB78206bcad2444B62d1bC31A2D03;

    address private constant POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    bytes32 private constant POOL_MANAGER_CODE_HASH =
        0x03c45db6d09b14da7c1f7239a5a49697f976d395277e6d2acb6fbed3f9e0249f;
    IPositionManagerV12 private constant POSITION_MANAGER =
        IPositionManagerV12(0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80);
    bytes32 private constant POSITION_MANAGER_CODE_HASH =
        0xe8329b35b8b34290b6cf03affc0836f7b23205229cc96ffdc66544b93112c076;
    IPermit2V12 private constant PERMIT2 = IPermit2V12(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    uint256 private constant INITIAL_GAS_TOKEN_SUPPLY = 1_000_000_000 ether;
    uint128 private constant BYTE_GAS_PRICE = 1_000_000_000_000;
    uint24 private constant POOL_FEE = 3_000;
    int24 private constant TICK_SPACING = 60;
    uint160 private constant INITIAL_SQRT_PRICE_X96 = 1 << 96;
    bytes32 private constant TOKEN_SALT = keccak256("SwapVM.v1.2.BaseSepolia.final-market.token.2026-08-30");
    bytes32 private constant BOOTSTRAP_SALT = keccak256("SwapVM.v1.2.BaseSepolia.final-market.bootstrap.2026-08-30");
    bytes32 private constant DISTRIBUTION_COMMITMENT =
        keccak256("SwapVM.v1.2.BaseSepolia.unaudited-zero-value.final-market");

    int24 private constant TICK_LOWER = -600;
    int24 private constant TICK_UPPER = 600;
    uint128 private constant LIQUIDITY = 3 ether;
    uint128 private constant MAX_NATIVE = 0.1 ether;
    uint128 private constant MAX_TOKEN = 0.1 ether;
    uint128 private constant VM_INPUT = 0.005 ether;
    uint128 private constant ORDER_AMOUNT = 100 ether;
    uint128 private constant UNIT_PRICE = 0.00000001 ether;
    uint128 private constant ORDER_PRICE = 0.000001 ether;
    uint32 private constant DEPLOY_LIMIT = 500;
    uint32 private constant TOKEN_LIMIT = 1_000;
    uint32 private constant ESCROW_LIMIT = 8_000;
    uint160 private constant SQRT_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;

    uint256 private actorKey;
    uint256 private releaseStartBalance;
    address private actor;
    SwaputerWorldFactory private factory;
    SwaputerAppRouter private router;
    SwaputerToken private gasToken;
    SwaputerKernel private kernel;
    SwaputerHook private hook;
    bytes32 private worldId;
    bytes32 private token;
    bytes32 private tokenCodeHash;
    bytes32 private escrow;
    bytes32 private escrowCodeHash;
    SwapVMSRC20Market private market;
    uint256 private positionTokenId;

    function run() external {
        _validateEnvironment();
        _deployWorld();
        _bootstrapOfficialLiquidity();
        _deployProgramsAndMarket();
        _exerciseMarket();
        _validateFinalState();
        _enforceReleaseCap();
        _logResult();
    }

    function _validateEnvironment() private {
        require(block.chainid == BASE_SEPOLIA_CHAIN_ID, "BASE_SEPOLIA_ONLY");
        require(POOL_MANAGER.codehash == POOL_MANAGER_CODE_HASH, "POOL_MANAGER_CODE_HASH");
        require(address(POSITION_MANAGER).codehash == POSITION_MANAGER_CODE_HASH, "POSITION_MANAGER_CODE_HASH");
        require(POSITION_MANAGER.poolManager() == POOL_MANAGER, "POSITION_MANAGER_POOL_MANAGER");
        require(POSITION_MANAGER.permit2() == address(PERMIT2), "POSITION_MANAGER_PERMIT2");
        actorKey = vm.envUint("STAGE7A2_PRIVATE_KEY");
        actor = vm.addr(actorKey);
        require(actor == EXPECTED_ACTOR, "ACTOR_MISMATCH");
        releaseStartBalance = vm.envUint("V12_RELEASE_START_BALANCE");
        require(actor.balance <= releaseStartBalance, "START_BALANCE_TOO_LOW");
        _enforceReleaseCap();
    }

    function _deployWorld() private {
        vm.startBroadcast(actorKey);
        SwaputerCreationCodeStore kernelStore = new SwaputerCreationCodeStore(type(SwaputerKernel).creationCode);
        SwaputerCreationCodeStore hookStore = new SwaputerCreationCodeStore(type(SwaputerHook).creationCode);
        factory = new SwaputerWorldFactory(
            IPoolManager(POOL_MANAGER),
            POOL_MANAGER_CODE_HASH,
            address(kernelStore),
            address(hookStore),
            vm.envAddress("SVM_PROTOCOL_FEE_ADMIN"),
            vm.envAddress("SVM_FEE_CONTROLLER")
        );
        vm.stopBroadcast();
        router = SwaputerAppRouter(payable(factory.router()));

        address predictedToken = factory.predictGasToken(TOKEN_SALT, INITIAL_GAS_TOKEN_SUPPLY, actor);
        address predictedWorldDeployer = factory.predictWorldDeployer(BOOTSTRAP_SALT);
        address predictedKernel = factory.predictKernel(predictedWorldDeployer);
        bytes memory hookArgs = abi.encode(
            IPoolManager(POOL_MANAGER),
            SwaputerKernel(predictedKernel),
            predictedToken,
            factory.initialProtocolFeeAdmin(),
            factory.feeController(),
            factory.initialProtocolFeeBps(),
            BYTE_GAS_PRICE,
            POOL_FEE,
            TICK_SPACING
        );
        (address predictedHook, bytes32 hookSalt) = HookMiner.find(
            predictedWorldDeployer,
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG,
            type(SwaputerHook).creationCode,
            hookArgs
        );
        SwaputerWorldFactory.CreateWorldParams memory params = SwaputerWorldFactory.CreateWorldParams({
            tokenSalt: TOKEN_SALT,
            bootstrapSalt: BOOTSTRAP_SALT,
            hookSalt: hookSalt,
            predictedKernel: predictedKernel,
            predictedHook: predictedHook,
            initialSupply: INITIAL_GAS_TOKEN_SUPPLY,
            initialHolder: actor,
            distributionCommitment: DISTRIBUTION_COMMITMENT,
            byteGasPrice: BYTE_GAS_PRICE,
            poolFee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            initialSqrtPriceX96: INITIAL_SQRT_PRICE_X96
        });

        vm.startBroadcast(actorKey);
        (worldId, gasToken, kernel, hook) = factory.createWorld(params);
        vm.stopBroadcast();
        (PoolKey memory key, bool isSealed) = factory.getPoolKey(worldId);
        require(isSealed, "WORLD_NOT_SEALED");
        require(address(key.hooks) == address(hook), "POOL_HOOK");
        require(address(kernel.hook()) == address(hook), "KERNEL_HOOK");
        require(address(hook.kernel()) == address(kernel), "HOOK_KERNEL");
        require(address(hook.poolManager()) == POOL_MANAGER, "HOOK_MANAGER");
    }

    function _bootstrapOfficialLiquidity() private {
        (PoolKey memory key,) = factory.getPoolKey(worldId);
        positionTokenId = POSITION_MANAGER.nextTokenId();
        vm.startBroadcast(actorKey);
        gasToken.approve(address(PERMIT2), MAX_TOKEN);
        PERMIT2.approve(
            address(gasToken), address(POSITION_MANAGER), uint160(MAX_TOKEN), uint48(block.timestamp + 1 hours)
        );
        POSITION_MANAGER.modifyLiquidities{value: MAX_NATIVE}(_mintPlan(key), block.timestamp + 600);
        PERMIT2.approve(address(gasToken), address(POSITION_MANAGER), 0, 0);
        gasToken.approve(address(PERMIT2), 0);
        vm.stopBroadcast();
        require(POSITION_MANAGER.ownerOf(positionTokenId) == actor, "POSITION_OWNER");
        require(POSITION_MANAGER.getPositionLiquidity(positionTokenId) == LIQUIDITY, "POSITION_LIQUIDITY");
    }

    function _deployProgramsAndMarket() private {
        bytes32 actorId = kernel.eoaAccountId(actor);
        bytes memory tokenPackage = vm.readFileBinary("tooling/tinysol/programs/mintable-src20/MintableSRC20.svm");
        tokenCodeHash = keccak256(tokenPackage);
        require(tokenCodeHash == 0xaf15e40fe9fc1181a7143abb413562d69e1ab49a655209ac966204646c85c14b, "MINTABLE_HASH");
        token = kernel.contractAccountId(worldId, actorId, kernel.creatorNonce(worldId, actorId), tokenCodeHash);
        _executeDeploy(tokenCodeHash, abi.encodePacked(bytes4(uint32(tokenPackage.length)), tokenPackage));
        _executeCall(
            token, abi.encodePacked(bytes4(keccak256("mint(bytes32)")), abi.encode(actorId)), TOKEN_LIMIT, actor, actor
        );
        require(_tokenBalance(actorId) == 1_000 ether, "MINT_BALANCE");

        bytes memory escrowPackage = vm.readFileBinary("tooling/tinysol/programs/market-escrow/MarketEscrow.svm");
        escrowCodeHash = keccak256(escrowPackage);
        require(escrowCodeHash == 0x3b7416393025dec94fa6bebae4fad00142468be16dd62784027cb4a4d1eaddb6, "ESCROW_HASH");
        escrow = kernel.contractAccountId(worldId, actorId, kernel.creatorNonce(worldId, actorId), escrowCodeHash);
        address predictedMarket = vm.computeCreateAddress(actor, vm.getNonce(actor) + 1);
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
        SwaputerKernel.VMEnvelope memory transfer = _signedCall(
            token,
            abi.encodePacked(
                bytes4(keccak256("transfer(bytes32,uint256)")), abi.encode(kernel.eoaAccountId(actor), ORDER_AMOUNT)
            ),
            TOKEN_LIMIT,
            actor,
            address(market),
            VM_INPUT
        );
        vm.startBroadcast(actorKey);
        market.fillBuyOrder(buyOrderId, transfer, SQRT_PRICE_LIMIT);
        vm.stopBroadcast();

        _executeCall(
            token,
            abi.encodePacked(bytes4(keccak256("approve(bytes32,uint256)")), abi.encode(escrow, ORDER_AMOUNT)),
            TOKEN_LIMIT,
            actor,
            actor
        );
        SwaputerKernel.VMEnvelope memory deposit = _signedCall(
            escrow,
            abi.encodePacked(
                bytes4(keccak256("deposit(bytes32,uint256)")), abi.encode(kernel.eoaAccountId(actor), ORDER_AMOUNT)
            ),
            ESCROW_LIMIT,
            actor,
            address(market),
            VM_INPUT
        );
        vm.startBroadcast(actorKey);
        uint256 sellOrderId = market.createSellOrder{value: VM_INPUT}(
            ORDER_AMOUNT, UNIT_PRICE, VM_INPUT, expiry, deposit, SQRT_PRICE_LIMIT
        );
        vm.stopBroadcast();
        SwaputerKernel.VMEnvelope memory release = _signedCall(
            escrow,
            abi.encodePacked(
                bytes4(keccak256("release(bytes32,uint256)")), abi.encode(kernel.eoaAccountId(actor), ORDER_AMOUNT)
            ),
            ESCROW_LIMIT,
            actor,
            address(market),
            VM_INPUT
        );
        vm.startBroadcast(actorKey);
        market.settleSellOrder{value: ORDER_PRICE + VM_INPUT}(sellOrderId, release, SQRT_PRICE_LIMIT);
        vm.stopBroadcast();
    }

    function _executeDeploy(bytes32 codeHash, bytes memory payload) private {
        SwaputerKernel.VMEnvelope memory envelope =
            _signed(SwaputerKernel.RootOp.DEPLOY, codeHash, payload, DEPLOY_LIMIT, actor, actor, VM_INPUT);
        vm.startBroadcast(actorKey);
        router.buyVMExactInput{value: VM_INPUT}(worldId, SQRT_PRICE_LIMIT, envelope);
        vm.stopBroadcast();
    }

    function _executeCall(bytes32 target, bytes memory payload, uint32 byteLimit, address recipient, address executor)
        private
    {
        SwaputerKernel.VMEnvelope memory envelope =
            _signed(SwaputerKernel.RootOp.CALL, target, payload, byteLimit, recipient, executor, VM_INPUT);
        vm.startBroadcast(actorKey);
        router.buyVMExactInput{value: VM_INPUT}(worldId, SQRT_PRICE_LIMIT, envelope);
        vm.stopBroadcast();
    }

    function _signedCall(
        bytes32 target,
        bytes memory payload,
        uint32 byteLimit,
        address recipient,
        address executor,
        uint128 ethInput
    ) private view returns (SwaputerKernel.VMEnvelope memory envelope) {
        return _signed(SwaputerKernel.RootOp.CALL, target, payload, byteLimit, recipient, executor, ethInput);
    }

    function _signed(
        SwaputerKernel.RootOp op,
        bytes32 target,
        bytes memory payload,
        uint32 byteLimit,
        address recipient,
        address executor,
        uint128 ethInput
    ) private view returns (SwaputerKernel.VMEnvelope memory envelope) {
        bytes32 actorId = kernel.eoaAccountId(actor);
        envelope = SwaputerKernel.VMEnvelope({
            op: op,
            worldId: worldId,
            actor: actor,
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
                ethInput,
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
            abi.encode(key, TICK_LOWER, TICK_UPPER, uint256(LIQUIDITY), MAX_NATIVE, MAX_TOKEN, actor, bytes(""))
        );
        plan.add(Actions.CLOSE_CURRENCY, abi.encode(key.currency0));
        plan.add(Actions.CLOSE_CURRENCY, abi.encode(key.currency1));
        plan.add(Actions.SWEEP, abi.encode(key.currency0, actor));
        return plan.encode();
    }

    function _validateFinalState() private view {
        require(market.orderCount() == 2, "ORDER_COUNT");
        require(market.lockedEth() == 0, "LOCKED_ETH");
        require(market.escrowedTokenAmount() == 0, "ESCROW_LIABILITY");
        require(market.activeSellAmount(actor) == 0, "ACTIVE_SELL");
        require(address(market).balance == 0, "MARKET_ETH");
        require(_tokenBalance(escrow) == 0, "ESCROW_BALANCE");
        require(_tokenBalance(kernel.eoaAccountId(actor)) == 1_000 ether, "ACTOR_TOKEN_BALANCE");
        (uint160 permitAmount,,) = PERMIT2.allowance(actor, address(gasToken), address(POSITION_MANAGER));
        require(permitAmount == 0, "PERMIT2_ALLOWANCE");
        require(gasToken.allowance(actor, address(PERMIT2)) == 0, "ERC20_ALLOWANCE");
    }

    function _tokenBalance(bytes32 accountId) private view returns (uint256 amount) {
        (bytes memory output,) = kernel.staticCall(
            worldId, token, abi.encodePacked(bytes4(keccak256("balanceOf(bytes32)")), abi.encode(accountId)), 3_000
        );
        require(output.length == 32, "BALANCE_WIDTH");
        amount = abi.decode(output, (uint256));
    }

    function _enforceReleaseCap() private view {
        if (actor.balance < releaseStartBalance) {
            require(releaseStartBalance - actor.balance <= RELEASE_ETH_CAP, "RELEASE_ETH_CAP_EXCEEDED");
        }
    }

    function _logResult() private view {
        console2.log("V12_UNAUDITED_EXPERIMENTAL", true);
        console2.log("V12_FACTORY", address(factory));
        console2.log("V12_ROUTER", address(router));
        console2.log("V12_REGISTRY", address(factory.referenceRegistry()));
        console2.log("V12_GAS_TOKEN", address(gasToken));
        console2.log("V12_KERNEL", address(kernel));
        console2.log("V12_HOOK", address(hook));
        console2.log("V12_POSITION_MANAGER", address(POSITION_MANAGER));
        console2.log("V12_POSITION_TOKEN_ID", positionTokenId);
        console2.log("V12_MARKET", address(market));
        console2.log("V12_WORLD_ID");
        console2.logBytes32(worldId);
        console2.log("V12_MINTABLE_SRC20_ID");
        console2.logBytes32(token);
        console2.log("V12_MINTABLE_SRC20_CODE_HASH");
        console2.logBytes32(tokenCodeHash);
        console2.log("V12_MARKET_ESCROW_ID");
        console2.logBytes32(escrow);
        console2.log("V12_MARKET_ESCROW_CODE_HASH");
        console2.logBytes32(escrowCodeHash);
        console2.log("V12_EXECUTION_HEIGHT", kernel.executionHeight(worldId));
        console2.log("V12_ACTOR_BALANCE_WEI", actor.balance);
    }
}
