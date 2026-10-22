// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import "./CLPrivateGauge.t.sol";

contract InitialRewardsCallForwarder {
    function forward(address target, bytes calldata data) external returns (bool success) {
        (success,) = target.call(data);
    }
}
import {ProtocolTimeLibrary} from "contracts/libraries/ProtocolTimeLibrary.sol";

contract CLPrivateGaugeEdgeCasesTest is CLPrivateGaugeFixture {
    function test_TinyQueuedIRSDoesNotBlockActivation_AndIsConsumedOnce() public {
        _queueIRS(1);
        _begin();
        _finish();
        assertEq(uint256(gauge.phase()), uint256(ICLPrivateGauge.Phase.IRS));
        assertEq(gauge.queuedIRS(), 1);
        assertEq(gauge.rewardRate(), 0);
        assertEq(pool.rewardRate(), 0);

        skip(1 days);
        uint256 duration = ProtocolTimeLibrary.epochNext(block.timestamp) - block.timestamp;
        _queueIRS(WEEK);
        assertEq(gauge.queuedIRS(), 0);
        assertEq(pool.rewardReserve(), WEEK + 1);
        assertEq(gauge.rewardRate(), (WEEK + 1) / duration);
        assertEq(rewardToken.balanceOf(address(gauge)), WEEK + 1);

        uint256 remainingSchedule = gauge.rewardRate() * duration;
        _queueIRS(WEEK);
        assertEq(gauge.queuedIRS(), 0);
        assertEq(pool.rewardReserve(), remainingSchedule + WEEK);
        assertEq(rewardToken.balanceOf(address(gauge)), WEEK * 2 + 1);
    }

    function test_InitialPoolTokenRefundPreservesRealFeeBalance() public {
        uint256 id = _stake(users.alice, -100, 100, 1e18);
        deal(address(token0), users.owner, CAMPAIGN * 2);
        vm.startPrank(users.owner);
        token0.approve(address(gauge), type(uint256).max);
        gauge.configureInitialRewards(address(token0), users.owner);
        gauge.notifyInitialRewards(CAMPAIGN);
        vm.stopPrank();
        skip(1 days);

        // Flash donations accrue actual gauge fees without requiring a nonzero swap fee.
        vm.prank(users.alice);
        clCallee.flash(address(pool), users.alice, 0, 0, 1000, 0);
        _queueIRS(1); // Voter funding also collects the pool's gauge fees.
        assertEq(gauge.fees0(), 999, "pool retains its one-unit sentinel");
        uint256 feeBalance = gauge.fees0();

        _begin();
        gauge.checkpointTransition(_one(id));
        uint256 refundable = gauge.unusedInitialRewards();
        assertEq(refundable, CAMPAIGN - gauge.totalInitialRewardsPaid());
        gauge.recoverUnusedInitialRewards();
        assertEq(token0.balanceOf(address(gauge)), feeBalance);
        assertEq(gauge.fees0(), feeBalance);
        assertEq(
            gauge.totalInitialRewardsFunded(), gauge.totalInitialRewardsPaid() + gauge.totalInitialRewardsRefunded()
        );
        _finish();
        assertEq(token0.balanceOf(address(gauge)), feeBalance);
    }

    function test_ClearedAndReinitializedTicksDoNotChangePendingEntitlement() public {
        uint256 a = _stake(users.alice, -100, 100, 1e18);
        uint256 b = _stake(users.bob, -200, 200, 1e18);
        _configure();
        _fund(CAMPAIGN);
        skip(1 days);
        _begin();
        uint256 owedB = gauge.earnedInitialRewards(users.bob, b);

        vm.prank(users.alice);
        gauge.withdraw(a);
        (,,,,,,, uint128 liquidity,,,,) = privateNft.positions(a);
        vm.prank(users.alice);
        privateNft.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: a, liquidity: liquidity, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
            })
        );
        (,,,,,,,,, bool lowerInitialized) = pool.ticks(-100);
        (,,,,,,,,, bool upperInitialized) = pool.ticks(100);
        assertFalse(lowerInitialized);
        assertFalse(upperInitialized);

        // Stress the frozen counter even if minting is resumed before settlement completes.
        uint256 fresh = _mint(users.charlie, -100, 100, 1e18);
        (,,,,,,,,, lowerInitialized) = pool.ticks(-100);
        (,,,,,,,,, upperInitialized) = pool.ticks(100);
        assertTrue(lowerInitialized);
        assertTrue(upperInitialized);
        vm.prank(users.charlie);
        vm.expectRevert(bytes("TRANSITION"));
        gauge.deposit(fresh);
        vm.prank(users.alice);
        clCallee.swapToHigherSqrtPrice(address(pool), TickMath.getSqrtRatioAtTick(150), users.alice);
        skip(1 hours);
        assertEq(gauge.earnedInitialRewards(users.bob, b), owedB);
        gauge.checkpointTransition(_one(b));
        assertEq(initialToken.balanceOf(users.bob), owedB);
        assertEq(gauge.pendingPositions(), 0);
        _finish();
        _assertSettledConservation();
    }

    function test_RecipientDepositRequiresWhitelist_AndGivesRecipientRights() public {
        uint256 id = _mint(users.alice, -100, 100, 1e18);
        vm.prank(users.alice);
        vm.expectRevert(bytes("NW"));
        gauge.deposit(id, users.bob);
        vm.prank(users.owner);
        privateGaugeFactory.setWhitelisted(users.alice, true);
        vm.prank(users.alice);
        gauge.deposit(id, users.bob);
        assertEq(gauge.stakerOf(id), users.bob);
        assertTrue(gauge.stakedContains(users.bob, id));
        assertFalse(gauge.stakedContains(users.alice, id));

        _configure();
        _fund(CAMPAIGN);
        skip(1 days);
        vm.startPrank(users.alice);
        vm.expectRevert(bytes("NA"));
        gauge.claimInitialRewards(_one(id));
        vm.expectRevert(bytes("NA"));
        gauge.withdraw(id);
        vm.stopPrank();
        vm.prank(users.bob);
        gauge.claimInitialRewards(_one(id));
        assertGt(initialToken.balanceOf(users.bob), 0);
        assertEq(initialToken.balanceOf(users.alice), 0);
        vm.prank(users.bob);
        gauge.withdraw(id);
        assertEq(privateNft.ownerOf(id), users.bob);
    }

    function test_KilledGaugeExitRetainsInitialCredit_AndAllowsTransition() public {
        uint256 id = _stake(users.alice, -100, 100, 1e18);
        uint256 newId = _mint(users.bob, -100, 100, 1e18);
        _configure();
        _fund(CAMPAIGN);
        skip(1 days);
        vm.prank(users.owner);
        voter.killGauge(address(gauge));
        vm.prank(users.bob);
        vm.expectRevert(bytes("GK"));
        gauge.deposit(newId);
        vm.prank(users.alice);
        gauge.withdraw(id);
        assertEq(privateNft.ownerOf(id), users.alice);
        uint256 owed = gauge.initialRewardCredits(users.alice);
        assertGt(owed, 0);
        assertEq(gauge.pendingPositions(), 0);

        _begin();
        gauge.recoverUnusedInitialRewards();
        assertEq(initialToken.balanceOf(address(gauge)), owed);
        _finish();
        vm.prank(users.alice);
        gauge.claimInitialRewards(new uint256[](0));
        assertEq(initialToken.balanceOf(users.alice), owed);
        _assertSettledConservation();
    }

    function test_FailedFundingRollsBackPoolCheckpointAndFundingAccounting() public {
        _stake(users.alice, -100, 100, 1e18);
        _configure();
        _fund(CAMPAIGN);
        uint256 reserve = pool.rewardReserve();
        uint256 lastUpdated = pool.lastUpdated();
        uint256 rate = pool.rewardRate();
        uint256 funderBalance = initialToken.balanceOf(users.owner);
        skip(1 hours);
        vm.startPrank(users.owner);
        initialToken.approve(address(gauge), 0);
        vm.expectRevert();
        gauge.notifyInitialRewards(CAMPAIGN);
        vm.stopPrank();
        assertEq(pool.rewardReserve(), reserve);
        assertEq(pool.lastUpdated(), lastUpdated);
        assertEq(pool.rewardRate(), rate);
        assertEq(gauge.totalInitialRewardsFunded(), CAMPAIGN);
        assertEq(initialToken.balanceOf(address(gauge)), CAMPAIGN);
        assertEq(initialToken.balanceOf(users.owner), funderBalance);
    }

    function test_IncompleteNamedTransitionRollsBackStopAndPayout() public {
        uint256 id = _stake(users.alice, -100, 100, 1e18);
        _stake(users.bob, -100, 100, 1e18);
        _configure();
        _fund(CAMPAIGN);
        uint256 reserve = pool.rewardReserve();
        uint256 funderBalance = initialToken.balanceOf(users.owner);
        skip(1 days);
        vm.prank(users.owner);
        vm.expectRevert();
        gauge.transitionToIRS(_one(id));
        assertEq(uint256(gauge.phase()), uint256(ICLPrivateGauge.Phase.Initial));
        assertEq(gauge.pendingPositions(), 2);
        assertEq(pool.rewardReserve(), reserve);
        assertEq(pool.rewardRate(), gauge.initialRewardRate());
        assertEq(gauge.totalInitialRewardsPaid(), 0);
        assertEq(gauge.totalInitialRewardsCredits(), 0);
        assertEq(gauge.totalInitialRewardsRefunded(), 0);
        assertEq(initialToken.balanceOf(users.alice), 0);
        assertEq(initialToken.balanceOf(users.owner), funderBalance);
        assertEq(initialToken.balanceOf(address(gauge)), CAMPAIGN);
    }

    function test_ExternalCallerCannotUseIsolatedTransferHelper() public {
        _configure();
        _fund(CAMPAIGN);
        vm.expectRevert(bytes("SELF"));
        gauge.transferInitialRewards(users.alice, 1);
        assertEq(initialToken.balanceOf(address(gauge)), CAMPAIGN);
        assertEq(initialToken.balanceOf(users.alice), 0);
    }

    function test_OrdinaryCallAggregatorCannotBorrowTeamAuthorization() public {
        InitialRewardsCallForwarder forwarder = new InitialRewardsCallForwarder();
        vm.prank(users.owner);
        bool success =
            forwarder.forward(address(gauge), abi.encodeWithSelector(gauge.transitionToIRS.selector, new uint256[](0)));
        assertFalse(success);
        assertEq(uint256(gauge.phase()), uint256(ICLPrivateGauge.Phase.AwaitingInitial));
        vm.prank(users.owner);
        gauge.transitionToIRS(new uint256[](0));
        assertEq(uint256(gauge.phase()), uint256(ICLPrivateGauge.Phase.IRS));
    }
}
