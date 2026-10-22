// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import "./CLGauge.t.sol";

/// @dev ABI bridge to the actual 0.8.30 escrow deployed from the sibling build artifact.
interface PrivateConcreteRealClaimEscrow {
    struct LockedBalance {
        int128 amount;
        uint256 end;
        bool isPermanent;
    }

    struct TeamLock {
        uint256 startTs;
        uint256 endTs;
        bool clawbacked;
    }

    function teamLocks(uint256 id) external view returns (TeamLock memory);

    function locked(uint256 id) external view returns (LockedBalance memory);

    function tokenId() external view returns (uint256);

    function permanentLockBalance() external view returns (uint256);

    function lockPermanent(uint256 id) external;

    function createTeamLockFor(uint256 amount, uint256 duration, address user, uint256 end) external returns (uint256);

    function setVoterAndDistributor(address voter, address distributor) external;
}

interface PrivateConcreteClaimVoter {
    function setClaimHook(address hook) external;

    function claimHook() external view returns (address);

    function claimRewardsAndLock(address[] calldata gauges, uint256 id, uint256 duration) external returns (uint256);
}

contract PrivateConcreteCLRecordingClaimHook {
    uint256 public calls;
    uint256 public id;
    uint256 public amount;
    address public user;
    address public gauge;
    address public pool;
    address public failGauge;
    bool public reenter;
    bool public reentryBlocked;
    mapping(address => uint256) public callsByGauge;
    mapping(address => address) public poolsByGauge;
    mapping(address => uint256) public amountsByGauge;

    function configure(address _failGauge, bool _reenter) external {
        failGauge = _failGauge;
        reenter = _reenter;
    }

    function onClaim(uint256 _id, uint256 _amount, address _user, address _gauge) external {
        require(msg.sender == _gauge, "hook caller mismatch");
        calls++;
        callsByGauge[_gauge]++;
        id = _id;
        amount = _amount;
        user = _user;
        gauge = _gauge;
        pool = address(CLGauge(_gauge).pool());
        poolsByGauge[_gauge] = pool;
        amountsByGauge[_gauge] = _amount;
        require(_gauge != failGauge, "hook failure");
        if (reenter) {
            (bool success, bytes memory reason) = _gauge.call(
                abi.encodeWithSignature("getRewardAndLock(address,uint256,uint256)", _user, _id, uint256(0))
            );
            reentryBlocked = !success
                && keccak256(reason)
                    == keccak256(abi.encodeWithSignature("Error(string)", "ReentrancyGuard: reentrant call"));
        }
    }
}

/// @dev Shares the real 0.8.30 escrow deployment across CL integration suites.
abstract contract PrivateConcreteRealEscrowArtifactDeployer is Test {
    struct LinkReference {
        uint256 length;
        uint256 start;
    }

    function _linkArtifact(bytes memory code, string memory artifact, string memory key, address libraryAddress)
        internal
    {
        LinkReference[] memory refs = abi.decode(vm.parseJson(artifact, key), (LinkReference[]));
        bytes memory addressHex = bytes(vm.toString(libraryAddress));
        for (uint256 r; r < refs.length; r++) {
            require(refs[r].length == 20, "unexpected library reference");
            uint256 start = 2 + refs[r].start * 2;
            for (uint256 i; i < 40; i++) {
                code[start + i] = addressHex[2 + i];
            }
        }
    }

    function _coreArtifactPath(string memory path) internal returns (string memory) {
        return string(abi.encodePacked(vm.envOr("ICARUS_CORE_ARTIFACTS", string("../contracts/out")), "/", path));
    }

    function _deployCoreArtifact(string memory path, bytes memory args) internal returns (address) {
        return deployCode(_coreArtifactPath(path), args);
    }

    function _deployRealClaimEscrow(address trustedForwarder, address token, address registry)
        internal
        returns (address deployed)
    {
        string memory artifactRoot = vm.envOr("ICARUS_CORE_ARTIFACTS", string("../contracts/out"));
        address balanceLogic =
            deployCode(string(abi.encodePacked(artifactRoot, "/BalanceLogicLibrary.sol/BalanceLogicLibrary.json")));
        address delegationLogic = deployCode(
            string(abi.encodePacked(artifactRoot, "/DelegationLogicLibrary.sol/DelegationLogicLibrary.json"))
        );
        string memory artifact =
            vm.readFile(string(abi.encodePacked(artifactRoot, "/VotingEscrow.sol/VotingEscrow.json")));
        bytes memory code = bytes(vm.parseJsonString(artifact, ".bytecode.object"));
        _linkArtifact(
            code,
            artifact,
            '.bytecode.linkReferences["contracts/libraries/BalanceLogicLibrary.sol"].BalanceLogicLibrary',
            balanceLogic
        );
        _linkArtifact(
            code,
            artifact,
            '.bytecode.linkReferences["contracts/libraries/DelegationLogicLibrary.sol"].DelegationLogicLibrary',
            delegationLogic
        );
        bytes memory creation =
            abi.encodePacked(vm.parseBytes(string(code)), abi.encode(trustedForwarder, token, registry));
        assembly { deployed := create(0, add(creation, 32), mload(creation)) }
        require(deployed != address(0), "real escrow deployment failed");
    }
}

