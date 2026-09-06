// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {Plan, Planner} from "@uniswap/v4-periphery/test/shared/Planner.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

import {SwapVMGasToken} from "../src/SwapVMGasToken.sol";
import {SwapVMKernel} from "../src/SwapVMKernel.sol";
import {SwapVMRouter} from "../src/SwapVMRouter.sol";
import {SwapVMWorldFactory} from "../src/SwapVMWorldFactory.sol";

interface IPositionManagerMinimal {
    error NotApproved(address caller);

    function poolManager() external view returns (address);
    function permit2() external view returns (address);
    function nextTokenId() external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128);
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
}

interface IPermit2AllowanceMinimal {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;

    function allowance(address owner, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);
}

interface IStateViewMinimal {
    function getPositionInfo(PoolId poolId, address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        external
        view
        returns (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128);
}

/// @notice Replaces the Stage 7D-U2 test-router LP with an official PositionManager ERC-721 position.
/// @dev Base Sepolia-only, zero-value experimental release operation. This is not a production deployer.
contract Stage7DU2PositionManagerScript is Script {
    using Planner for Plan;
    using PoolIdLibrary for PoolKey;

    uint256 private constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    uint256 private constant RELEASE_START_BALANCE = 12_413_260_640_785_848_061;
    uint256 private constant RELEASE_ETH_CAP = 0.5 ether;

    address private constant ACTOR = 0x590a77Ec892bB78206bcad2444B62d1bC31A2D03;
    SwapVMWorldFactory private constant FACTORY = SwapVMWorldFactory(0xF327e35FEA7EE7c92a765D1f00eD6A2A3db5b340);
    SwapVMRouter private constant ROUTER = SwapVMRouter(payable(0xEDAbF849F3F74FE3C92FCEa50968332f77B06F07));
    SwapVMGasToken private constant TOKEN = SwapVMGasToken(0xe7bE2F5Af5281D81394c1ed22a27EDe5fdbb8775);
    SwapVMKernel private constant KERNEL = SwapVMKernel(0xA048C894A738185c24B4A5020Fb6708dAb160283);

    address private constant POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    bytes32 private constant POOL_MANAGER_CODE_HASH =
        0x03c45db6d09b14da7c1f7239a5a49697f976d395277e6d2acb6fbed3f9e0249f;
    IPositionManagerMinimal private constant POSITION_MANAGER =
        IPositionManagerMinimal(0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80);
    bytes32 private constant POSITION_MANAGER_CODE_HASH =
        0xe8329b35b8b34290b6cf03affc0836f7b23205229cc96ffdc66544b93112c076;
    IPermit2AllowanceMinimal private constant PERMIT2 =
        IPermit2AllowanceMinimal(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    IStateViewMinimal private constant STATE_VIEW = IStateViewMinimal(0x571291b572ed32ce6751a2Cb2486EbEe8DEfB9B4);
    PoolModifyLiquidityTest private constant LEGACY_LIQUIDITY_ROUTER =
        PoolModifyLiquidityTest(payable(0x37429cD17Cb1454C34E7F50b09725202Fd533039));

    bytes32 private constant WORLD_ID = 0x9c414214b34b78217698b02c5b1a7af65f6d43c500ed2bd865ea4c54ed4360b9;
    bytes32 private constant LEGACY_LP_SALT = keccak256("Swaputer Stage 7D-U2 Base Sepolia zero-value LP");
    int24 private constant TICK_LOWER = -600;
    int24 private constant TICK_UPPER = 600;
    uint128 private constant LIQUIDITY = 3 ether;
    uint128 private constant MAX_NATIVE = 0.1 ether;
    uint128 private constant MAX_TOKEN = 0.1 ether;
    uint128 private constant NOP_BUY_INPUT = 0.001 ether;
    uint128 private constant SELL_INPUT = 0.0001 ether;

    /// @notice Performs the live Base Sepolia remediation. The private key is supplied only in process memory.
    function run() external {
        _validateRelease();
        uint256 actorKey = vm.envUint("STAGE7A2_PRIVATE_KEY");
        require(vm.addr(actorKey) == ACTOR, "ACTOR_MISMATCH");
        _enforceReleaseCap();

        vm.startBroadcast(actorKey);
        uint256 tokenId = _replaceLiquidityAndExercise();
        vm.stopBroadcast();

        _validateFinalState(tokenId);
        _enforceReleaseCap();
        _logResult(tokenId);
    }

    /// @notice Executes the same flow on a local fork and proves a non-owner cannot decrease the NFT position.
    function forkCheck() external {
        _validateRelease();
        uint256 actorBalance = ACTOR.balance;
        vm.deal(ACTOR, actorBalance + 1 ether);

        vm.startPrank(ACTOR);
        uint256 tokenId = _replaceLiquidityAndExercise();
        vm.stopPrank();
        _validateFinalState(tokenId);

        uint128 beforeLiquidity = POSITION_MANAGER.getPositionLiquidity(tokenId);
        bytes memory decreasePlan = _decreasePlan(tokenId, 1);
        vm.prank(address(0xBADD));
        (bool unauthorizedSucceeded, bytes memory reason) = address(POSITION_MANAGER)
            .call(abi.encodeCall(POSITION_MANAGER.modifyLiquidities, (decreasePlan, block.timestamp + 600)));
        require(!unauthorizedSucceeded, "UNAUTHORIZED_DECREASE_SUCCEEDED");
        require(_selector(reason) == IPositionManagerMinimal.NotApproved.selector, "WRONG_UNAUTHORIZED_ERROR");
        require(POSITION_MANAGER.getPositionLiquidity(tokenId) == beforeLiquidity, "UNAUTHORIZED_CHANGED_LIQUIDITY");

        console2.log("STAGE7D_U2_POSITION_MANAGER_FORK_OK", true);
        console2.log("STAGE7D_U2_UNAUTHORIZED_REJECTED", true);
        _logResult(tokenId);
    }

    function _replaceLiquidityAndExercise() private returns (uint256 tokenId) {
        (PoolKey memory key, bool isSealed) = FACTORY.getPoolKey(WORLD_ID);
        require(isSealed && PoolId.unwrap(key.toId()) == WORLD_ID, "WORLD_NOT_SEALED");

        (uint128 legacyLiquidity,,) = STATE_VIEW.getPositionInfo(
            key.toId(), address(LEGACY_LIQUIDITY_ROUTER), TICK_LOWER, TICK_UPPER, LEGACY_LP_SALT
        );
        require(legacyLiquidity == LIQUIDITY, "LEGACY_LIQUIDITY_MISMATCH");
        LEGACY_LIQUIDITY_ROUTER.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: -int256(uint256(LIQUIDITY)),
                salt: LEGACY_LP_SALT
            }),
            bytes("")
        );
        (legacyLiquidity,,) = STATE_VIEW.getPositionInfo(
            key.toId(), address(LEGACY_LIQUIDITY_ROUTER), TICK_LOWER, TICK_UPPER, LEGACY_LP_SALT
        );
        require(legacyLiquidity == 0, "LEGACY_LIQUIDITY_REMAINS");

