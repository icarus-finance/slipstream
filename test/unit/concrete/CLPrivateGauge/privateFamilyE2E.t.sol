// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import "./CLPrivateGauge.t.sol";

/// @dev Real private factory, pool, NFT manager and gauge. The shared fixture's
///      mock Voter funds IRS; real production-Voter distribution is covered separately.
contract CLPrivateFamilyE2ETest is CLPrivateGaugeFixture {
    function _exitAndBurn(address account, uint256 id) private {
        vm.startPrank(account);
        gauge.withdraw(id);
        assertEq(privateNft.ownerOf(id), account);
        (,,,,,,, uint128 liquidity,,,,) = privateNft.positions(id);
        privateNft.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: id, liquidity: liquidity, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
            })
        );
        (uint256 amount0, uint256 amount1) = privateNft.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: id, recipient: account, amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
        );
        assertGt(amount0 + amount1, 0);
        privateNft.burn(id);
        vm.stopPrank();
        vm.expectRevert();
        privateNft.ownerOf(id);
    }

    function test_E2E_ExecutorRevocationAtomicTransitionIrsCrossingAndFullExit() public {
        // Unstaked background liquidity keeps the swap path funded between ranges.
        _mint(users.charlie, -1000, 1000, 10e18);
        uint256 alice = _stake(users.alice, -100, 100, 1e18);
        uint256 bob = _stake(users.bob, 100, 300, 1e18);
        _configure();
        _fund(CAMPAIGN);
        skip(1 hours);
        vm.prank(users.alice);
        clCallee.swapToHigherSqrtPrice(address(pool), TickMath.getSqrtRatioAtTick(200), users.alice);
        skip(2 hours);
        uint256 earnedAlice = gauge.earnedInitialRewards(users.alice, alice);
        uint256 earnedBob = gauge.earnedInitialRewards(users.bob, bob);
        assertApproxEqAbs(earnedAlice, 1 hours * 1e18, 2);
        assertApproxEqAbs(earnedBob, 2 hours * 1e18, 2);

        // Revoke both independent permissions: mint manager and swap executor.
        // Neither permission is needed to settle the gauge's rewards or change its phase.
        vm.startPrank(users.owner);
        privateFactory.setWhitelist(address(privateNft), false);
        privateFactory.setWhitelist(address(clCallee), false);
        vm.stopPrank();
        vm.prank(users.alice);
        vm.expectRevert(bytes("NW"));
        clCallee.swapToLowerSqrtPrice(address(pool), TickMath.getSqrtRatioAtTick(0), users.alice);
        assertEq(gauge.earnedInitialRewards(users.alice, alice), earnedAlice);
        assertEq(gauge.earnedInitialRewards(users.bob, bob), earnedBob);

        _queueIRS(CAMPAIGN);
        uint256[] memory ids = new uint256[](2);
        ids[0] = alice;
        ids[1] = bob;
        vm.prank(users.owner);
        gauge.transitionToIRS(ids);
        assertEq(uint256(gauge.phase()), uint256(ICLPrivateGauge.Phase.IRS));
        assertEq(gauge.pendingPositions(), 0);
        assertEq(gauge.queuedIRS(), 0);
        assertEq(initialToken.balanceOf(users.alice), earnedAlice);
        assertEq(initialToken.balanceOf(users.bob), earnedBob);
        assertEq(privateNft.ownerOf(alice), address(gauge));
        assertEq(privateNft.ownerOf(bob), address(gauge));
        assertEq(gauge.earned(users.alice, alice), 0);
        assertEq(gauge.earned(users.bob, bob), 0);
        uint256 initialGrowth = pool.rewardGrowthGlobalX128();
        assertGt(initialGrowth, 0);
        uint256 rate = gauge.rewardRate();
        assertGt(rate, 0);
        uint256 refund = gauge.recoverUnusedInitialRewards();
        assertGt(refund, 0);
        _assertSettledConservation();
        assertEq(initialToken.balanceOf(address(gauge)), 0);

        // First IRS interval belongs only to Bob's range. Revoked trading does not
        // stop time-based rewards or give Alice retroactive entitlement.
        skip(2 hours);
        assertEq(gauge.earned(users.alice, alice), 0);
        uint256 bobIRS = gauge.earned(users.bob, bob);
        assertApproxEqAbs(bobIRS, rate * 2 hours, 2);
        vm.prank(users.bob);
        gauge.getReward(bob);
        assertEq(rewardToken.balanceOf(users.bob), bobIRS);
        vm.prank(users.alice);
        vm.expectRevert(bytes("NW"));
        clCallee.swapToLowerSqrtPrice(address(pool), TickMath.getSqrtRatioAtTick(0), users.alice);

        // Restore trading while manager minting is still paused; a live IRS tick
        // crossing must move reward attribution without reviving initial rewards.
        vm.prank(users.owner);
        privateFactory.setWhitelist(address(clCallee), true);
        vm.prank(users.alice);
        clCallee.swapToLowerSqrtPrice(address(pool), TickMath.getSqrtRatioAtTick(0), users.alice);
        skip(1 hours);
        uint256 aliceIRS = gauge.earned(users.alice, alice);
        assertApproxEqAbs(aliceIRS, rate * 1 hours, 2);
        assertEq(gauge.earned(users.bob, bob), 0);
        vm.prank(users.alice);
        gauge.getReward(alice);
        assertEq(rewardToken.balanceOf(users.alice), aliceIRS);
        assertGt(pool.rewardGrowthGlobalX128(), initialGrowth);
        assertEq(gauge.earnedInitialRewards(users.alice, alice), 0);
        assertEq(gauge.earnedInitialRewards(users.bob, bob), 0);
        assertEq(initialToken.balanceOf(users.alice), earnedAlice);
        assertEq(initialToken.balanceOf(users.bob), earnedBob);

        // An operational mint pause must not trap either NFT or its underlying LP funds.
        assertFalse(privateFactory.isWhitelisted(address(privateNft)));
        _exitAndBurn(users.alice, alice);
        _exitAndBurn(users.bob, bob);
        assertEq(uint256(pool.stakedLiquidity()), 0);
        assertEq(gauge.stakedLength(users.alice), 0);
        assertEq(gauge.stakedLength(users.bob), 0);
        assertEq(gauge.totalInitialRewardsCredits(), 0);
        _assertSettledConservation();
        vm.prank(users.owner);
        privateFactory.setWhitelist(address(privateNft), true);
        uint256 resumed = _mint(users.alice, -100, 100, 1e18);
        assertEq(privateNft.ownerOf(resumed), users.alice);
    }
}
