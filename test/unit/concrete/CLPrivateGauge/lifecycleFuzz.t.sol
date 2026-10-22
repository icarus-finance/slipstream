// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import "./CLPrivateGauge.t.sol";

/// @dev Independent inputs: funding amounts, elapsed time, NFT liquidity and known
/// ranges. No gauge/pool reward counters or unusedInitialRewards() feed the oracle.
contract CLPrivateGaugeLifecycleFuzzTest is CLPrivateGaugeFixture {
    struct Schedule {
        uint256 rate;
        uint256 reserve;
        uint256 rollover;
        uint256 dust;
        uint256 finish;
    }

    address[3] private actors;
    uint256[3] private ids;
    uint128[3] private liquidity;
    bool[3] private deposited;
    bool[3] private pending;
    uint256[3] private initialGrowth;
    uint256[3] private irsGrowth;
    uint256[3] private credits;
    uint256[3] private paid;
    uint256[3] private irsPaid;
    Schedule private initialSchedule;
    Schedule private irsSchedule;
    uint256 private funded;
    uint256 private refunded;
    uint256 private donated;
    uint256 private irsFunded;
    uint256 private queued;
    uint256 private funderStart;
    uint256 private stage; // 0: initial, 1: frozen transition, 2: IRS
    bool private highTick;
    bool private blocked;

    function _initializeSequence(uint256 seed) private {
        actors = [users.alice, users.bob, users.charlie];
        funderStart = initialToken.balanceOf(users.owner);
        _mint(users.owner, -1000, 1000, 10e18); // Always retain swappable background liquidity.
        for (uint256 i; i < 3; ++i) {
            int24 lower = i == 1 ? int24(100) : int24(-100);
            int24 upper = i == 0 ? int24(100) : int24(300);
            ids[i] = _stake(actors[i], lower, upper, 1e16 + uint256(keccak256(abi.encode(seed, i))) % 10e18);
            (,,,,,,, liquidity[i],,,,) = privateNft.positions(ids[i]);
            deposited[i] = true;
            pending[i] = true;
        }
        _configure();
        _topUp(CAMPAIGN + seed % 1e24);
    }

    function _active(uint256 i) private view returns (bool) {
        return deposited[i] && (i == 2 || (highTick ? i == 1 : i == 0));
    }

    function _activeLiquidity() private view returns (uint256 total) {
        for (uint256 i; i < 3; ++i) {
            if (_active(i)) total += liquidity[i];
        }
    }

    function _cross() private {
        vm.prank(users.alice);
        if (highTick) {
            clCallee.swapToLowerSqrtPrice(address(pool), TickMath.getSqrtRatioAtTick(0), users.alice);
        } else {
            clCallee.swapToHigherSqrtPrice(address(pool), TickMath.getSqrtRatioAtTick(200), users.alice);
        }
        highTick = !highTick;
    }

    function _advance(uint256 elapsed) private {
        uint256 activeLiquidity = _activeLiquidity();
        if (stage != 1) {
            Schedule storage schedule = stage == 0 ? initialSchedule : irsSchedule;
            uint256 emitted = schedule.rate * elapsed;
            if (emitted > schedule.reserve) emitted = schedule.reserve;
            schedule.reserve -= emitted;
            if (activeLiquidity == 0) {
                schedule.rollover += emitted;
            } else {
                uint256 growth = FullMath.mulDiv(emitted, Q128, activeLiquidity);
                for (uint256 i; i < 3; ++i) {
                    if (_active(i)) {
                        if (stage == 0) initialGrowth[i] += growth;
                        else irsGrowth[i] += growth;
                    }
                }
            }
        }
        skip(elapsed);
        // A real authorized crossing checkpoints pool growth at each modeled time
        // boundary. No gauge impersonation or privileged direct pool writes.
        // This also fixes the reference model's Q128 rounding boundaries exactly.
        _cross();
        _assertBacking();
    }

    function _topUp(uint256 amount) private {
        uint256 budget = amount + initialSchedule.reserve + initialSchedule.rollover + initialSchedule.dust;
        uint256 duration = WEEK - block.timestamp % WEEK;
        initialSchedule.rate = budget / duration;
        initialSchedule.reserve = initialSchedule.rate * duration;
        initialSchedule.rollover = 0;
        initialSchedule.dust = budget - initialSchedule.reserve;
        initialSchedule.finish = block.timestamp + duration;
        funded += amount;
        _fund(amount);
        _assertBacking();
    }

    function _fundIRS(uint256 amount) private {
        irsFunded += amount;
        if (stage != 2) queued += amount;
        else _scheduleIRS(amount);
        _queueIRS(amount);
        _assertBacking();
    }

    function _scheduleIRS(uint256 amount) private {
        uint256 duration = WEEK - block.timestamp % WEEK;
        uint256 budget = amount + irsSchedule.rollover;
        if (block.timestamp < irsSchedule.finish) budget += duration * irsSchedule.rate;
        irsSchedule.rate = budget / duration;
        irsSchedule.reserve = budget; // Existing IRS scheduling includes its division remainder.
        irsSchedule.rollover = 0;
        irsSchedule.finish = block.timestamp + duration;
    }

    function _setBlocked(bool value) private {
        blocked = value;
        // Move then return false: a failed isolated payout must roll back token writes too.
        initialToken.configureFailure(value ? actors[2] : address(0), value ? 3 : 0);
        _assertBacking();
    }

    function _checkpointInitial(uint256 i) private {
        credits[i] += FullMath.mulDiv(initialGrowth[i], liquidity[i], Q128);
        initialGrowth[i] = 0;
        if (stage == 1) pending[i] = false;
    }

    function _payInitial(uint256 i) private {
        if (i == 2 && blocked) return;
        paid[i] += credits[i];
        credits[i] = 0;
    }

    function _claimInitial(uint256 i, bool empty) private {
        if (!empty && pending[i] && stage != 2) _checkpointInitial(i);
        _payInitial(i);
        vm.prank(actors[i]);
        gauge.claimInitialRewards(empty ? new uint256[](0) : _one(ids[i]));
        _assertBacking();
    }

    function _claimIRS(uint256 i) private {
        irsPaid[i] += FullMath.mulDiv(irsGrowth[i], liquidity[i], Q128);
        irsGrowth[i] = 0;
        vm.prank(actors[i]);
        gauge.getReward(ids[i]);
        _assertBacking();
    }

    function _toggleStake(uint256 i) private {
        if (deposited[i]) {
            if (stage == 2) {
                irsPaid[i] += FullMath.mulDiv(irsGrowth[i], liquidity[i], Q128);
                irsGrowth[i] = 0;
            } else {
                _checkpointInitial(i);
            }
            pending[i] = false;
            deposited[i] = false;
            vm.prank(actors[i]);
            gauge.withdraw(ids[i]);
        } else {
            deposited[i] = true;
            pending[i] = stage == 0;
            vm.startPrank(actors[i]);
            privateNft.approve(address(gauge), ids[i]);
            gauge.deposit(ids[i]);
            vm.stopPrank();
        }
        _assertBacking();
    }

    function _batch(uint256 first, uint256 random) private {
        uint256 length = 1 + random % 4;
        uint256[] memory batch = new uint256[](length);
        for (uint256 j; j < length; ++j) {
            uint256 i = (first + j) % 3;
            if (j == length - 1 && random % 2 == 0) i = first;
            batch[j] = ids[i];
            if (pending[i]) {
                _checkpointInitial(i);
                _payInitial(i);
            }
        }
        // Permissionless caller; payments must still go to the recorded staker.
        vm.prank(users.owner);
        gauge.checkpointTransition(batch);
        _assertBacking();
    }

    function _refund() private {
        uint256 expected = funded - refunded;
        for (uint256 i; i < 3; ++i) {
            expected -= paid[i] + credits[i];
        }
        uint256 beforeBalance = initialToken.balanceOf(users.owner);
        uint256 actual = gauge.recoverUnusedInitialRewards();
        assertEq(actual, expected, "refund vs independent liabilities");
        assertEq(initialToken.balanceOf(users.owner) - beforeBalance, expected, "refund wallet delta");
        refunded += actual;
        _assertBacking();
        uint256 backing = donated;
        for (uint256 i; i < 3; ++i) {
            backing += credits[i];
        }
        assertEq(initialToken.balanceOf(address(gauge)), backing, "refund retains all credit backing and donations");
    }

    function _assertBacking() private {
        uint256 totalPaid;
        uint256 totalCredits;
        uint256 initialLiability;
        uint256 irsLiability;
        uint256 totalIRSPaid;
        uint256 pendingCount;
        for (uint256 i; i < 3; ++i) {
            uint256 uncheckpointed = FullMath.mulDiv(initialGrowth[i], liquidity[i], Q128);
            uint256 earnedIRS = FullMath.mulDiv(irsGrowth[i], liquidity[i], Q128);
            assertEq(initialToken.balanceOf(actors[i]), paid[i], "initial recipient vs independent earnings");
            assertEq(gauge.initialRewardCredits(actors[i]), credits[i], "credits vs independent earnings");
            assertEq(rewardToken.balanceOf(actors[i]), irsPaid[i], "IRS recipient vs independent earnings");
            if (deposited[i]) {
                assertEq(gauge.earnedInitialRewards(actors[i], ids[i]), uncheckpointed, "initial range/time oracle");
                assertEq(gauge.earned(actors[i], ids[i]), earnedIRS, "IRS range/time oracle");
            }
            assertEq(privateNft.ownerOf(ids[i]), deposited[i] ? address(gauge) : actors[i], "custody");
            assertEq(gauge.stakerOf(ids[i]), deposited[i] ? actors[i] : address(0), "recorded staker");
            assertEq(gauge.stakedContains(actors[i], ids[i]), deposited[i], "recorded deposit");
            if (pending[i]) ++pendingCount;
            totalPaid += paid[i];
            totalCredits += credits[i];
            initialLiability += credits[i] + uncheckpointed;
            irsLiability += earnedIRS;
            totalIRSPaid += irsPaid[i];
        }
        uint256 cash = initialToken.balanceOf(address(gauge));
        assertEq(gauge.pendingPositions(), pendingCount, "pending settlement set");
        assertEq(cash + totalPaid + refunded, funded + donated, "actual initial token conservation");
        assertEq(initialToken.balanceOf(users.owner), funderStart - funded + refunded, "funder cash ledger");
        assertGe(cash, initialLiability + donated, "independent initial liabilities backed");
        if (stage == 0) {
            assertGe(
                cash,
                initialLiability + donated + initialSchedule.reserve + initialSchedule.rollover + initialSchedule.dust,
                "earned and future initial rewards backed"
            );
        }
        assertEq(gauge.totalInitialRewardsFunded(), funded, "funded counter vs funding inputs");
        assertEq(gauge.totalInitialRewardsPaid(), totalPaid, "paid counter vs recipient balances");
        assertEq(gauge.totalInitialRewardsCredits(), totalCredits, "credit aggregation");
        assertEq(gauge.totalInitialRewardsRefunded(), refunded, "refund counter vs wallet deltas");
        assertEq(rewardToken.balanceOf(address(gauge)) + totalIRSPaid, irsFunded, "actual IRS conservation");
        assertGe(
            rewardToken.balanceOf(address(gauge)),
            irsLiability + queued + irsSchedule.reserve + irsSchedule.rollover,
            "independent IRS liabilities backed"
        );
        assertEq(uint256(pool.stakedLiquidity()), _activeLiquidity(), "reference active liquidity");
    }

    function _initialAction(uint256 random) private {
        uint256 action = random % 8;
        uint256 i = (random >> 8) % 3;
        if (action == 0) {
            _topUp(1e18 + (random >> 16) % 1e24);
        } else if (action == 1) {
            _claimInitial(i, !deposited[i]);
        } else if (action == 2) {
            _toggleStake(i);
        } else if (action == 3) {
            _cross();
            _assertBacking();
        } else if (action == 4) {
            _setBlocked(!blocked);
        } else if (action == 5) {
            _fundIRS(1e18 + (random >> 16) % 1e24);
        } else if (action == 6) {
            uint256 amount = 1 + (random >> 16) % 1e20;
            donated += amount;
            initialToken.mint(address(gauge), amount);
            _assertBacking();
        } else {
            _claimInitial(i, true);
        }
    }

    function testFuzz_RandomizedLifecycleBacksEveryLiability(uint256 seed, uint8 rawSteps) public {
        _initializeSequence(seed);
        _advance(1 hours + seed % 1 days);
        _claimInitial(0, false); // Required successful payout, independently calculated.
        _setBlocked(true);
        _claimInitial(2, false);
        assertGt(credits[2], 0, "required blocked payout");
        _topUp(1e18 + seed % 1e24);
        _toggleStake(2);
        _toggleStake(2); // Credits survive an actual withdrawal/restake.
        uint256 steps = bound(uint256(rawSteps), 8, 32);
        for (uint256 step; step < steps; ++step) {
            uint256 random = uint256(keccak256(abi.encode(seed, step)));
            _advance((random >> 32) % 2 days);
            _initialAction(random);
        }
        if (!deposited[2]) _toggleStake(2);
        uint256 remaining = WEEK - block.timestamp % WEEK;
        if (remaining <= 2 hours) _advance(remaining);
        _topUp(CAMPAIGN); // Ensure stop has a live, refundable schedule in every run.
        _setBlocked(true);
        _advance(1 hours + seed % 1 hours);
        _claimInitial(2, false);
        _fundIRS(CAMPAIGN);
        vm.prank(users.owner);
        privateFactory.setWhitelist(address(privateNft), false);
        _begin();
        stage = 1;
        _assertBacking();
        // Settlement spread over randomized pauses, including epoch boundaries.
        for (uint256 step; step < 3; ++step) {
            uint256 random = uint256(keccak256(abi.encode(seed, "transition", step)));
            _advance(random % 9 days);
            uint256 i = (seed % 3 + step) % 3;
            if (deposited[i] && i != 2 && random % 2 == 0) _toggleStake(i);
            else _batch(i, random);
        }
        assertEq(gauge.pendingPositions(), 0);
        assertGt(credits[2], 0, "failed payouts must not block transition");
        bool refundBeforeIRS = seed % 2 == 0;
        if (refundBeforeIRS) _refund();
        _advance(seed % 2 days);
        _finish();
        stage = 2;
        _scheduleIRS(queued);
        queued = 0;
        _assertBacking(); // No IRS earned during any of the paused time.
        if (!refundBeforeIRS) _refund();
        for (uint256 step; step < steps; ++step) {
            uint256 random = uint256(keccak256(abi.encode(seed, "IRS", step)));
            uint256 i = (random >> 8) % 3;
            _advance((random >> 32) % 2 days);
            if (random % 4 == 0) _fundIRS(1e18 + (random >> 16) % 1e24);
            else if (random % 4 == 1) _toggleStake(i);
            else if (random % 4 == 2 && deposited[i]) _claimIRS(i);
            else _claimInitial(i, true);
        }
        _fundIRS(CAMPAIGN);
        if (!deposited[2]) _toggleStake(2);
        _advance(1 hours + seed % 1 hours);
        _claimIRS(2);
        assertGt(irsPaid[2], 0, "required IRS payout");
        _setBlocked(false);
        for (uint256 i; i < 3; ++i) {
            _claimInitial(i, true);
            if (deposited[i]) _toggleStake(i);
            assertEq(credits[i], 0);
        }
        assertEq(initialToken.balanceOf(address(gauge)), donated, "all earned initial rewards executable after refund");
        assertGt(refunded, 0, "required unused funding refund");
    }
}