        tokenId = POSITION_MANAGER.nextTokenId();
        TOKEN.approve(address(PERMIT2), MAX_TOKEN);
        PERMIT2.approve(
            address(TOKEN), address(POSITION_MANAGER), uint160(MAX_TOKEN), uint48(block.timestamp + 1 hours)
        );
        POSITION_MANAGER.modifyLiquidities{value: MAX_NATIVE}(_mintPlan(key), block.timestamp + 600);

        PERMIT2.approve(address(TOKEN), address(POSITION_MANAGER), 0, 0);
        TOKEN.approve(address(PERMIT2), 0);
        require(TOKEN.allowance(ACTOR, address(PERMIT2)) == 0, "ERC20_PERMIT2_ALLOWANCE_REMAINS");
        (uint160 permitAmount,,) = PERMIT2.allowance(ACTOR, address(TOKEN), address(POSITION_MANAGER));
        require(permitAmount == 0, "PERMIT2_ALLOWANCE_REMAINS");

        uint64 heightBefore = KERNEL.executionHeight(WORLD_ID);
        uint256 supplyBefore = TOKEN.totalSupply();
        ROUTER.buyNOPExactInput{value: NOP_BUY_INPUT}(WORLD_ID, 1, TickMath.MIN_SQRT_PRICE + 1, ACTOR);
        require(KERNEL.executionHeight(WORLD_ID) == heightBefore + 1, "NOP_HEIGHT_MISMATCH");
        require(KERNEL.executedBytes(WORLD_ID) == 1, "NOP_BYTES_MISMATCH");
        require(TOKEN.totalSupply() == supplyBefore - 1_000_000_000_000, "NOP_BURN_MISMATCH");

