// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import "./INonfungiblePositionManager.sol";

/// @notice Position manager with factory-whitelisted minters and an optional public minting mode.
interface IPrivateNonFungiblePositionManager is INonfungiblePositionManager {
    event PublicLiquidityUpdated(bool allowed);

    /// @notice Whether anyone may mint positions in existing pools. Initially false.
    /// @dev Pool creation through mint still requires a factory-whitelisted caller.
    function publicLiquidity() external view returns (bool);

    /// @notice Owner-only toggle for minting; existing position management rules remain unchanged.
    function setPublicLiquidity(bool allowed) external;
}
