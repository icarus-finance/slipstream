// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title Permissioned pool actions
/// @notice Contains pool methods that may only be called by the factory owner
interface ICLPoolOwnerActions {
    /// @notice Collect the gauge fee accrued to the pool
    /// @dev Retains one smallest unit per token after a sweep; sentinel-only collection returns zero.
    /// @return amount0 The amount of token0 actually transferred to the gauge
    /// @return amount1 The amount of token1 actually transferred to the gauge
    function collectFees() external returns (uint128 amount0, uint128 amount1);
}