        TOKEN.approve(address(ROUTER), SELL_INPUT);
        ROUTER.sellExactInput(WORLD_ID, SELL_INPUT, 1, TickMath.MAX_SQRT_PRICE - 1, ACTOR);
        TOKEN.approve(address(ROUTER), 0);
        require(KERNEL.executionHeight(WORLD_ID) == heightBefore + 1, "SELL_EXECUTED_VM");
        require(TOKEN.totalSupply() == supplyBefore - 1_000_000_000_000, "SELL_BURNED_TOKEN");
        require(TOKEN.allowance(ACTOR, address(ROUTER)) == 0, "ROUTER_ALLOWANCE_REMAINS");
    }

    function _mintPlan(PoolKey memory key) private pure returns (bytes memory) {
        Plan memory plan = Planner.init();
        plan.add(
            Actions.MINT_POSITION,
            abi.encode(key, TICK_LOWER, TICK_UPPER, uint256(LIQUIDITY), MAX_NATIVE, MAX_TOKEN, ACTOR, bytes(""))
        );
        plan.add(Actions.CLOSE_CURRENCY, abi.encode(key.currency0));
        plan.add(Actions.CLOSE_CURRENCY, abi.encode(key.currency1));
        plan.add(Actions.SWEEP, abi.encode(key.currency0, ACTOR));
        return plan.encode();
    }

    function _decreasePlan(uint256 tokenId, uint256 liquidity) private pure returns (bytes memory) {
        Plan memory plan = Planner.init();
        plan.add(Actions.DECREASE_LIQUIDITY, abi.encode(tokenId, liquidity, uint128(0), uint128(0), bytes("")));
        plan.add(Actions.TAKE_PAIR, abi.encode(address(0), address(TOKEN), ACTOR));
        return plan.encode();
    }

    function _validateRelease() private view {
        require(block.chainid == BASE_SEPOLIA_CHAIN_ID, "BASE_SEPOLIA_ONLY");
        require(POOL_MANAGER.codehash == POOL_MANAGER_CODE_HASH, "POOL_MANAGER_CODE_HASH_MISMATCH");
        require(address(POSITION_MANAGER).codehash == POSITION_MANAGER_CODE_HASH, "POSITION_MANAGER_CODE_HASH_MISMATCH");
        require(POSITION_MANAGER.poolManager() == POOL_MANAGER, "POSITION_MANAGER_POOL_MANAGER_MISMATCH");
        require(POSITION_MANAGER.permit2() == address(PERMIT2), "POSITION_MANAGER_PERMIT2_MISMATCH");
        require(address(FACTORY.poolManager()) == POOL_MANAGER, "FACTORY_POOL_MANAGER_MISMATCH");
        require(FACTORY.router() == address(ROUTER), "FACTORY_ROUTER_MISMATCH");
    }

    function _validateFinalState(uint256 tokenId) private view {
        require(POSITION_MANAGER.ownerOf(tokenId) == ACTOR, "POSITION_OWNER_MISMATCH");
        require(POSITION_MANAGER.getPositionLiquidity(tokenId) == LIQUIDITY, "POSITION_LIQUIDITY_MISMATCH");
        (PoolKey memory key,) = FACTORY.getPoolKey(WORLD_ID);
        (uint128 managerLiquidity,,) =
            STATE_VIEW.getPositionInfo(key.toId(), address(POSITION_MANAGER), TICK_LOWER, TICK_UPPER, bytes32(tokenId));
        require(managerLiquidity == LIQUIDITY, "POOL_MANAGER_POSITION_MISMATCH");
    }

    function _enforceReleaseCap() private view {
        if (ACTOR.balance < RELEASE_START_BALANCE) {
            require(RELEASE_START_BALANCE - ACTOR.balance <= RELEASE_ETH_CAP, "RELEASE_ETH_CAP_EXCEEDED");
        }
    }

    function _logResult(uint256 tokenId) private view {
        console2.log("STAGE7D_U2_POSITION_MANAGER", address(POSITION_MANAGER));
        console2.log("STAGE7D_U2_POSITION_TOKEN_ID", tokenId);
        console2.log("STAGE7D_U2_POSITION_OWNER", POSITION_MANAGER.ownerOf(tokenId));
        console2.log("STAGE7D_U2_POSITION_LIQUIDITY", POSITION_MANAGER.getPositionLiquidity(tokenId));
        console2.log("STAGE7D_U2_EXECUTION_HEIGHT", KERNEL.executionHeight(WORLD_ID));
        console2.log("STAGE7D_U2_ACTOR_BALANCE_WEI", ACTOR.balance);
        console2.log("STAGE7D_U2_UNAUDITED", true);
    }

    function _selector(bytes memory reason) private pure returns (bytes4 selector) {
        if (reason.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            selector := mload(add(reason, 0x20))
        }
    }
}