contract PrivateConcreteClaimAndLockTest is PrivateConcreteCLGaugeTest, PrivateConcreteRealEscrowArtifactDeployer {
    CLPool public pool;
    CLGauge public gauge;
    PrivateConcreteRealClaimEscrow internal realEscrow;
    PrivateConcreteClaimVoter internal claimVoter;
    PrivateConcreteCLRecordingClaimHook internal hook;
    uint256 internal constant MAXTIME = 4 * 365 days;

    function deployDependencies() public override {
        factoryRegistry = IFactoryRegistry(new MockFactoryRegistry());
        votingRewardsFactory = IVotingRewardsFactory(new MockVotingRewardsFactory());
        weth = IERC20(address(new MockWETH()));
        address deployed = _deployRealClaimEscrow(address(11), address(rewardToken), address(factoryRegistry));
        escrow = IVotingEscrow(deployed);
        realEscrow = PrivateConcreteRealClaimEscrow(deployed);
        voter = IVoter(new MockVoter(address(rewardToken), address(factoryRegistry), deployed));
        realEscrow.setVoterAndDistributor(address(voter), address(0));
        claimVoter = PrivateConcreteClaimVoter(address(voter));
    }

    function setUp() public override {
        super.setUp();
        pool = CLPool(poolFactory.createPool(address(token0), address(token1), TICK_SPACING_60, encodePriceSqrt(1, 1)));
        gauge = CLGauge(voter.createGauge(address(poolFactory), address(pool)));
        _activateIRS(gauge);
        hook = new PrivateConcreteCLRecordingClaimHook();
        vm.prank(users.owner);
        claimVoter.setClaimHook(address(hook));
        skipToNextEpoch(0);
        vm.startPrank(users.alice);
    }

    function _stake() internal returns (uint256 id) {
        id = nftCallee.mintNewCustomRangePositionForUserWith60TickSpacing(
            TOKEN_1, TOKEN_1, -TICK_SPACING_60, TICK_SPACING_60, users.alice
        );
        nft.approve(address(gauge), id);
        gauge.deposit(id);
    }

    function _accrue(uint256 id) internal returns (uint256 reward) {
        addRewardToGauge(address(voter), address(gauge), TOKEN_1);
        skip(2 days);
        vm.startPrank(users.alice);
        reward = gauge.earned(users.alice, id);
        assertGt(reward, 0);
    }

    function _lock(address user, uint256 duration) internal returns (uint256 id) {
        deal(address(rewardToken), user, TOKEN_1);
        vm.startPrank(user);
        rewardToken.approve(address(escrow), TOKEN_1);
        id = escrow.createLock(TOKEN_1, duration);
        vm.startPrank(users.alice);
    }

    function _amount(uint256 id) internal view returns (uint256) {
        return uint256(uint128(realEscrow.locked(id).amount));
    }

    function _assertHook(uint256 id, uint256 reward) internal {
        assertEq(hook.calls(), 1);
        assertEq(hook.id(), id);
        assertEq(hook.amount(), reward);
        assertEq(hook.user(), users.alice);
        assertEq(hook.gauge(), address(gauge));
        assertEq(hook.pool(), address(pool));
    }

    function test_NewLockPositionClaimUsesActualEscrowAndNoUserApproval() public {
        uint256 pos = _stake();
        uint256 reward = _accrue(pos);
        uint256 balance = rewardToken.balanceOf(address(gauge));
        uint256 id = gauge.getRewardAndLock(pos, 0, MAXTIME);
        assertEq(escrow.ownerOf(id), users.alice);
        assertEq(_amount(id), reward);
        assertEq(realEscrow.locked(id).end, ((block.timestamp + MAXTIME) / WEEK) * WEEK);
        assertEq(rewardToken.balanceOf(users.alice), 0);
        assertEq(rewardToken.balanceOf(address(escrow)), reward);
        assertEq(rewardToken.balanceOf(address(gauge)), balance - reward);
        assertEq(rewardToken.allowance(address(gauge), address(escrow)), 0);
        assertEq(gauge.rewards(pos), 0);
        assertEq(gauge.earned(users.alice, pos), 0);
        assertEq(gauge.lastUpdateTime(pos), block.timestamp);
        _assertHook(id, reward);
    }

    function test_ExistingLockAmountIncreasesAndExpiryUnchanged() public {
        uint256 id = _lock(users.alice, MAXTIME);
        uint256 expiry = realEscrow.locked(id).end;
        uint256 pos = _stake();
        uint256 reward = _accrue(pos);
        assertEq(gauge.getRewardAndLock(users.alice, id, 0), id);
        assertEq(_amount(id), TOKEN_1 + reward);
        assertEq(realEscrow.locked(id).end, expiry);
        assertEq(rewardToken.balanceOf(users.alice), 0);
        _assertHook(id, reward);
    }

    function test_PermanentLockAmountAndPermanentSupplyIncrease() public {
        uint256 id = _lock(users.alice, MAXTIME);
        realEscrow.lockPermanent(id);
        uint256 pos = _stake();
        uint256 reward = _accrue(pos);
        uint256 permanent = realEscrow.permanentLockBalance();
        gauge.getRewardAndLock(pos, id, 0);
        assertTrue(realEscrow.locked(id).isPermanent);
        assertEq(_amount(id), TOKEN_1 + reward);
        assertEq(realEscrow.permanentLockBalance(), permanent + reward);
    }

    function test_AllPositionsAggregateOneNewLockAndOneCallback() public {
        uint256 first = _stake();
        uint256 second = _stake();
        _accrue(first);
        uint256 reward = gauge.earned(users.alice, first) + gauge.earned(users.alice, second);
        uint256 count = realEscrow.tokenId();
        uint256 id = gauge.getRewardAndLock(users.alice, 0, MAXTIME);
        assertEq(realEscrow.tokenId(), count + 1);
        assertEq(_amount(id), reward);
        assertEq(gauge.rewards(first), 0);
        assertEq(gauge.rewards(second), 0);
        assertEq(gauge.earned(users.alice, first), 0);
        assertEq(gauge.earned(users.alice, second), 0);
        _assertHook(id, reward);
    }

    function test_ClaimOnlySelectedPositionLeavesOthersClaimable() public {
        uint256 first = _stake();
        uint256 second = _stake();
        _accrue(first);
        uint256 secondReward = gauge.earned(users.alice, second);
        gauge.getRewardAndLock(first, 0, MAXTIME);
        assertEq(gauge.earned(users.alice, first), 0);
        assertEq(gauge.earned(users.alice, second), secondReward);
    }

    function test_ZeroRewardSkipsNFTAndHook() public {
        uint256 pos = _stake();
        assertEq(gauge.getRewardAndLock(pos, 0, MAXTIME), 0);
        assertEq(gauge.getRewardAndLock(users.alice, 0, MAXTIME), 0);
        assertEq(realEscrow.tokenId(), 0);
        assertEq(hook.calls(), 0);
    }

    function test_OutOfRangeSkipsNFTAndHook() public {
        uint256 pos = nftCallee.mintNewCustomRangePositionForUserWith60TickSpacing(
            TOKEN_1, TOKEN_1, TICK_SPACING_60, 2 * TICK_SPACING_60, users.alice
        );
        nft.approve(address(gauge), pos);
        gauge.deposit(pos);
        addRewardToGauge(address(voter), address(gauge), TOKEN_1);
        skip(2 days);
        vm.startPrank(users.alice);
        assertEq(gauge.getRewardAndLock(pos, 0, MAXTIME), 0);
        assertEq(realEscrow.tokenId(), 0);
        assertEq(hook.calls(), 0);
        assertEq(rewardToken.balanceOf(address(gauge)), TOKEN_1);
    }

    function test_UnauthorizedPositionAndAccountClaimsRevert() public {
        uint256 pos = _stake();
        uint256 reward = _accrue(pos);
        vm.startPrank(users.bob);
        vm.expectRevert(bytes("NA"));
        gauge.getRewardAndLock(pos, 0, MAXTIME);
        vm.expectRevert(bytes("NA"));
        gauge.getRewardAndLock(users.alice, 0, MAXTIME);
        assertEq(gauge.earned(users.alice, pos), reward);
    }

    function test_ForeignVeNFTRejectedEvenWithApproval() public {
        uint256 id = _lock(users.bob, MAXTIME);
        vm.stopPrank();
        vm.startPrank(users.bob);
        escrow.approve(users.alice, id);
        vm.startPrank(users.alice);
        uint256 pos = _stake();
        _accrue(pos);
        vm.expectRevert(bytes("NA"));
        gauge.getRewardAndLock(pos, id, 0);
        assertEq(_amount(id), TOKEN_1);
    }

    function test_ExistingLockRejectsDuration() public {
        uint256 id = _lock(users.alice, MAXTIME);
        uint256 pos = _stake();
        _accrue(pos);
        vm.expectRevert(bytes("IP"));
        gauge.getRewardAndLock(pos, id, WEEK);
    }

    function test_ExpiredLockRejectedWithoutLosingRewards() public {
        uint256 id = _lock(users.alice, WEEK);
        uint256 pos = _stake();
        _accrue(pos);
        vm.warp(realEscrow.locked(id).end + 1);
        uint256 reward = gauge.earned(users.alice, pos);
        vm.expectRevert(abi.encodeWithSignature("LockExpired()"));
        gauge.getRewardAndLock(pos, id, 0);
        assertEq(gauge.earned(users.alice, pos), reward);
        assertEq(_amount(id), TOKEN_1);
    }

    function test_InvalidNewDurationRejectedWithoutLosingRewards() public {
        uint256 pos = _stake();
        uint256 reward = _accrue(pos);
        vm.expectRevert(abi.encodeWithSignature("LockDurationNotInFuture()"));
        gauge.getRewardAndLock(pos, 0, 0);
        vm.expectRevert(abi.encodeWithSignature("LockDurationTooLong()"));
        gauge.getRewardAndLock(pos, 0, MAXTIME + WEEK);
        assertEq(gauge.earned(users.alice, pos), reward);
        assertEq(rewardToken.allowance(address(gauge), address(escrow)), 0);
    }

    function test_LiquidClaimAndWithdrawInvokeZeroLockedCallback() public {
        uint256 pos = _stake();
        uint256 reward = _accrue(pos);
        gauge.getReward(pos);
        _assertHook(0, 0);
        assertEq(rewardToken.balanceOf(users.alice), reward);
        skip(1 days);
        gauge.withdraw(pos);
        assertEq(hook.calls(), 2);
        assertEq(hook.id(), 0);
        assertEq(hook.amount(), 0);
        assertEq(nft.ownerOf(pos), users.alice);
        assertFalse(gauge.stakedContains(users.alice, pos));
        vm.expectRevert(bytes("NA"));
        gauge.getRewardAndLock(pos, 0, MAXTIME);
    }

    function test_KilledGaugeRetainsClaimableLockedRewards() public {
        uint256 pos = _stake();
        uint256 reward = _accrue(pos);
        voter.killGauge(address(gauge));
        uint256 id = gauge.getRewardAndLock(pos, 0, MAXTIME);
        assertEq(_amount(id), reward);
        _assertHook(id, reward);
    }

    function test_HookFailurePreservesLockBalancesAndPoolAccounting() public {
        uint256 first = _stake();
        uint256 second = _stake();
        _accrue(first);
        uint256 reward = gauge.earned(users.alice, first) + gauge.earned(users.alice, second);
        uint256 balance = rewardToken.balanceOf(address(gauge));
        uint256 reserve = pool.rewardReserve();
        uint256 growth = pool.rewardGrowthGlobalX128();
        hook.configure(address(gauge), false);
        uint256 id = gauge.getRewardAndLock(users.alice, 0, MAXTIME);
        assertEq(gauge.earned(users.alice, first), 0);
        assertEq(gauge.earned(users.alice, second), 0);
        assertEq(rewardToken.balanceOf(address(gauge)), balance - reward);
        assertEq(rewardToken.balanceOf(address(escrow)), reward);
        assertEq(_amount(id), reward);
        assertEq(escrow.ownerOf(id), users.alice);
        assertEq(rewardToken.balanceOf(users.alice), 0);
        assertEq(realEscrow.tokenId(), 1);
        assertEq(rewardToken.allowance(address(gauge), address(escrow)), 0);
        assertLt(pool.rewardReserve(), reserve);
        assertGt(pool.rewardGrowthGlobalX128(), growth);
        assertEq(pool.lastUpdated(), block.timestamp);
        assertEq(gauge.lastUpdateTime(first), block.timestamp);
        assertEq(hook.calls(), 0);
        assertEq(gauge.getRewardAndLock(users.alice, id, 0), id);
        assertEq(_amount(id), reward);
    }

    function test_HookFailureDoesNotBlockWithdrawAndReward() public {
        uint256 pos = _stake();
        uint256 reward = _accrue(pos);
        hook.configure(address(gauge), false);
        gauge.withdraw(pos);
        assertEq(nft.ownerOf(pos), users.alice);
        assertFalse(gauge.stakedContains(users.alice, pos));
        assertEq(uint256(pool.stakedLiquidity()), 0);
        assertEq(gauge.rewards(pos), 0);
        assertEq(rewardToken.balanceOf(users.alice), reward);
        assertEq(hook.calls(), 0);
    }

    function test_HookReentryBlocked() public {
        uint256 pos = _stake();
        _accrue(pos);
        hook.configure(address(0), true);
        gauge.getRewardAndLock(pos, 0, MAXTIME);
        assertTrue(hook.reentryBlocked());
        assertEq(hook.calls(), 1);
    }

    function test_GlobalHookReplacementAndDisableUseLatestConfig() public {
        uint256 pos = _stake();
        _accrue(pos);
        PrivateConcreteCLRecordingClaimHook replacement = new PrivateConcreteCLRecordingClaimHook();
        vm.startPrank(users.owner);
        claimVoter.setClaimHook(address(replacement));
        vm.startPrank(users.alice);
        gauge.getReward(pos);
        assertEq(hook.calls(), 0);
        assertEq(replacement.calls(), 1);
        vm.startPrank(users.owner);
        claimVoter.setClaimHook(address(0));
        vm.startPrank(users.alice);
        skip(1 days);
        gauge.getReward(pos);
        assertEq(replacement.calls(), 1);
    }

    function _secondGauge(bool stakePosition) internal returns (CLGauge second, uint256 pos) {
        CLPool secondPool =
            CLPool(poolFactory.createPool(address(token0), address(token1), TICK_SPACING_200, encodePriceSqrt(1, 1)));
        second = CLGauge(voter.createGauge(address(poolFactory), address(secondPool)));
        _activateIRS(second);
        if (stakePosition) {
            pos = nftCallee.mintNewCustomRangePositionForUserWithCustomTickSpacing(
                TOKEN_1, TOKEN_1, -TICK_SPACING_200, TICK_SPACING_200, TICK_SPACING_200, users.alice
            );
            nft.approve(address(second), pos);
            second.deposit(pos);
        }
    }

    function test_VoterBatchLocksTwoGaugesIntoOneVeNFT() public {
        uint256 pos = _stake();
        (CLGauge second, uint256 secondPos) = _secondGauge(true);
        addRewardToGauge(address(voter), address(gauge), TOKEN_1);
        addRewardToGauge(address(voter), address(second), TOKEN_1);
        skip(2 days);
        vm.startPrank(users.alice);
        uint256 firstReward = gauge.earned(users.alice, pos);
        uint256 secondReward = second.earned(users.alice, secondPos);
        address[] memory gauges = new address[](2);
        gauges[0] = address(gauge);
        gauges[1] = address(second);
        uint256 id = claimVoter.claimRewardsAndLock(gauges, 0, MAXTIME);
        assertEq(_amount(id), firstReward + secondReward);
        assertEq(realEscrow.tokenId(), 1);
        assertEq(hook.calls(), 2);
        assertEq(hook.callsByGauge(address(gauge)), 1);
        assertEq(hook.callsByGauge(address(second)), 1);
        assertEq(hook.poolsByGauge(address(gauge)), address(pool));
        assertEq(hook.poolsByGauge(address(second)), address(second.pool()));
        assertEq(hook.amountsByGauge(address(gauge)), firstReward);
        assertEq(hook.amountsByGauge(address(second)), secondReward);
        assertEq(hook.id(), id);
        assertEq(rewardToken.allowance(address(second), address(escrow)), 0);
    }

    function test_VoterBatchEmptyFirstGaugeStillCreatesOneLock() public {
        uint256 pos = _stake();
        uint256 reward = _accrue(pos);
        (CLGauge second,) = _secondGauge(false);
        address[] memory gauges = new address[](2);
        gauges[0] = address(second);
        gauges[1] = address(gauge);
        uint256 id = claimVoter.claimRewardsAndLock(gauges, 0, MAXTIME);
        assertEq(_amount(id), reward);
        _assertHook(id, reward);
    }

    function test_VoterBatchFirstHookFailureStillSettlesBothGauges() public {
        uint256 pos = _stake();
        (CLGauge second, uint256 secondPos) = _secondGauge(true);
        addRewardToGauge(address(voter), address(gauge), TOKEN_1);
        addRewardToGauge(address(voter), address(second), TOKEN_1);
        skip(2 days);
        vm.startPrank(users.alice);
        uint256 firstReward = gauge.earned(users.alice, pos);
        uint256 secondReward = second.earned(users.alice, secondPos);
        hook.configure(address(gauge), false);
        address[] memory gauges = new address[](2);
        gauges[0] = address(gauge);
        gauges[1] = address(second);
        uint256 id = claimVoter.claimRewardsAndLock(gauges, 0, MAXTIME);
        assertEq(gauge.earned(users.alice, pos), 0);
        assertEq(second.earned(users.alice, secondPos), 0);
        assertEq(realEscrow.tokenId(), 1);
        assertEq(_amount(id), firstReward + secondReward);
        assertEq(rewardToken.balanceOf(address(escrow)), firstReward + secondReward);
        assertEq(rewardToken.allowance(address(gauge), address(escrow)), 0);
        assertEq(rewardToken.allowance(address(second), address(escrow)), 0);
        assertEq(hook.calls(), 1);
        assertEq(hook.gauge(), address(second));
        assertEq(hook.id(), id);
        assertEq(hook.amount(), secondReward);
    }

    function test_TeamLockAdditionPreservesVesting() public {
        deal(address(rewardToken), users.owner, TOKEN_1);
        vm.startPrank(users.owner);
        rewardToken.approve(address(escrow), TOKEN_1);
        uint256 id = realEscrow.createTeamLockFor(TOKEN_1, MAXTIME, users.alice, block.timestamp + WEEK);
        PrivateConcreteRealClaimEscrow.TeamLock memory beforeTeam = realEscrow.teamLocks(id);
        uint256 expiry = realEscrow.locked(id).end;
        vm.startPrank(users.alice);
        uint256 pos = _stake();
        uint256 reward = _accrue(pos);
        assertEq(gauge.getRewardAndLock(pos, id, 0), id);
        assertEq(gauge.earned(users.alice, pos), 0);
        assertEq(_amount(id), TOKEN_1 + reward);
        assertEq(realEscrow.locked(id).end, expiry);
        PrivateConcreteRealClaimEscrow.TeamLock memory afterTeam = realEscrow.teamLocks(id);
        assertEq(afterTeam.startTs, beforeTeam.startTs);
        assertEq(afterTeam.endTs, beforeTeam.endTs);
        assertEq(afterTeam.clawbacked, beforeTeam.clawbacked);
        assertEq(rewardToken.allowance(address(gauge), address(escrow)), 0);
        _assertHook(id, reward);
    }

    function test_HookFailurePreservesExistingLockAddition() public {
        uint256 id = _lock(users.alice, MAXTIME);
        uint256 expiry = realEscrow.locked(id).end;
        uint256 pos = _stake();
        uint256 reward = _accrue(pos);
        hook.configure(address(gauge), false);
        assertEq(gauge.getRewardAndLock(pos, id, 0), id);
        assertEq(_amount(id), TOKEN_1 + reward);
        assertEq(realEscrow.locked(id).end, expiry);
        assertEq(gauge.earned(users.alice, pos), 0);
        assertEq(rewardToken.balanceOf(address(escrow)), TOKEN_1 + reward);
        assertEq(rewardToken.allowance(address(gauge), address(escrow)), 0);
    }

    function test_HookFailurePreservesLiquidRewardWithoutDoublePayment() public {
        uint256 pos = _stake();
        uint256 reward = _accrue(pos);
        hook.configure(address(gauge), false);
        gauge.getReward(pos);
        assertEq(rewardToken.balanceOf(users.alice), reward);
        assertEq(gauge.earned(users.alice, pos), 0);
        gauge.getReward(pos);
        assertEq(rewardToken.balanceOf(users.alice), reward);
    }

    function test_LegacyVoterLiquidClaimContinuesAfterEachHookFailure() public {
        uint256 first = _stake();
        uint256 second = _stake();
        _accrue(first);
        uint256 reward = gauge.earned(users.alice, first) + gauge.earned(users.alice, second);
        hook.configure(address(gauge), false);
        address[] memory gauges = new address[](1);
        gauges[0] = address(gauge);
        voter.claimRewards(gauges);
        assertEq(rewardToken.balanceOf(users.alice), reward);
        assertEq(gauge.earned(users.alice, first), 0);
        assertEq(gauge.earned(users.alice, second), 0);
        assertEq(hook.calls(), 0);
        assertEq(hook.callsByGauge(address(gauge)), 0);
    }

    function test_LegacyVoterLiquidClaimPaysEachPositionAndInvokesHook() public {
        uint256 first = _stake();
        uint256 second = _stake();
        _accrue(first);
        uint256 reward = gauge.earned(users.alice, first) + gauge.earned(users.alice, second);
        address[] memory gauges = new address[](1);
        gauges[0] = address(gauge);
        voter.claimRewards(gauges);
        assertEq(rewardToken.balanceOf(users.alice), reward);
        assertEq(hook.calls(), 2);
        assertEq(hook.id(), 0);
        assertEq(hook.amount(), 0);
    }

    function test_MismatchedRewardTokenCannotBeLocked() public {
        CLGauge mismatched = new CLGauge();
        mismatched.initialize(
            address(pool),
            address(0),
            address(token0),
            address(voter),
            address(nft),
            address(token0),
            address(token1),
            TICK_SPACING_60,
            true
        );
        vm.expectRevert(bytes("IRT"));
        mismatched.getRewardAndLock(users.alice, 0, MAXTIME);
    }

    function test_ZeroRewardExistingLockReturnsSameId() public {
        uint256 id = _lock(users.alice, MAXTIME);
        uint256 pos = _stake();
        assertEq(gauge.getRewardAndLock(pos, id, 0), id);
        assertEq(gauge.getRewardAndLock(users.alice, id, 0), id);
        assertEq(_amount(id), TOKEN_1);
        assertEq(hook.calls(), 0);
    }

    function testFuzz_MultiPositionConservation(uint96 funding, uint32 elapsed, uint8 count) public {
        uint256 amount = bound(uint256(funding), TOKEN_1, TOKEN_1 * 1_000_000);
        uint256 delay = bound(uint256(elapsed), 1, 6 days);
        uint256 positions = bound(uint256(count), 1, 5);
        uint256[] memory ids = new uint256[](positions);
        for (uint256 i; i < positions; i++) {
            ids[i] = _stake();
        }
        addRewardToGauge(address(voter), address(gauge), amount);
        skip(delay);
        vm.startPrank(users.alice);
        uint256 reward;
        for (uint256 i; i < positions; i++) {
            reward += gauge.earned(users.alice, ids[i]);
        }
        uint256 id = gauge.getRewardAndLock(users.alice, 0, MAXTIME);
        assertEq(_amount(id), reward);
        assertEq(rewardToken.balanceOf(address(gauge)), amount - reward);
        assertEq(rewardToken.balanceOf(address(escrow)), reward);
        assertEq(rewardToken.balanceOf(users.alice), 0);
        assertEq(rewardToken.allowance(address(gauge), address(escrow)), 0);
        assertEq(realEscrow.tokenId(), 1);
        for (uint256 i; i < positions; i++) {
            assertEq(gauge.earned(users.alice, ids[i]), 0);
        }
        _assertHook(id, reward);
    }
}
