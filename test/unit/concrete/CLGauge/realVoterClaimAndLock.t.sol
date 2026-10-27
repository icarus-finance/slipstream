// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import "./claimAndLock.t.sol";

interface RealV2ClaimGauge {
    function deposit(uint256 amount) external;
    function earned(address account) external view returns (uint256);
}

interface RealGaugeRegistry {
    function isGauge(address gauge) external view returns (bool);
    function poolForGauge(address gauge) external view returns (address);
}

contract NonPoolClaimFactory {
    function isPool(address) external pure returns (bool) {
        return false;
    }
}

contract MixedGaugeClaimHook {
    RealGaugeRegistry internal registry;
    uint256 public calls;
    mapping(address => uint256) public ids;
    mapping(address => uint256) public amounts;
    mapping(address => address) public users;
    mapping(address => address) public pools;

    constructor(address voter) {
        registry = RealGaugeRegistry(voter);
    }

    function onClaim(uint256 id, uint256 amount, address user, address gauge) external {
        require(msg.sender == gauge && registry.isGauge(gauge), "unauthorized gauge");
        calls++;
        ids[gauge] = id;
        amounts[gauge] = amount;
        users[gauge] = user;
        pools[gauge] = registry.poolForGauge(gauge);
    }
}

/// @dev Real 0.8.30 Voter and escrow with real 0.7.6 pools, position manager and gauge clones.
contract RealVoterClaimAndLockTest is CLGaugeTest, RealEscrowArtifactDeployer {
    CLGauge internal firstGauge;
    CLGauge internal secondGauge;
    CLPool internal firstPool;
    CLPool internal secondPool;
    RealClaimEscrow internal realEscrow;
    ClaimVoter internal claimVoter;
    CLRecordingClaimHook internal hook;
    uint256 internal constant MAXTIME = 4 * 365 days;

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
        firstPool = CLPool(poolFactory.createPool(address(token0), address(token1), 60, encodePriceSqrt(1, 1)));
        firstGauge = CLGauge(voter.createGauge(address(poolFactory), address(firstPool)));
        hook = new CLRecordingClaimHook();
        claimVoter.setClaimHook(address(hook));
        // Created after the single global setter: new gauges must inherit the callback too.
        secondPool = CLPool(poolFactory.createPool(address(token0), address(token1), 10, encodePriceSqrt(1, 1)));
        secondGauge = CLGauge(voter.createGauge(address(poolFactory), address(secondPool)));
        vm.stopPrank();
        skipToNextEpoch(0);
        vm.startPrank(users.alice);
    }

    function _stake(CLGauge target, int24 spacing) internal returns (uint256 id) {
        id = nftCallee.mintNewCustomRangePositionForUserWithCustomTickSpacing(
            TOKEN_1, TOKEN_1, -spacing, spacing, spacing, users.alice
        );
        nft.approve(address(target), id);
        target.deposit(id);
    }

    function _accrueBoth() internal returns (uint256 first, uint256 second, uint256 amount) {
        first = _stake(firstGauge, 60);
        second = _stake(secondGauge, 10);
        addRewardToGauge(address(voter), address(firstGauge), TOKEN_1);
        addRewardToGauge(address(voter), address(secondGauge), TOKEN_1);
        skip(2 days);
        vm.startPrank(users.alice);
        amount = firstGauge.earned(users.alice, first) + secondGauge.earned(users.alice, second);
        assertGt(amount, 0);
    }

    function _gauges() internal view returns (address[] memory targets) {
        targets = new address[](2);
        targets[0] = address(firstGauge);
        targets[1] = address(secondGauge);
    }

    function _amount(uint256 id) internal view returns (uint256) {
        return uint256(uint128(realEscrow.locked(id).amount));
    }

    function test_ProductionVoterBatchCreatesOneNFTAndSharesHookWithLaterGauge() public {
        (uint256 first, uint256 second, uint256 amount) = _accrueBoth();
        uint256 id = claimVoter.claimRewardsAndLock(_gauges(), 0, MAXTIME);
        assertEq(realEscrow.tokenId(), 1);
        assertEq(escrow.ownerOf(id), users.alice);
        assertEq(_amount(id), amount);
        assertEq(rewardToken.balanceOf(address(escrow)), amount);
        assertEq(rewardToken.balanceOf(users.alice), 0);
        assertEq(firstGauge.earned(users.alice, first), 0);
        assertEq(secondGauge.earned(users.alice, second), 0);
        assertEq(rewardToken.allowance(address(firstGauge), address(escrow)), 0);
        assertEq(rewardToken.allowance(address(secondGauge), address(escrow)), 0);
        assertEq(hook.calls(), 2);
        assertEq(hook.callsByGauge(address(firstGauge)), 1);
        assertEq(hook.callsByGauge(address(secondGauge)), 1);
        assertEq(hook.poolsByGauge(address(firstGauge)), address(firstPool));
        assertEq(hook.poolsByGauge(address(secondGauge)), address(secondPool));
        assertEq(hook.amountsByGauge(address(firstGauge)) + hook.amountsByGauge(address(secondGauge)), amount);
        assertEq(hook.id(), id);
    }

    function test_ProductionVoterExistingLockBatchRetainsExpiry() public {
        deal(address(rewardToken), users.alice, TOKEN_1);
        rewardToken.approve(address(escrow), TOKEN_1);
        uint256 id = escrow.createLock(TOKEN_1, MAXTIME);
        uint256 expiry = realEscrow.locked(id).end;
        (,, uint256 amount) = _accrueBoth();
        assertEq(claimVoter.claimRewardsAndLock(_gauges(), id, 0), id);
        assertEq(realEscrow.tokenId(), 1);
        assertEq(_amount(id), TOKEN_1 + amount);
        assertEq(realEscrow.locked(id).end, expiry);
        assertEq(hook.calls(), 2);
    }

    function test_ProductionVoterGlobalDisableRestoresLiquidClaims() public {
        (,, uint256 amount) = _accrueBoth();
        hook.configure(address(secondGauge), false);
        vm.startPrank(users.owner);
        claimVoter.setClaimHook(address(0));
        vm.startPrank(users.alice);
        voter.claimRewards(_gauges());
        assertEq(rewardToken.balanceOf(users.alice), amount);
        assertEq(hook.calls(), 0);
        assertEq(claimVoter.claimHook(), address(0));
        assertEq(realEscrow.tokenId(), 0);
    }

    function test_ProductionVoterLaterHookFailurePreservesEarlierGaugeAndNFT() public {
        (uint256 first, uint256 second, uint256 amount) = _accrueBoth();
        uint256 firstReward = firstGauge.earned(users.alice, first);
        hook.configure(address(secondGauge), false);
        uint256 id = claimVoter.claimRewardsAndLock(_gauges(), 0, MAXTIME);
        assertEq(realEscrow.tokenId(), 1);
        assertEq(_amount(id), amount);
        assertEq(escrow.ownerOf(id), users.alice);
        assertEq(rewardToken.balanceOf(address(escrow)), amount);
        assertEq(firstGauge.earned(users.alice, first), 0);
        assertEq(secondGauge.earned(users.alice, second), 0);
        assertEq(rewardToken.allowance(address(firstGauge), address(escrow)), 0);
        assertEq(rewardToken.allowance(address(secondGauge), address(escrow)), 0);
        assertEq(hook.calls(), 1);
        assertEq(hook.gauge(), address(firstGauge));
        assertEq(hook.id(), id);
        assertEq(hook.amount(), firstReward);
    }

    function test_ProductionVoterMixedV2AndCLBatchUsesOneNFTAndGlobalHook() public {
        vm.stopPrank();
        vm.startPrank(users.owner);
        address coreFactory = _deployCoreArtifact("GaugeFactory.sol/GaugeFactory.json", bytes(""));
        NonPoolClaimFactory nonPoolFactory = new NonPoolClaimFactory();
        factoryRegistry.approve(address(nonPoolFactory), address(votingRewardsFactory), coreFactory);
        address v2 = voter.createGauge(address(nonPoolFactory), address(token0));
        MixedGaugeClaimHook mixedHook = new MixedGaugeClaimHook(address(voter));
        claimVoter.setClaimHook(address(mixedHook));

        vm.startPrank(users.alice);
        token0.approve(v2, TOKEN_1);
        RealV2ClaimGauge(v2).deposit(TOKEN_1);
        uint256 position = _stake(firstGauge, 60);
        addRewardToGauge(address(voter), v2, TOKEN_1);
        addRewardToGauge(address(voter), address(firstGauge), TOKEN_1);
        skip(2 days);
        vm.startPrank(users.alice);
        uint256 v2Reward = RealV2ClaimGauge(v2).earned(users.alice);
        uint256 clReward = firstGauge.earned(users.alice, position);
        assertGt(v2Reward, 0);
        assertGt(clReward, 0);
        address[] memory targets = new address[](2);
        targets[0] = v2;
        targets[1] = address(firstGauge);
        uint256 id = claimVoter.claimRewardsAndLock(targets, 0, MAXTIME);

        assertEq(realEscrow.tokenId(), 1);
        assertEq(escrow.ownerOf(id), users.alice);
        assertEq(_amount(id), v2Reward + clReward);
        assertEq(rewardToken.balanceOf(address(escrow)), v2Reward + clReward);
        assertEq(rewardToken.balanceOf(users.alice), 0);
        assertEq(rewardToken.balanceOf(v2), TOKEN_1 - v2Reward);
        assertEq(rewardToken.balanceOf(address(firstGauge)), TOKEN_1 - clReward);
        assertEq(RealV2ClaimGauge(v2).earned(users.alice), 0);
        assertEq(firstGauge.earned(users.alice, position), 0);
        assertEq(rewardToken.allowance(v2, address(escrow)), 0);
        assertEq(rewardToken.allowance(address(firstGauge), address(escrow)), 0);
        assertEq(mixedHook.calls(), 2);
        assertEq(mixedHook.ids(v2), id);
        assertEq(mixedHook.ids(address(firstGauge)), id);
        assertEq(mixedHook.amounts(v2), v2Reward);
        assertEq(mixedHook.amounts(address(firstGauge)), clReward);
        assertEq(mixedHook.users(v2), users.alice);
        assertEq(mixedHook.users(address(firstGauge)), users.alice);
        assertEq(mixedHook.pools(v2), address(token0));
        assertEq(mixedHook.pools(address(firstGauge)), address(firstPool));
    }
}
