// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import "../../../BaseFixture.sol";
import {CLPrivateGauge} from "contracts/gauge/CLPrivateGauge.sol";
import {ICLPrivateGauge} from "contracts/gauge/interfaces/ICLPrivateGauge.sol";
import {CLPrivateFactory} from "contracts/core/CLPrivateFactory.sol";
import {CLPrivatePool} from "contracts/core/CLPrivatePool.sol";
import {PrivateNonFungiblePositionManager} from "contracts/periphery/PrivateNonFungiblePositionManager.sol";
import {TickMath} from "contracts/core/libraries/TickMath.sol";
import {FullMath} from "contracts/core/libraries/FullMath.sol";

/// @dev Includes tokens that move funds and then return false: isolation must roll that movement back.
contract CampaignToken is ERC20 {
    address public blockedRecipient;
    uint256 public failureMode;
    bool public taxFunding;
    address public reentryTarget;
    bytes public reentryData;
    bool public reentryBlocked;

    constructor() ERC20("Initial Reward", "INITIAL") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function configureFailure(address account, uint256 mode) external {
        blockedRecipient = account;
        failureMode = mode;
    }

    function setTaxFunding(bool taxed) external {
        taxFunding = taxed;
    }

    function configureReentry(address target, bytes calldata data) external {
        reentryTarget = target;
        reentryData = data;
    }

    function transfer(address recipient, uint256 amount) public override returns (bool) {
        if (recipient == blockedRecipient) {
            if (failureMode == 1) revert("blocked");
            if (failureMode == 2) return false;
            if (failureMode == 3) {
                _transfer(msg.sender, recipient, amount);
                return false;
            }
            if (failureMode == 4) while (true) {}
        }
        if (reentryTarget != address(0)) {
            (bool ok,) = reentryTarget.call(reentryData);
            reentryBlocked = !ok;
        }
        return super.transfer(recipient, amount);
    }

    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        bool ok = super.transferFrom(sender, recipient, amount);
        if (taxFunding) _burn(recipient, amount / 10);
        return ok;
    }
}

