// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import "./ICLFactory.sol";

/// @notice Permissioned factory extensions; standard pool and gauge APIs remain compatible.
interface ICLPrivateFactory is ICLFactory {
    event WhitelistUpdated(address indexed account, bool allowed);

    /// @notice Whether an immediate caller may create pools, swap, flash, or provide liquidity.
    /// @dev Shared routers/executors must enforce their own upstream caller authorization.
    function isWhitelisted(address account) external view returns (bool);

    /// @notice Owner-only update of an immediate caller's permissions; zero address is rejected.
    function setWhitelist(address account, bool allowed) external;
}
