// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Read-only production boundary consumed by the canonical SwapVM Router.
interface ISwaputerWorldFactory {
    function poolManager() external view returns (IPoolManager);

    function router() external view returns (address);

    function getPoolKey(bytes32 worldId) external view returns (PoolKey memory key, bool isSealed);
}
