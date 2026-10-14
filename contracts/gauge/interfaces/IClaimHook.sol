// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;

/// @notice Optional reward callback registered globally by the team on Voter.
interface IClaimHook {
    /// @notice Called after a nonzero IRS claim has settled.
    /// @dev Authenticate msg.sender == gauge and verify that gauge is authorized.
    ///      Hook reverts are ignored; settled rewards and escrow changes persist.
    /// @param tokenId Resulting veNFT id, or zero for a liquid claim.
    /// @param amountLocked IRS deposited into escrow, or zero for a liquid claim.
    /// @param account User whose rewards were claimed.
    /// @param gauge Gauge invoking the callback.
    function onClaim(uint256 tokenId, uint256 amountLocked, address account, address gauge) external;
}