abstract contract CLPrivateGaugeFixture is BaseFixture {
    CLPrivateFactory internal privateFactory;
    CLPrivatePool internal pool;
    CLGaugeFactory internal privateGaugeFactory;
    PrivateNonFungiblePositionManager internal privateNft;
    CLPrivateGauge internal gauge;
    CampaignToken internal initialToken;
    uint256 internal constant CAMPAIGN = 604800e18;

    function setUp() public virtual override {
        super.setUp();
        vm.startPrank(users.owner);
        CLPrivateGauge implementation = new CLPrivateGauge();
        privateGaugeFactory = new CLGaugeFactory(address(voter), address(implementation));
        privateFactory = new CLPrivateFactory(
            address(voter), address(new CLPrivatePool()), address(privateGaugeFactory), address(implementation)
        );
        privateNft = new PrivateNonFungiblePositionManager(
            users.owner, address(privateFactory), address(weth), address(nftDescriptor), "Private CL", "PCL"
        );
        privateFactory.setNonfungiblePositionManager(address(privateNft));
        privateGaugeFactory.setNonfungiblePositionManager(address(privateNft));
        privateFactory.setWhitelist(address(privateNft), true);
        privateFactory.setWhitelist(address(clCallee), true);
        privateFactory.setWhitelist(users.owner, true);
        privateNft.setPublicLiquidity(true);
        factoryRegistry.approve(address(privateFactory), address(votingRewardsFactory), address(privateGaugeFactory));
        pool = CLPrivatePool(
            privateFactory.createPool(address(token0), address(token1), int24(100), encodePriceSqrt(1, 1))
        );
        gauge = CLPrivateGauge(voter.createGauge(address(privateFactory), address(pool)));
        vm.stopPrank();
        initialToken = new CampaignToken();
        initialToken.mint(users.owner, 1e30);
        vm.prank(users.owner);
        initialToken.approve(address(gauge), type(uint256).max);
        skipToNextEpoch(0);
    }

    function _configure() internal {
        vm.prank(users.owner);
        gauge.configureInitialRewards(address(initialToken), users.owner);
    }

    function _fund(uint256 amount) internal {
        vm.prank(users.owner);
        gauge.notifyInitialRewards(amount);
    }

    function _begin() internal {
        vm.prank(users.owner);
        gauge.beginIrsTransition();
    }

    function _finish() internal {
        vm.prank(users.owner);
        gauge.finishIrsTransition();
    }

    function _one(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    function _mint(address who, int24 lower, int24 upper, uint256 amount) internal returns (uint256 id) {
        deal(address(token0), who, 1000e18);
        deal(address(token1), who, 1000e18);
        vm.startPrank(who);
        token0.approve(address(privateNft), type(uint256).max);
        token1.approve(address(privateNft), type(uint256).max);
        (id,,,) = privateNft.mint(
            INonfungiblePositionManager.MintParams({
                token0: address(token0),
                token1: address(token1),
                tickSpacing: 100,
                tickLower: lower,
                tickUpper: upper,
                amount0Desired: amount,
                amount1Desired: amount,
                amount0Min: 0,
                amount1Min: 0,
                recipient: who,
                deadline: block.timestamp,
                sqrtPriceX96: 0
            })
        );
        privateNft.approve(address(gauge), id);
        vm.stopPrank();
    }

    function _stake(address who, int24 lower, int24 upper, uint256 amount) internal returns (uint256 id) {
        id = _mint(who, lower, upper, amount);
        vm.prank(who);
        gauge.deposit(id);
    }

    function _queueIRS(uint256 amount) internal {
        deal(address(rewardToken), address(voter), amount);
        vm.startPrank(address(voter));
        rewardToken.approve(address(gauge), amount);
        gauge.notifyRewardAmount(amount);
        vm.stopPrank();
    }

    function _assertSettledConservation() internal {
        // Check real custody as well as bookkeeping. Excess donations are allowed;
        // earned user credits and refundable campaign cash must remain backed.
        uint256 cash = IERC20(gauge.initialRewardToken()).balanceOf(address(gauge));
        assertGe(cash, gauge.totalInitialRewardsCredits(), "outstanding credits backed by actual tokens");
        assertGe(
            cash + gauge.totalInitialRewardsPaid() + gauge.totalInitialRewardsRefunded(),
            gauge.totalInitialRewardsFunded(),
            "funded campaign cash remains in custody or has been transferred"
        );
        assertEq(
            gauge.totalInitialRewardsFunded(),
            gauge.totalInitialRewardsPaid() + gauge.totalInitialRewardsCredits() + gauge.totalInitialRewardsRefunded()
                + gauge.unusedInitialRewards()
        );
    }
}

contract CLPrivateGaugeTest is CLPrivateGaugeFixture {
    function test_LateConfiguration_NoRetroactiveRewards_AndPredictedGauge() public {
        uint256 id = _stake(users.alice, -100, 100, 1e18);
        skip(1 days);
        assertEq(uint256(gauge.phase()), 0);
        assertEq(pool.gauge(), address(gauge));
        assertEq(gauge.rewardToken(), address(rewardToken));
        _configure();
        _fund(CAMPAIGN);
        assertEq(gauge.earnedInitialRewards(users.alice, id), 0);
        assertEq(gauge.earned(users.alice, id), 0);
        assertEq(gauge.rewardRate(), 0);
        assertEq(gauge.left(), 0);
        skip(1 hours);
        assertApproxEqAbs(gauge.earnedInitialRewards(users.alice, id), gauge.initialRewardRate() * 1 hours, 1);
    }

    function test_ConfigurationAndFundingAuthorization_AndOneWayLifecycle() public {
        vm.expectRevert();
        gauge.configureInitialRewards(address(initialToken), users.owner);
        vm.startPrank(users.owner);
        vm.expectRevert();
        gauge.configureInitialRewards(address(0), users.owner);
        vm.expectRevert();
        gauge.configureInitialRewards(users.alice, users.owner);
        vm.expectRevert();
        gauge.configureInitialRewards(address(rewardToken), users.owner);
        vm.expectRevert();
        gauge.configureInitialRewards(address(initialToken), address(0));
        vm.stopPrank();
        _configure();
        vm.prank(users.owner);
        vm.expectRevert();
        gauge.configureInitialRewards(address(initialToken), users.owner);
        vm.expectRevert();
        gauge.notifyInitialRewards(CAMPAIGN);
        vm.prank(users.owner);
        vm.expectRevert();
        gauge.notifyInitialRewards(0);
        _fund(CAMPAIGN);
        _begin();
        vm.prank(users.owner);
        vm.expectRevert();
        gauge.notifyInitialRewards(CAMPAIGN);
        _finish();
        vm.prank(users.owner);
        vm.expectRevert();
        gauge.beginIrsTransition();
    }

    function test_TaxFundingRejectedWithoutChangingReserve() public {
        _configure();
        initialToken.setTaxFunding(true);
        vm.prank(users.owner);
        vm.expectRevert();
        gauge.notifyInitialRewards(CAMPAIGN);
        assertEq(gauge.totalInitialRewardsFunded(), 0);
        assertEq(initialToken.balanceOf(address(gauge)), 0);
        assertEq(pool.rewardReserve(), 0);
    }

    function test_HourlyTopupChangesOnlyFutureAccrual_AndKeepsWeeklyEnd() public {
        uint256 id = _stake(users.alice, -100, 100, 1e18);
        _configure();
        _fund(CAMPAIGN);
        uint256 finish = gauge.initialPeriodFinish();
        skip(1 hours);
        uint256 before = gauge.earnedInitialRewards(users.alice, id);
        _fund(CAMPAIGN);
        assertApproxEqAbs(gauge.earnedInitialRewards(users.alice, id), before, 1);
        assertEq(gauge.initialPeriodFinish(), finish);
        assertGt(gauge.initialRewardRate(), 1e18);
        assertApproxEqAbs(pool.rewardReserve() + gauge.initialRewardDust() + before, CAMPAIGN * 2, 1);
        skip(1 hours);
        assertApproxEqAbs(gauge.earnedInitialRewards(users.alice, id), before + gauge.initialRewardRate() * 1 hours, 2);
    }

    function test_StopAfterThreeDays_RefundsFourDays_AndStartsIRSWithoutRetroactiveAccrual() public {
        uint256 id = _stake(users.alice, -100, 100, 1e18);
        _configure();
        _fund(CAMPAIGN);
        _queueIRS(CAMPAIGN);
        skip(3 days);
        _begin();
        assertEq(pool.rewardRate(), 0);
        assertEq(pool.rewardReserve(), 0);
        uint256 initialTokenEarned = gauge.earnedInitialRewards(users.alice, id);
        assertApproxEqAbs(initialTokenEarned, 3 days * 1e18, 1);
        skip(1 days);
        gauge.checkpointTransition(_one(id));
        assertEq(initialToken.balanceOf(users.alice), initialTokenEarned);
        assertEq(gauge.pendingPositions(), 0);
        assertEq(gauge.stakerOf(id), users.alice);
        assertTrue(gauge.stakedContains(users.alice, id));
        assertApproxEqAbs(gauge.unusedInitialRewards(), 4 days * 1e18, 1);
        uint256 refund = gauge.recoverUnusedInitialRewards();
        assertEq(refund, gauge.totalInitialRewardsRefunded());
        _assertSettledConservation();
        _finish();
        assertEq(gauge.queuedIRS(), 0);
        assertEq(gauge.earned(users.alice, id), 0);
        skip(1 hours);
        uint256 irsEarned = gauge.earned(users.alice, id);
        assertApproxEqAbs(irsEarned, gauge.rewardRate() * 1 hours, 1);
        vm.prank(users.alice);
        gauge.getReward(id);
        assertEq(rewardToken.balanceOf(users.alice), irsEarned);
        assertEq(initialToken.balanceOf(users.alice), initialTokenEarned);
    }

    function test_QueueIRS_BeforeConfiguration_DuringCampaign_AndDuringTransition() public {
        _queueIRS(CAMPAIGN);
        assertEq(pool.rewardRate(), 0);
        _configure();
        _fund(CAMPAIGN);
        uint256 rate = pool.rewardRate();
        _queueIRS(CAMPAIGN);
        assertEq(pool.rewardRate(), rate);
        deal(address(rewardToken), users.owner, CAMPAIGN);
        vm.startPrank(users.owner);
        rewardToken.approve(address(gauge), CAMPAIGN);
        gauge.notifyRewardWithoutClaim(CAMPAIGN);
        vm.stopPrank();
        _begin();
        _queueIRS(CAMPAIGN);
        assertEq(gauge.queuedIRS(), CAMPAIGN * 4);
        assertEq(pool.rewardRate(), 0);
        _finish();
        assertEq(gauge.rewardRate(), CAMPAIGN * 4 / WEEK);
        assertEq(gauge.left(), gauge.rewardRate() * WEEK);
    }

    function test_PartialCheckpoint_DuplicateIds_AndWithdrawalDoNotSkipPending() public {
        uint256 a = _stake(users.alice, -100, 100, 1e18);
        uint256 b = _stake(users.bob, -100, 100, 1e18);
        uint256 c = _stake(users.charlie, -100, 100, 1e18);
        _configure();
        _fund(CAMPAIGN);
        skip(1 days);
        _begin();
        vm.prank(users.owner);
        vm.expectRevert();
        gauge.finishIrsTransition();
        vm.expectRevert();
        gauge.recoverUnusedInitialRewards();
        uint256[] memory ids = new uint256[](3);
        ids[0] = b;
        ids[1] = b;
        ids[2] = 999;
        gauge.checkpointTransition(ids);
        assertEq(gauge.pendingPositions(), 2);
        vm.prank(users.alice);
        gauge.withdraw(a);
        assertEq(privateNft.ownerOf(a), users.alice);
        assertEq(gauge.pendingPositions(), 1);
        uint256[] memory remaining = gauge.pendingTokenIds(0, 100);
        assertEq(remaining.length, 1);
        assertEq(remaining[0], c);
        assertEq(gauge.pendingTokenIds(10, 100).length, 0);
        gauge.checkpointTransition(remaining);
        _finish();
        _assertSettledConservation();
    }

    function test_SameBlockNamedTransitionPreservesAuthorization() public {
        uint256 id = _stake(users.alice, -100, 100, 1e18);
        _configure();
        _fund(CAMPAIGN);
        vm.expectRevert();
        gauge.transitionToIRS(_one(id));
        assertEq(uint256(gauge.phase()), 1);
        vm.prank(users.owner);
        gauge.transitionToIRS(_one(id));
        assertEq(uint256(gauge.phase()), 3);
        assertEq(gauge.pendingPositions(), 0);
        assertEq(gauge.earned(users.alice, id), 0);
        assertEq(gauge.unusedInitialRewards(), CAMPAIGN);
    }

    function test_NoConfigurationCanTransition_AndIRSStartsWithLaterFunding() public {
        uint256 id = _stake(users.alice, -100, 100, 1e18);
        _begin();
        gauge.checkpointTransition(_one(id));
        _finish();
        assertEq(pool.rewardRate(), 0);
        skip(2 days);
        _queueIRS(CAMPAIGN);
        assertEq(gauge.queuedIRS(), 0);
        assertEq(gauge.earned(users.alice, id), 0);
        skip(1 hours);
        assertGt(gauge.earned(users.alice, id), 0);
    }

    function test_WithdrawBeforeStop_PreservesCreditsAcrossTransferAndRestake() public {
        uint256 id = _stake(users.alice, -100, 100, 1e18);
        _configure();
        _fund(CAMPAIGN);
        skip(1 days);
        initialToken.configureFailure(users.alice, 1);
        vm.prank(users.alice);
        gauge.withdraw(id);
        uint256 owed = gauge.initialRewardCredits(users.alice);
        assertGt(owed, 0);
        vm.prank(users.alice);
        privateNft.transferFrom(users.alice, users.bob, id);
        vm.startPrank(users.bob);
        privateNft.approve(address(gauge), id);
        gauge.deposit(id);
        vm.stopPrank();
        skip(1 days);
        _begin();
        gauge.checkpointTransition(_one(id));
        assertEq(gauge.initialRewardCredits(users.alice), owed);
        assertGt(initialToken.balanceOf(users.bob), 0);
        uint256 refund = gauge.recoverUnusedInitialRewards();
        assertEq(initialToken.balanceOf(address(gauge)), owed);
        assertGt(refund, 0);
        _finish();
        initialToken.configureFailure(address(0), 0);
        vm.prank(users.alice);
        gauge.claimInitialRewards(new uint256[](0));
        assertEq(initialToken.balanceOf(users.alice), owed);
        _assertSettledConservation();
    }

    function test_FailedPayoutKeepsBacking_AndCannotBlockOtherUsersOrIRS() public {
        uint256 a = _stake(users.alice, -100, 100, 1e18);
        uint256 b = _stake(users.bob, -100, 100, 1e18);
        _configure();
        _fund(CAMPAIGN);
        skip(1 days);
        _begin();
        initialToken.configureFailure(users.alice, 3);
        uint256[] memory ids = new uint256[](2);
        ids[0] = a;
        ids[1] = b;
        gauge.checkpointTransition(ids);
        assertEq(initialToken.balanceOf(users.alice), 0, "false-return transfer must roll back");
        assertGt(initialToken.balanceOf(users.bob), 0);
        assertEq(gauge.pendingPositions(), 0);
        uint256 owed = gauge.initialRewardCredits(users.alice);
        assertGt(owed, 0);
        gauge.recoverUnusedInitialRewards();
        assertEq(initialToken.balanceOf(address(gauge)), owed);
        _finish();
        vm.prank(users.alice);
        gauge.withdraw(a);
        assertEq(privateNft.ownerOf(a), users.alice);
        initialToken.configureFailure(address(0), 0);
        vm.prank(users.alice);
        gauge.claimInitialRewards(new uint256[](0));
        assertEq(initialToken.balanceOf(users.alice), owed);
        _assertSettledConservation();
    }

    function test_GasBurningPayoutIsBounded_AndCreditsSurvive() public {
        uint256 id = _stake(users.alice, -100, 100, 1e18);
        _configure();
        _fund(CAMPAIGN);
        skip(1 days);
        _begin();
        initialToken.configureFailure(users.alice, 4);
        gauge.checkpointTransition(_one(id));
        assertEq(gauge.pendingPositions(), 0);
        assertGt(gauge.initialRewardCredits(users.alice), 0);
        _finish();
    }

    function test_ReentrantPayoutCannotWithdrawOrClaimTwice() public {
        uint256 id = _stake(users.alice, -100, 100, 1e18);
        _configure();
        _fund(CAMPAIGN);
        skip(1 days);
        _begin();
        initialToken.configureReentry(
            address(gauge), abi.encodeWithSelector(gauge.checkpointTransition.selector, _one(id))
        );
        gauge.checkpointTransition(_one(id));
        assertTrue(initialToken.reentryBlocked());
        assertGt(initialToken.balanceOf(users.alice), 0);
        assertEq(gauge.totalInitialRewardsCredits(), 0);
        assertEq(gauge.pendingPositions(), 0);
        _assertSettledConservation();
    }

    function test_ClaimMidCampaignThenStopDoesNotPayTwice() public {
        uint256 id = _stake(users.alice, -100, 100, 1e18);
        _configure();
        _fund(CAMPAIGN);
        skip(1 days);
        vm.prank(users.alice);
        gauge.claimInitialRewards(_one(id));
        uint256 paid = initialToken.balanceOf(users.alice);
        assertApproxEqAbs(paid, 1 days * 1e18, 1);
        skip(1 days);
        _begin();
        gauge.checkpointTransition(_one(id));
        assertApproxEqAbs(initialToken.balanceOf(users.alice), 2 days * 1e18, 2);
        gauge.checkpointTransition(_one(id));
        assertApproxEqAbs(initialToken.balanceOf(users.alice), 2 days * 1e18, 2);
        _assertSettledConservation();
    }

    function test_OnlyActiveStakedLiquidityEarns_AndNoStakeTimeIsRefundable() public {
        uint256 inactive = _stake(users.bob, 100, 200, 1e18);
        _configure();
        _fund(CAMPAIGN);
        skip(1 days);
        assertEq(gauge.earnedInitialRewards(users.bob, inactive), 0);
        uint256 active = _stake(users.alice, -100, 100, 1e18);
        skip(1 days);
        _begin();
        assertApproxEqAbs(gauge.earnedInitialRewards(users.alice, active), 1 days * 1e18, 1);
        gauge.checkpointTransition(gauge.pendingTokenIds(0, 10));
        assertApproxEqAbs(gauge.unusedInitialRewards(), 6 days * 1e18, 1);
        assertEq(initialToken.balanceOf(users.bob), 0);
        _assertSettledConservation();
    }

    function test_DustDoesNotExtendCampaignPastWeeklyBoundary() public {
        uint256 id = _stake(users.alice, -100, 100, 1e18);
        _configure();
        _fund(CAMPAIGN + WEEK - 1);
        assertEq(gauge.initialRewardDust(), WEEK - 1);
        assertEq(pool.rewardReserve(), CAMPAIGN);
        skip(10 days);
        _begin();
        gauge.checkpointTransition(_one(id));
        assertApproxEqAbs(initialToken.balanceOf(users.alice), CAMPAIGN, 1);
        assertApproxEqAbs(gauge.unusedInitialRewards(), WEEK - 1, 1);
        _assertSettledConservation();
    }

    function test_RefundExcludesDonations_AndAlwaysPaysFixedFunder() public {
        _configure();
        _fund(CAMPAIGN);
        initialToken.mint(address(gauge), 123e18);
        _begin();
        uint256 before = initialToken.balanceOf(users.owner);
        vm.prank(users.alice);
        assertEq(gauge.recoverUnusedInitialRewards(), CAMPAIGN);
        assertEq(initialToken.balanceOf(users.owner), before + CAMPAIGN);
        assertEq(initialToken.balanceOf(users.alice), 0);
        assertEq(initialToken.balanceOf(address(gauge)), 123e18);
        _assertSettledConservation();
    }

    function test_MintPauseBlocksMintAndIncrease_PreservesWithdrawAndDecrease() public {
        uint256 id = _stake(users.alice, -100, 100, 1e18);
        uint256 unstaked = _mint(users.bob, -100, 100, 1e18);
        vm.prank(users.owner);
        privateFactory.setWhitelist(address(privateNft), false);
        vm.startPrank(users.bob);
        vm.expectRevert(bytes("NW"));
        privateNft.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: unstaked,
                amount0Desired: 1e18,
                amount1Desired: 1e18,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
        _begin();
        vm.prank(users.bob);
        vm.expectRevert();
        gauge.deposit(unstaked);
        vm.prank(users.alice);
        gauge.withdraw(id);
        (,,,,,,, uint128 liq,,,,) = privateNft.positions(id);
        vm.prank(users.alice);
        privateNft.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: id, liquidity: liq, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
            })
        );
        _finish();
        vm.prank(users.owner);
        privateFactory.setWhitelist(address(privateNft), true);
        vm.prank(users.bob);
        gauge.deposit(unstaked);
        assertTrue(gauge.stakedContains(users.bob, unstaked));
    }

    function test_SwapsDuringCheckpointingPreserveFrozenEntitlementsAndIrsBaselines() public {
        _mint(users.charlie, -1000, 1000, 10e18);
        uint256 a = _stake(users.alice, -100, 100, 1e18);
        uint256 b = _stake(users.bob, 100, 300, 1e18);
        _configure();
        _fund(CAMPAIGN);
        skip(1 days);
        vm.prank(users.alice);
        clCallee.swapToHigherSqrtPrice(address(pool), TickMath.getSqrtRatioAtTick(200), users.alice);
        skip(1 days);
        _begin();
        uint256 earnedA = gauge.earnedInitialRewards(users.alice, a);
        uint256 earnedB = gauge.earnedInitialRewards(users.bob, b);
        assertApproxEqAbs(earnedA, 1 days * 1e18, 1);
        assertApproxEqAbs(earnedB, 1 days * 1e18, 1);
        gauge.checkpointTransition(_one(a));
        vm.prank(users.alice);
        clCallee.swapToLowerSqrtPrice(address(pool), TickMath.getSqrtRatioAtTick(0), users.alice);
        skip(1 days);
        assertEq(gauge.earnedInitialRewards(users.bob, b), earnedB);
        gauge.checkpointTransition(_one(b));
        assertEq(initialToken.balanceOf(users.alice), earnedA);
        assertEq(initialToken.balanceOf(users.bob), earnedB);
        _queueIRS(CAMPAIGN);
        _finish();
        assertEq(gauge.earned(users.alice, a), 0);
        assertEq(gauge.earned(users.bob, b), 0);
        skip(1 hours);
        assertGt(gauge.earned(users.alice, a), 0);
        assertEq(gauge.earned(users.bob, b), 0);
    }

    function testFuzz_ConservationAcrossEarlyStop(uint256 elapsed, uint256 extra) public {
        elapsed = bound(elapsed, 0, 10 days);
        extra = bound(extra, 0, 1e24);
        uint256 a = _stake(users.alice, -100, 100, 1e18);
        uint256 b = _stake(users.bob, -100, 100, 2e18);
        _configure();
        _fund(CAMPAIGN + extra);
        skip(elapsed);
        _begin();
        uint256[] memory ids = new uint256[](2);
        ids[0] = a;
        ids[1] = b;
        gauge.checkpointTransition(ids);
        _assertSettledConservation();
        assertEq(
            initialToken.balanceOf(address(gauge)) + initialToken.balanceOf(users.alice)
                + initialToken.balanceOf(users.bob),
            CAMPAIGN + extra,
            "actual balances vs funding input"
        );
        (,,,,,,, uint128 liquidityA,,,,) = privateNft.positions(a);
        (,,,,,,, uint128 liquidityB,,,,) = privateNft.positions(b);
        assertApproxEqAbs(
            initialToken.balanceOf(users.bob),
            FullMath.mulDiv(initialToken.balanceOf(users.alice), liquidityB, liquidityA),
            3
        );
        uint256 refund = gauge.recoverUnusedInitialRewards();
        assertEq(
            refund + initialToken.balanceOf(users.alice) + initialToken.balanceOf(users.bob),
            CAMPAIGN + extra,
            "paid and refunded vs funding input"
        );
        assertEq(initialToken.balanceOf(address(gauge)), 0, "no residual liabilities after complete payout/refund");
        _finish();
        _assertSettledConservation();
    }

    function test_ImplementationFitsEip170() public {
        address implementation = address(new CLPrivateGauge());
        uint256 size;
        assembly { size := extcodesize(implementation) }
        assertLe(size, 24576);
    }

    function test_CheckpointBatchGasTwentyFiveDistinctStakers() public {
        for (uint256 i; i < 25; ++i) {
            _stake(address(uint160(0x1000 + i)), -100, 100, 1e18);
        }
        _configure();
        _fund(CAMPAIGN);
        skip(1 days);
        _begin();
        uint256[] memory ids = gauge.pendingTokenIds(0, 25);
        uint256 gasBefore = gasleft();
        gauge.checkpointTransition(ids);
        emit log_named_uint("checkpoint and pay 25 distinct stakers (gross gas)", gasBefore - gasleft());
        assertEq(gauge.pendingPositions(), 0);
        assertEq(gauge.totalInitialRewardsCredits(), 0);
        assertGt(gauge.totalInitialRewardsPaid(), 0);
        _assertSettledConservation();
    }
}
