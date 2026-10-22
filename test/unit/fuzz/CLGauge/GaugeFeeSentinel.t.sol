pragma solidity ^0.7.6;
pragma abicoder v2;

import "../../../BaseFixture.sol";
import {CLPool} from "contracts/core/CLPool.sol";
import {CLGauge} from "contracts/gauge/CLGauge.sol";
import {TestCLCallee} from "contracts/core/test/TestCLCallee.sol";

/// @notice Real-swap regression for fee collection across idle notification cycles.
contract GaugeFeeSentinelRegressionTest is BaseFixture {
    CLPool pool;
    CLGauge gauge;
    TestCLCallee callee;
    int24 constant SPACING = 60;

    address lpAcct;
    address traderAcct;

    function setUp() public override {
        super.setUp();
        lpAcct = users.alice;
        traderAcct = users.bob;

        pool = CLPool(
            poolFactory.createPool({
                tokenA: address(token0),
                tokenB: address(token1),
                tickSpacing: SPACING,
                sqrtPriceX96: encodePriceSqrt(1, 1)
            })
        );
        gauge = CLGauge(voter.createGauge(address(poolFactory), address(pool)));
        callee = new TestCLCallee();

        deal({token: address(token0), to: lpAcct, give: 1e30});
        deal({token: address(token1), to: lpAcct, give: 1e30});
        deal({token: address(token0), to: traderAcct, give: 1e30});
        deal({token: address(token1), to: traderAcct, give: 1e30});

        vm.startPrank(lpAcct);
        token0.approve(address(nft), type(uint256).max);
        token1.approve(address(nft), type(uint256).max);
        token0.approve(address(nftCallee), type(uint256).max);
        token1.approve(address(nftCallee), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(traderAcct);
        token0.approve(address(callee), type(uint256).max);
        token1.approve(address(callee), type(uint256).max);
        vm.stopPrank();

        // staked full-range LP: swap fees accrue to the gauge
        uint256 id = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(1e22, 1e22, lpAcct);
        vm.startPrank(lpAcct);
        nft.approve(address(gauge), id);
        gauge.deposit(id);
        vm.stopPrank();

        skipToNextEpoch(0);
    }

    function _genFees(uint256 rounds) internal {
        for (uint256 i = 0; i < rounds; i++) {
            (uint160 sp,,,,,) = pool.slot0();
            uint160 target = sp - sp / 5;
            if (target > 4295128739) {
                vm.prank(traderAcct);
                callee.swapToLowerSqrtPrice(address(pool), target, traderAcct);
            }
            skip(1800);
        }
    }

    function _notify(uint256 amt) internal {
        deal({token: address(rewardToken), to: address(voter), give: amt * 4});
        vm.startPrank(address(voter));
        rewardToken.approve(address(gauge), type(uint256).max);
        gauge.notifyRewardAmount(amt);
        vm.stopPrank();
    }

    function _assertSynchronized() internal {
        assertEq(gauge.fees0(), token0.balanceOf(address(gauge)), "token0 ledger mismatch");
        assertEq(gauge.fees1(), token1.balanceOf(address(gauge)), "token1 ledger mismatch");
    }

    function test_IdleNotificationsThenFreshFeesRemainSynchronized() public {
        _genFees(6);
        (uint128 accrued,) = pool.gaugeFees();
        assertGt(uint256(accrued), 604800, "must exercise fee forwarding");
        _notify(100e18);
        (uint128 sentinel,) = pool.gaugeFees();
        assertEq(uint256(sentinel), 1);
        assertEq(gauge.fees0(), 0);
        _assertSynchronized();

        // No new swap fees: neither notification may credit the retained sentinel.
        _notify(100e18);
        _notify(100e18);
        _assertSynchronized();
        assertEq(gauge.fees0(), 0);

        address recipient = gauge.feesVotingReward();
        uint256 beforeForward = token0.balanceOf(recipient);
        _genFees(6);
        (uint128 fresh,) = pool.gaugeFees();
        assertGt(uint256(fresh), 604800, "must exercise subsequent forwarding");
        _notify(100e18);
        assertEq(token0.balanceOf(recipient) - beforeForward, uint256(fresh) - 1);
        assertEq(gauge.fees0(), 0);
        _assertSynchronized();
    }

    function test_FeesBetweenNotificationsRemainSynchronized() public {
        for (uint256 i; i < 3; i++) {
            _genFees(6);
            _notify(100e18);
            _assertSynchronized();
        }
    }
}
