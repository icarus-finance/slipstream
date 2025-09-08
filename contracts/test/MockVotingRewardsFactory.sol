// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;

import {IVotingRewardsFactory} from "./interfaces/IVotingRewardsFactory.sol";
import {MockFeesVotingReward} from "./MockFeesVotingReward.sol";
import {MockBribeVotingReward} from "./MockBribeVotingReward.sol";

/// @dev stub, unused in tests
///      see fork tests for more rigorous integration testing including voting rewards
contract MockVotingRewardsFactory is IVotingRewardsFactory {
    /// @inheritdoc IVotingRewardsFactory
    function createRewards(
        address, // _forwarder
        address[] memory // _rewards
    ) external override returns (address feesVotingReward, address bribeVotingReward) {
        feesVotingReward = address(new MockFeesVotingReward());
        bribeVotingReward = address(new MockBribeVotingReward());
    }
}
