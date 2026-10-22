// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import "./CLPrivateGauge.t.sol";
import "../CLGauge/claimAndLock.t.sol";

interface CampaignProductionVoter {
    function initialize(address[] calldata tokens, address minter) external;
    function notifyRewardAmount(uint256 amount) external;
    function weights(address pool) external view returns (uint256);
    function totalWeight() external view returns (uint256);
    function claimable(address target) external view returns (uint256);
}

/// @dev Only the Minter is stubbed: real Voter notification, index accounting,
///      gauge distribution, approvals, and claims all execute production bytecode.
contract CampaignMinter {
    IERC20 private token;
    CampaignProductionVoter private voter;
    uint256 public updates;

    constructor(address reward, address target) {
        token = IERC20(reward);
        voter = CampaignProductionVoter(target);
    }

    function fund(uint256 amount) external {
        require(token.transferFrom(msg.sender, address(this), amount));
        require(token.approve(address(voter), amount));
        voter.notifyRewardAmount(amount);
    }

    function updatePeriod() external returns (uint256) {
        updates++;
        return block.timestamp - block.timestamp % 1 weeks;
    }
}

contract CLPrivateGaugeRealVoterTest is CLPrivateGaugeFixture, RealEscrowArtifactDeployer {
    using stdStorage for StdStorage;
    RealClaimEscrow private realEscrow;
    ClaimVoter private claimVoter;
    CLRecordingClaimHook private hook;
    CampaignMinter private campaignMinter;
    uint256 private constant MAXTIME = 4 * 365 days;

    function deployDependencies() public override {
        factoryRegistry = IFactoryRegistry(new MockFactoryRegistry());
        votingRewardsFactory = IVotingRewardsFactory(new MockVotingRewardsFactory());
        weth = IERC20(address(new MockWETH()));
        escrow = IVotingEscrow(_deployRealClaimEscrow(address(11), address(rewardToken), address(factoryRegistry)));
        voter = IVoter(
            _deployCoreArtifact(
                "Voter.sol/Voter.json", abi.encode(address(11), address(escrow), address(factoryRegistry))
            )
        );
        realEscrow = RealClaimEscrow(address(escrow));
        realEscrow.setVoterAndDistributor(address(voter), address(0));
        claimVoter = ClaimVoter(address(voter));
    }

    function setUp() public override {
        super.setUp();
        vm.startPrank(users.owner);
        hook = new CLRecordingClaimHook();
        claimVoter.setClaimHook(address(hook));
        campaignMinter = new CampaignMinter(address(rewardToken), address(voter));
        CampaignProductionVoter(address(voter)).initialize(new address[](0), address(campaignMinter));
        vm.stopPrank();
        // Seed the voting outcome only: these tests cover the real distribution
        // integration, not voting/rewards-distributor/fee-voting contracts.
        stdstore.target(address(voter)).sig("weights(address)").with_key(address(pool)).checked_write(1e18);
        stdstore.target(address(voter)).sig("totalWeight()").checked_write(1e18);
    }

    function _targets() private view returns (address[] memory targets) {
        targets = new address[](1);
        targets[0] = address(gauge);
    }

    function _distributeIRS(uint256 amount) private {
        deal(address(rewardToken), users.owner, amount);
        vm.startPrank(users.owner);
        rewardToken.approve(address(campaignMinter), amount);
        campaignMinter.fund(amount);
        vm.stopPrank();
        // Genuine production Voter.distribute: calls Minter, updates the gauge's
        // share from its index, approves IRS, and calls gauge.notifyRewardAmount.
        voter.distribute(_targets());
        assertEq(CampaignProductionVoter(address(voter)).claimable(address(gauge)), 0);
        assertEq(rewardToken.allowance(address(voter), address(gauge)), 0);
    }

    function _createLock(address account) private returns (uint256 id) {
        deal(address(rewardToken), account, 1e18);
        vm.startPrank(account);
        rewardToken.approve(address(escrow), 1e18);
        id = escrow.createLock(1e18, MAXTIME);
        vm.stopPrank();
    }

    function test_ProductionVoterDistributionQueuesThenStartsIRSAndClaimsLiquid() public {
        uint256 position = _stake(users.alice, -100, 100, 1e18);
        _configure();
        _fund(CAMPAIGN);
        _distributeIRS(CAMPAIGN);
        assertEq(campaignMinter.updates(), 1);
        assertEq(gauge.queuedIRS(), CAMPAIGN);
        assertEq(gauge.left(), 0);
        assertEq(pool.rewardRate(), gauge.initialRewardRate());
        skip(1 days);
        uint256 initialTokenEarned = gauge.earnedInitialRewards(users.alice, position);
        vm.prank(users.alice);
        voter.claimRewards(_targets());
        assertEq(rewardToken.balanceOf(users.alice), 0);
        assertEq(initialToken.balanceOf(users.alice), 0);
        assertEq(gauge.earnedInitialRewards(users.alice, position), initialTokenEarned);
        assertEq(hook.calls(), 0);
        _begin();
        gauge.checkpointTransition(_one(position));
        assertEq(initialToken.balanceOf(users.alice), initialTokenEarned);
        assertEq(hook.calls(), 0);
        skip(2 hours);
        _finish();
        assertEq(gauge.queuedIRS(), 0);
        assertEq(gauge.earned(users.alice, position), 0);
        skip(1 hours);
        uint256 earned = gauge.earned(users.alice, position);
        assertGt(earned, 0);
        vm.prank(users.alice);
        voter.claimRewards(_targets());
        assertEq(rewardToken.balanceOf(users.alice), earned);
        assertEq(initialToken.balanceOf(users.alice), initialTokenEarned);
        assertEq(hook.calls(), 1);
        assertEq(hook.id(), 0);
        assertEq(hook.amount(), 0);
        assertEq(hook.gauge(), address(gauge));
        assertEq(hook.pool(), address(pool));
        uint256 previousRate = gauge.rewardRate();
        _distributeIRS(CAMPAIGN * 2);
        assertEq(campaignMinter.updates(), 2);
        assertEq(gauge.queuedIRS(), 0);
        assertGt(gauge.rewardRate(), previousRate);
        assertEq(pool.rewardRate(), gauge.rewardRate());
    }

    function test_ProductionVoterLocksOnlyIRSAfterTransitionAndClearsAllowance() public {
        uint256 position = _stake(users.alice, -100, 100, 1e18);
        _configure();
        _fund(CAMPAIGN);
        _distributeIRS(CAMPAIGN);
        skip(1 days);
        _begin();
        gauge.checkpointTransition(_one(position));
        uint256 paidInitial = initialToken.balanceOf(users.alice);
        _finish();
        skip(1 days);
        uint256 earned = gauge.earned(users.alice, position);
        assertGt(earned, 0);
        vm.prank(users.alice);
        uint256 lockId = claimVoter.claimRewardsAndLock(_targets(), 0, MAXTIME);
        assertEq(escrow.ownerOf(lockId), users.alice);
        assertEq(uint256(uint128(realEscrow.locked(lockId).amount)), earned);
        assertEq(rewardToken.balanceOf(address(escrow)), earned);
        assertEq(rewardToken.balanceOf(users.alice), 0);
        assertEq(initialToken.balanceOf(users.alice), paidInitial);
        assertEq(initialToken.balanceOf(address(escrow)), 0);
        assertEq(gauge.earned(users.alice, position), 0);
        assertEq(rewardToken.allowance(address(gauge), address(escrow)), 0);
        assertEq(hook.calls(), 1);
        assertEq(hook.id(), lockId);
        assertEq(hook.amount(), earned);
        assertEq(hook.user(), users.alice);
        assertEq(hook.gauge(), address(gauge));
        vm.prank(users.alice);
        assertEq(claimVoter.claimRewardsAndLock(_targets(), lockId, 0), lockId);
        assertEq(hook.calls(), 1);
        assertEq(realEscrow.tokenId(), 1);
    }

    function test_PreIrsLocksDoNotConsumeInitialAndStillValidateExistingTargets() public {
        uint256 position = _stake(users.alice, -100, 100, 1e18);
        _configure();
        _fund(CAMPAIGN);
        skip(1 days);
        uint256 earned = gauge.earnedInitialRewards(users.alice, position);
        uint256 foreignLock = _createLock(users.bob);
        uint256 ownLock = _createLock(users.alice);
        vm.startPrank(users.alice);
        vm.expectRevert(bytes("NA"));
        gauge.getRewardAndLock(position, foreignLock, 0);
        vm.expectRevert(bytes("IP"));
        gauge.getRewardAndLock(position, ownLock, 1);
        assertEq(gauge.getRewardAndLock(position, ownLock, 0), ownLock);
        assertEq(claimVoter.claimRewardsAndLock(_targets(), 0, MAXTIME), 0);
        vm.stopPrank();
        assertEq(uint256(uint128(realEscrow.locked(ownLock).amount)), 1e18);
        assertEq(gauge.earnedInitialRewards(users.alice, position), earned);
        assertEq(gauge.initialRewardCredits(users.alice), 0);
        assertEq(initialToken.balanceOf(users.alice), 0);
        assertEq(initialToken.balanceOf(address(escrow)), 0);
        assertEq(realEscrow.tokenId(), 2);
        assertEq(hook.calls(), 0);
    }

    function test_ProductionHookFailureCannotBlockIRSWithdrawal() public {
        uint256 position = _stake(users.alice, -100, 100, 1e18);
        _begin();
        gauge.checkpointTransition(_one(position));
        _finish();
        _distributeIRS(CAMPAIGN);
        hook.configure(address(gauge), false);
        skip(1 hours);
        uint256 earned = gauge.earned(users.alice, position);
        assertGt(earned, 0);
        vm.prank(users.alice);
        gauge.withdraw(position);
        assertEq(privateNft.ownerOf(position), users.alice);
        assertEq(rewardToken.balanceOf(users.alice), earned);
        assertEq(hook.calls(), 0);
        assertFalse(gauge.stakedContains(users.alice, position));
    }

    /// @dev Complete operator runbook through the private factory/pool/manager/gauge
    ///      and production Voter. Only Minter and the voting outcome are seeded.
    function test_E2E_LateTokenTopupsPausedBatchesRefundResumeAndNormalIRS() public {
        uint256 alice = _stake(users.alice, -100, 100, 1e18);
        uint256 bob = _stake(users.bob, -100, 100, 2e18);
        uint256 waiting = _mint(users.charlie, -100, 100, 1e18);
        assertEq(gauge.initialRewardToken(), address(0));
        skip(1 days);
        assertEq(gauge.earnedInitialRewards(users.alice, alice), 0);
        _configure();
        _fund(CAMPAIGN);
        skip(1 hours);
        _fund(CAMPAIGN);
        skip(1 days);
        _fund(CAMPAIGN);
        _distributeIRS(CAMPAIGN);
        assertEq(gauge.queuedIRS(), CAMPAIGN);
        assertEq(gauge.rewardRate(), 0);
        skip(2 days);

        vm.prank(users.owner);
        privateFactory.setWhitelist(address(privateNft), false);
        vm.startPrank(users.charlie);
        vm.expectRevert(bytes("NW"));
        privateNft.mint(
            INonfungiblePositionManager.MintParams({
                token0: address(token0),
                token1: address(token1),
                tickSpacing: 100,
                tickLower: -100,
                tickUpper: 100,
                amount0Desired: 1e18,
                amount1Desired: 1e18,
                amount0Min: 0,
                amount1Min: 0,
                recipient: users.charlie,
                deadline: block.timestamp,
                sqrtPriceX96: 0
            })
        );
        vm.stopPrank();
        uint256 owedAlice = gauge.earnedInitialRewards(users.alice, alice);
        uint256 owedBob = gauge.earnedInitialRewards(users.bob, bob);
        _begin();
        vm.prank(users.charlie);
        vm.expectRevert();
        gauge.deposit(waiting);
        vm.prank(users.owner);
        vm.expectRevert(bytes("PHASE"));
        gauge.notifyInitialRewards(CAMPAIGN);

        gauge.checkpointTransition(_one(alice));
        assertEq(initialToken.balanceOf(users.alice), owedAlice);
        assertEq(gauge.pendingPositions(), 1);
        skip(2 hours);
        assertEq(gauge.earnedInitialRewards(users.bob, bob), owedBob);
        gauge.checkpointTransition(_one(bob));
        assertEq(initialToken.balanceOf(users.bob), owedBob);
        assertGt(gauge.unusedInitialRewards(), 0);
        uint256 beforeRefund = initialToken.balanceOf(users.owner);
        uint256 refund = gauge.recoverUnusedInitialRewards();
        assertEq(initialToken.balanceOf(users.owner), beforeRefund + refund);
        _assertSettledConservation();
        assertEq(initialToken.balanceOf(address(gauge)), 0);
        skip(1 hours);
        _finish();
        assertEq(gauge.earned(users.alice, alice), 0);
        assertEq(gauge.earned(users.bob, bob), 0);
        assertEq(gauge.queuedIRS(), 0);
        assertEq(pool.rewardRate(), gauge.rewardRate());

        vm.prank(users.owner);
        privateFactory.setWhitelist(address(privateNft), true);
        vm.prank(users.charlie);
        gauge.deposit(waiting);
        uint256 fresh = _stake(users.charlie, -100, 100, 1e18);
        assertEq(privateNft.ownerOf(fresh), address(gauge));
        skip(1 hours);
        uint256 aliceIRS = gauge.earned(users.alice, alice);
        assertGt(aliceIRS, 0);
        vm.prank(users.alice);
        voter.claimRewards(_targets());
        assertEq(rewardToken.balanceOf(users.alice), aliceIRS);
        assertEq(initialToken.balanceOf(users.alice), owedAlice);
        _distributeIRS(CAMPAIGN);
        vm.prank(users.bob);
        gauge.withdraw(bob);
        assertEq(privateNft.ownerOf(bob), users.bob);
        assertGt(rewardToken.balanceOf(users.bob), 0);
        assertEq(initialToken.balanceOf(users.bob), owedBob);
    }
}
