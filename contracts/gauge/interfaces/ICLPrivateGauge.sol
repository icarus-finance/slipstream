// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;
pragma abicoder v2;

import {ICLGauge} from "./ICLGauge.sol";

/// @notice A prefunded initial rewards campaign followed permanently by ordinary IRS emissions.
interface ICLPrivateGauge is ICLGauge {
    enum Phase {
        AwaitingInitial,
        Initial,
        Transition,
        IRS
    }

    event InitialRewardsConfigured(address indexed token, address indexed funder);
    event NotifyInitialRewards(address indexed funder, uint256 amount, uint256 rate, uint256 finish);
    event InitialRewardsCredited(address indexed account, uint256 indexed tokenId, uint256 amount);
    event ClaimInitialRewards(address indexed account, uint256 amount);
    event InitialRewardsPayoutFailed(address indexed account, uint256 amount);
    event IrsTransitionStarted(uint256 timestamp, uint256 pendingPositions);
    event TransitionCheckpointed(uint256 indexed tokenId, address indexed account, uint256 amount);
    event IrsTransitionFinished(uint256 queuedAmount);
    event InitialRewardsRefunded(address indexed funder, uint256 amount);
    event IrsQueued(address indexed from, uint256 amount);

    function phase() external view returns (Phase);
    function initialRewardToken() external view returns (address);
    function initialRewardFunder() external view returns (address);
    function initialRewardRate() external view returns (uint256);
    function initialPeriodFinish() external view returns (uint256);
    function initialRewardDust() external view returns (uint256);
    function stoppedInitialRewardReserve() external view returns (uint256);
    function stoppedInitialRewardRollover() external view returns (uint256);
    function queuedIRS() external view returns (uint256);
    function stakerOf(uint256 tokenId) external view returns (address);
    function initialRewardCredits(address account) external view returns (uint256);
    function totalInitialRewardsFunded() external view returns (uint256);
    function totalInitialRewardsPaid() external view returns (uint256);
    function totalInitialRewardsCredits() external view returns (uint256);
    function totalInitialRewardsRefunded() external view returns (uint256);

    /// @notice Team configures the campaign token and its sole funding/refund wallet once.
    function configureInitialRewards(address token, address funder) external;
    /// @notice Funder adds prefunded initial rewards, streaming until the next weekly boundary.
    function notifyInitialRewards(uint256 amount) external;
    /// @notice Uncheckpointed initial rewards for a currently staked position, excluding account credits.
    function earnedInitialRewards(address account, uint256 tokenId) external view returns (uint256);
    /// @notice Checkpoint caller-owned positions and attempt payment of all caller credits.
    /// @dev An empty array retries previously credited rewards; failed payouts preserve credits.
    function claimInitialRewards(uint256[] calldata tokenIds) external;
    /// @notice Team freezes initial rewards immediately and blocks new deposits.
    function beginIrsTransition() external;
    /// @notice Permissionless bounded checkpoint and best-effort payout; duplicates are ignored.
    function checkpointTransition(uint256[] calldata tokenIds) external;
    /// @notice Team starts IRS after every remaining position has a fresh counter baseline.
    function finishIrsTransition() external;
    /// @notice Active campaign positions; during Transition, only those still pending.
    function pendingPositions() external view returns (uint256);
    /// @notice Bounded unordered page. Refetch after mutations because removal swaps entries.
    function pendingTokenIds(uint256 offset, uint256 limit) external view returns (uint256[] memory);
    /// @notice Refundable funded initial rewards after all transition checkpoints, excluding user credits.
    function unusedInitialRewards() external view returns (uint256);
    /// @notice Permissionlessly return unused campaign funding only to the fixed funding wallet.
    function recoverUnusedInitialRewards() external returns (uint256);
    /// @notice Team stops initial rewards, checkpoints the supplied positions, and starts IRS atomically.
    /// @dev Reverts the entire transition if any pending position is omitted. Best-effort payouts preserve credits.
    ///      For larger gauges, use beginIrsTransition, bounded checkpointTransition batches, then finishIrsTransition.
    function transitionToIRS(uint256[] calldata tokenIds) external;
}
