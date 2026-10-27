// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/ERC721Holder.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {ICLGauge} from "contracts/gauge/interfaces/ICLGauge.sol";
import {ICLPrivateGauge} from "contracts/gauge/interfaces/ICLPrivateGauge.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ICLGaugeFactory} from "contracts/gauge/interfaces/ICLGaugeFactory.sol";
import {IVoter} from "contracts/core/interfaces/IVoter.sol";
import {IVotingEscrow} from "contracts/core/interfaces/IVotingEscrow.sol";
import {ICLPool} from "contracts/core/interfaces/ICLPool.sol";
import {INonfungiblePositionManager} from "contracts/periphery/interfaces/INonfungiblePositionManager.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EnumerableSet} from "contracts/libraries/EnumerableSet.sol";
import {SafeCast} from "contracts/gauge/libraries/SafeCast.sol";
import {FullMath} from "contracts/core/libraries/FullMath.sol";
import {FixedPoint128} from "contracts/core/libraries/FixedPoint128.sol";
import {ProtocolTimeLibrary} from "contracts/libraries/ProtocolTimeLibrary.sol";
import {IReward} from "contracts/gauge/interfaces/IReward.sol";
import {IClaimHook} from "contracts/gauge/interfaces/IClaimHook.sol";
import {SafeMath} from "@openzeppelin/contracts/math/SafeMath.sol";

/// @notice Private gauge with one prefunded initial rewards campaign followed permanently by IRS.
/// @dev Isolated fork of CLGauge. Pool growth is reused sequentially, never reset.
contract CLPrivateGauge is ICLPrivateGauge, ERC721Holder, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.UintSet;
    using SafeERC20 for IERC20;
    using SafeCast for uint128;
    using SafeMath for uint256;

    uint256 public constant INITIAL_REWARDS_PAYOUT_GAS = 150_000;

    Phase public override phase;
    address public override initialRewardToken;
    address public override initialRewardFunder;
    uint256 public override initialRewardRate;
    uint256 public override initialPeriodFinish;
    uint256 public override initialRewardDust;
    uint256 public override stoppedInitialRewardReserve;
    uint256 public override stoppedInitialRewardRollover;
    uint256 public override queuedIRS;
    uint256 public override totalInitialRewardsFunded;
    uint256 public override totalInitialRewardsPaid;
    uint256 public override totalInitialRewardsCredits;
    uint256 public override totalInitialRewardsRefunded;
    mapping(address => uint256) public override initialRewardCredits;
    mapping(uint256 => address) public override stakerOf;
    // Active initial rewards positions become the pending transition set without copying.
    EnumerableSet.UintSet private _pending;

    modifier onlyTeam() {
        require(msg.sender == IVotingEscrow(voter.ve()).team(), "NT");
        _;
    }

    /// @inheritdoc ICLGauge
    INonfungiblePositionManager public override nft;
    /// @inheritdoc ICLGauge
    IVoter public override voter;
    /// @inheritdoc ICLGauge
    ICLPool public override pool;

    /// @inheritdoc ICLGauge
    address public override feesVotingReward;
    /// @inheritdoc ICLGauge
    address public override rewardToken;

    /// @inheritdoc ICLGauge
    uint256 public override periodFinish;
    /// @inheritdoc ICLGauge
    uint256 public override rewardRate;

    mapping(uint256 => uint256) public override rewardRateByEpoch; // epochStart => rewardRate
    /// @dev The set of all staked nfts for a given address
    mapping(address => EnumerableSet.UintSet) internal _stakes;
    /// @inheritdoc ICLGauge
    mapping(uint256 => uint256) public override rewardGrowthInside;

    /// @inheritdoc ICLGauge
    mapping(uint256 => uint256) public override rewards;
    /// @inheritdoc ICLGauge
    mapping(uint256 => uint256) public override lastUpdateTime;

    /// @inheritdoc ICLGauge
    uint256 public override fees0;
    /// @inheritdoc ICLGauge
    uint256 public override fees1;
    /// @inheritdoc ICLGauge
    address public override token0;
    /// @inheritdoc ICLGauge
    address public override token1;
    /// @inheritdoc ICLGauge
    int24 public override tickSpacing;

    /// @inheritdoc ICLGauge
    bool public override isPool;

    /// @inheritdoc ICLGauge
    ICLGaugeFactory public override factory;

    /// @inheritdoc ICLGauge
    function initialize(
        address _pool,
        address _feesVotingReward,
        address _rewardToken,
        address _voter,
        address _nft,
        address _token0,
        address _token1,
        int24 _tickSpacing,
        bool _isPool
    ) external override {
        require(address(pool) == address(0), "AI");
        factory = ICLGaugeFactory(msg.sender);
        pool = ICLPool(_pool);
        feesVotingReward = _feesVotingReward;
        rewardToken = _rewardToken;
        voter = IVoter(_voter);
        nft = INonfungiblePositionManager(_nft);
        token0 = _token0;
        token1 = _token1;
        tickSpacing = _tickSpacing;
        isPool = _isPool;
    }

    // updates the claimable rewards and lastUpdateTime for tokenId
    function _updateRewards(uint256 tokenId, int24 tickLower, int24 tickUpper) internal {
        if (lastUpdateTime[tokenId] == block.timestamp) return;
        pool.updateRewardsGrowthGlobal();
        lastUpdateTime[tokenId] = block.timestamp;
        rewards[tokenId] = rewards[tokenId].add(_earned(tokenId));
        rewardGrowthInside[tokenId] = pool.getRewardGrowthInside(tickLower, tickUpper, 0);
    }

    /// @inheritdoc ICLGauge
    function earned(address account, uint256 tokenId) external view override returns (uint256) {
        require(_stakes[account].contains(tokenId), "NA");

        if (phase != Phase.IRS) return 0;
        return rewards[tokenId].add(_earned(tokenId));
    }

    function _earned(uint256 tokenId) internal view returns (uint256) {
        uint256 lastUpdated = pool.lastUpdated();

        uint256 timeDelta = block.timestamp - lastUpdated;

        uint256 rewardGrowthGlobalX128 = pool.rewardGrowthGlobalX128();
        uint256 rewardReserve = pool.rewardReserve();

        if (timeDelta != 0 && rewardReserve > 0 && pool.stakedLiquidity() > 0) {
            uint256 rate = phase == Phase.IRS ? rewardRate : initialRewardRate;
            uint256 reward = rate.mul(timeDelta);
            if (reward > rewardReserve) reward = rewardReserve;

            rewardGrowthGlobalX128 += FullMath.mulDiv(reward, FixedPoint128.Q128, pool.stakedLiquidity());
        }

        (,,,,, int24 tickLower, int24 tickUpper, uint128 liquidity,,,,) = nft.positions(tokenId);

        uint256 rewardPerTokenInsideInitialX128 = rewardGrowthInside[tokenId];
        uint256 rewardPerTokenInsideX128 = pool.getRewardGrowthInside(tickLower, tickUpper, rewardGrowthGlobalX128);

        uint256 claimable =
            FullMath.mulDiv(rewardPerTokenInsideX128 - rewardPerTokenInsideInitialX128, liquidity, FixedPoint128.Q128);
        return claimable;
    }

    /// @inheritdoc ICLGauge
    function getReward(address account) external override nonReentrant {
        require(msg.sender == address(voter), "NV");

        if (phase != Phase.IRS) return;
        uint256[] memory tokenIds = _stakes[account].values();
        uint256 length = tokenIds.length;
        uint256 tokenId;
        int24 tickLower;
        int24 tickUpper;
        for (uint256 i = 0; i < length; i++) {
            tokenId = tokenIds[i];
            (,,,,, tickLower, tickUpper,,,,,) = nft.positions(tokenId);
            _getReward(tickLower, tickUpper, tokenId, account);
        }
    }

    /// @inheritdoc ICLGauge
    function getReward(uint256 tokenId) external override nonReentrant {
        require(_stakes[msg.sender].contains(tokenId), "NA");

        if (phase != Phase.IRS) return;
        (,,,,, int24 tickLower, int24 tickUpper,,,,,) = nft.positions(tokenId);
        _getReward(tickLower, tickUpper, tokenId, msg.sender);
    }

    function _getReward(int24 tickLower, int24 tickUpper, uint256 tokenId, address owner) internal {
        _settleReward(owner, _takeReward(tickLower, tickUpper, tokenId), false, 0, 0);
    }

    /// @inheritdoc ICLGauge
    function getRewardAndLock(address account, uint256 veTokenId, uint256 lockDuration)
        external
        override
        nonReentrant
        returns (uint256)
    {
        require(msg.sender == account || msg.sender == address(voter), "NA");
        _validateLock(account, veTokenId, lockDuration);
        uint256[] memory tokenIds = _stakes[account].values();
        uint256 reward;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            (,,,,, int24 tickLower, int24 tickUpper,,,,,) = nft.positions(tokenIds[i]);
            reward = reward.add(_takeReward(tickLower, tickUpper, tokenIds[i]));
        }
        return _settleReward(account, reward, true, veTokenId, lockDuration);
    }

    /// @inheritdoc ICLGauge
    function getRewardAndLock(uint256 tokenId, uint256 veTokenId, uint256 lockDuration)
        external
        override
        nonReentrant
        returns (uint256)
    {
        require(_stakes[msg.sender].contains(tokenId), "NA");
        _validateLock(msg.sender, veTokenId, lockDuration);
        (,,,,, int24 tickLower, int24 tickUpper,,,,,) = nft.positions(tokenId);
        return _settleReward(msg.sender, _takeReward(tickLower, tickUpper, tokenId), true, veTokenId, lockDuration);
    }

    function _validateLock(address account, uint256 veTokenId, uint256 lockDuration) internal view {
        IVotingEscrow escrow = IVotingEscrow(voter.ve());
        require(rewardToken == escrow.token(), "IRT");
        if (veTokenId != 0) {
            require(lockDuration == 0, "IP");
            require(escrow.ownerOf(veTokenId) == account, "NA");
        }
    }

    function _takeReward(int24 tickLower, int24 tickUpper, uint256 tokenId) internal returns (uint256 reward) {
        if (phase != Phase.IRS) return 0;
        _updateRewards(tokenId, tickLower, tickUpper);
        reward = rewards[tokenId];
        delete rewards[tokenId];
    }

    function _settleReward(address account, uint256 reward, bool lockReward, uint256 veTokenId, uint256 lockDuration)
        internal
        returns (uint256)
    {
        if (reward > 0) {
            uint256 amountLocked;
            if (lockReward) {
                address ve = address(voter.ve());
                IERC20(rewardToken).safeApprove(ve, 0);
                IERC20(rewardToken).safeApprove(ve, reward);
                if (veTokenId == 0) {
                    veTokenId = IVotingEscrow(ve).createLockFor(reward, lockDuration, account);
                } else {
                    IVotingEscrow(ve).depositFor(veTokenId, reward);
                }
                IERC20(rewardToken).safeApprove(ve, 0);
                amountLocked = reward;
                emit ClaimRewardsLocked(account, veTokenId, reward);
            } else {
                IERC20(rewardToken).safeTransfer(account, reward);
            }
            emit ClaimRewards(account, reward);
            address hook = voter.claimHook();
            if (hook != address(0)) {
                // Optional bonuses must not roll back settled rewards or prevent LP withdrawal.
                try IClaimHook(hook).onClaim(veTokenId, amountLocked, account, address(this)) {} catch {}
            }
        }
        return veTokenId;
    }

    /// @inheritdoc ICLGauge
    function deposit(uint256 tokenId) external override nonReentrant {
        _deposit(tokenId, msg.sender);
    }

    /// @inheritdoc ICLGauge
    function deposit(uint256 tokenId, address recipient) external override nonReentrant {
        require(recipient != address(0), "ZA");
        require(recipient == msg.sender || factory.isWhitelisted(msg.sender), "NW");
        _deposit(tokenId, recipient);
    }

    function _deposit(uint256 tokenId, address recipient) private {
        require(phase != Phase.Transition, "TRANSITION");
        require(nft.ownerOf(tokenId) == msg.sender, "NA");
        require(voter.isAlive(address(this)), "GK");
        (,, address _token0, address _token1, int24 _tickSpacing, int24 tickLower, int24 tickUpper,,,,,) =
            nft.positions(tokenId);
        require(token0 == _token0 && token1 == _token1 && tickSpacing == _tickSpacing, "PM");

        // trigger update on staked position so NFT will be in sync with the pool
        nft.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId, recipient: msg.sender, amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
        );

        nft.safeTransferFrom(msg.sender, address(this), tokenId);
        _stakes[recipient].add(tokenId);
        stakerOf[tokenId] = recipient;
        if (phase != Phase.IRS) _pending.add(tokenId);

        (,,,,,,, uint128 liquidityToStake,,,,) = nft.positions(tokenId);
        pool.stake(liquidityToStake.toInt128(), tickLower, tickUpper, true);

        uint256 rewardGrowth = pool.getRewardGrowthInside(tickLower, tickUpper, 0);
        rewardGrowthInside[tokenId] = rewardGrowth;
        lastUpdateTime[tokenId] = block.timestamp;

        emit Deposit(recipient, tokenId, liquidityToStake);
    }

    /// @inheritdoc ICLGauge
    function withdraw(uint256 tokenId) external override nonReentrant {
        require(_stakes[msg.sender].contains(tokenId), "NA");

        // trigger update on staked position so NFT will be in sync with the pool
        nft.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId, recipient: msg.sender, amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
        );

        (,,,,, int24 tickLower, int24 tickUpper, uint128 liquidityToStake,,,,) = nft.positions(tokenId);
        if (phase == Phase.IRS) {
            _getReward(tickLower, tickUpper, tokenId, msg.sender);
        } else {
            _checkpointInitialRewards(tokenId, tickLower, tickUpper, msg.sender);
        }

        // update virtual liquidity in pool only if token has existing liquidity
        // i.e. not all removed already via decreaseStakedLiquidity
        if (liquidityToStake != 0) {
            pool.stake(-liquidityToStake.toInt128(), tickLower, tickUpper, true);
        }

        _stakes[msg.sender].remove(tokenId);
        _pending.remove(tokenId);
        delete stakerOf[tokenId];
        nft.safeTransferFrom(address(this), msg.sender, tokenId);

        emit Withdraw(msg.sender, tokenId, liquidityToStake);
    }

    /// @inheritdoc ICLGauge
    function stakedValues(address depositor) external view override returns (uint256[] memory) {
        return _stakes[depositor].values();
    }

    /// @inheritdoc ICLGauge
    function stakedContains(address depositor, uint256 tokenId) external view override returns (bool) {
        return _stakes[depositor].contains(tokenId);
    }

    /// @inheritdoc ICLGauge
    function stakedLength(address depositor) external view override returns (uint256) {
        return _stakes[depositor].length();
    }

    function left() external view override returns (uint256) {
        if (block.timestamp >= periodFinish) return 0;
        uint256 _remaining = periodFinish - block.timestamp;
        return _remaining * rewardRate;
    }

    /// @inheritdoc ICLGauge
    function notifyRewardAmount(uint256 _amount) external override nonReentrant {
        address sender = msg.sender;
        require(sender == address(voter), "NV");
        require(_amount != 0, "ZR");
        _claimFees();
        _notifyRewardAmount(sender, _amount);
    }

    /// @inheritdoc ICLGauge
    function notifyRewardWithoutClaim(uint256 _amount) external override nonReentrant {
        address sender = msg.sender;
        require(sender == IVotingEscrow(voter.ve()).team(), "NT");
        require(_amount != 0, "ZR");
        _notifyRewardAmount(sender, _amount);
    }

    function _notifyRewardAmount(address _sender, uint256 _amount) internal {
        _pullExact(rewardToken, _sender, _amount);
        if (phase != Phase.IRS) {
            queuedIRS = queuedIRS.add(_amount);
            emit IrsQueued(_sender, _amount);
        } else {
            uint256 amount = _amount.add(queuedIRS);
            delete queuedIRS;
            _scheduleIRS(_sender, amount);
        }
    }

    function _scheduleIRS(address sender, uint256 amount) private {
        uint256 timestamp = block.timestamp;
        uint256 duration = ProtocolTimeLibrary.epochNext(timestamp).sub(timestamp);
        // Also advances lastUpdated while the stream is zero at transition finish.
        pool.updateRewardsGrowthGlobal();
        amount = amount.add(pool.rollover());
        uint256 budget = amount;
        if (timestamp < periodFinish) budget = budget.add(duration.mul(rewardRate));
        rewardRate = budget / duration;
        require(rewardRate != 0, "ZRR");
        require(rewardRate <= IERC20(rewardToken).balanceOf(address(this)) / duration, "RRH");
        periodFinish = timestamp.add(duration);
        rewardRateByEpoch[ProtocolTimeLibrary.epochStart(timestamp)] = rewardRate;
        pool.syncReward(rewardRate, budget, periodFinish);
        emit NotifyReward(sender, amount);
    }

    function _pullExact(address token, address from, uint256 amount) private {
        uint256 beforeBalance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(from, address(this), amount);
        require(IERC20(token).balanceOf(address(this)) == beforeBalance.add(amount), "TRANSFER_AMOUNT");
    }

    /// @inheritdoc ICLPrivateGauge
    function configureInitialRewards(address token, address funder) external override onlyTeam nonReentrant {
        require(phase == Phase.AwaitingInitial, "PHASE");
        require(token != rewardToken && Address.isContract(token), "TOKEN");
        require(funder != address(0) && funder != address(this), "FUNDER");
        initialRewardToken = token;
        initialRewardFunder = funder;
        phase = Phase.Initial;
        emit InitialRewardsConfigured(token, funder);
    }

    /// @inheritdoc ICLPrivateGauge
    function notifyInitialRewards(uint256 amount) external override nonReentrant {
        require(phase == Phase.Initial, "PHASE");
        require(msg.sender == initialRewardFunder, "FUNDER");
        require(amount != 0, "ZR");
        pool.updateRewardsGrowthGlobal();
        _pullExact(initialRewardToken, msg.sender, amount);
        totalInitialRewardsFunded = totalInitialRewardsFunded.add(amount);
        uint256 budget = amount.add(pool.rewardReserve()).add(pool.rollover()).add(initialRewardDust);
        uint256 finish = ProtocolTimeLibrary.epochNext(block.timestamp);
        uint256 duration = finish.sub(block.timestamp);
        uint256 rate = budget / duration;
        require(rate != 0, "ZRR");
        uint256 scheduled = rate.mul(duration);
        initialRewardDust = budget.sub(scheduled);
        initialRewardRate = rate;
        initialPeriodFinish = finish;
        pool.syncReward(rate, scheduled, finish);
        emit NotifyInitialRewards(msg.sender, amount, rate, finish);
    }

    /// @inheritdoc ICLPrivateGauge
    function earnedInitialRewards(address account, uint256 tokenId) external view override returns (uint256) {
        require(_stakes[account].contains(tokenId), "NA");
        if (phase == Phase.IRS || !_pending.contains(tokenId)) return 0;
        return _earned(tokenId);
    }

    /// @inheritdoc ICLPrivateGauge
    function claimInitialRewards(uint256[] calldata tokenIds) external override nonReentrant {
        for (uint256 i; i < tokenIds.length; ++i) {
            uint256 tokenId = tokenIds[i];
            require(_stakes[msg.sender].contains(tokenId), "NA");
            if (phase != Phase.IRS && _pending.contains(tokenId)) {
                (,,,,, int24 lower, int24 upper,,,,,) = nft.positions(tokenId);
                _checkpointInitialRewards(tokenId, lower, upper, msg.sender);
            }
        }
        _tryPayInitialRewards(msg.sender);
    }

    function _checkpointInitialRewards(uint256 tokenId, int24 lower, int24 upper, address account) private {
        // Do not reuse the IRS same-timestamp shortcut: even a zero-reward position
        // must leave the pending transition set in the block in which stopping occurs.
        if (!_pending.contains(tokenId)) return;
        pool.updateRewardsGrowthGlobal();
        uint256 amount = _earned(tokenId);
        rewardGrowthInside[tokenId] = pool.getRewardGrowthInside(lower, upper, 0);
        lastUpdateTime[tokenId] = block.timestamp;
        if (amount != 0) {
            initialRewardCredits[account] = initialRewardCredits[account].add(amount);
            totalInitialRewardsCredits = totalInitialRewardsCredits.add(amount);
            emit InitialRewardsCredited(account, tokenId, amount);
        }
        if (phase == Phase.Transition) {
            _pending.remove(tokenId);
            emit TransitionCheckpointed(tokenId, account, amount);
        }
    }

    /// @inheritdoc ICLPrivateGauge
    function beginIrsTransition() external override onlyTeam nonReentrant {
        _beginIrsTransition();
    }

    function _beginIrsTransition() private {
        require(phase == Phase.AwaitingInitial || phase == Phase.Initial, "PHASE");
        pool.updateRewardsGrowthGlobal();
        stoppedInitialRewardReserve = pool.rewardReserve();
        stoppedInitialRewardRollover = pool.rollover();
        pool.syncReward(0, 0, block.timestamp);
        initialRewardRate = 0;
        initialPeriodFinish = block.timestamp;
        phase = Phase.Transition;
        emit IrsTransitionStarted(block.timestamp, _pending.length());
    }

    /// @inheritdoc ICLPrivateGauge
    function checkpointTransition(uint256[] calldata tokenIds) external override nonReentrant {
        _checkpointTransition(tokenIds);
    }

    function _checkpointTransition(uint256[] calldata tokenIds) private {
        require(phase == Phase.Transition, "PHASE");
        for (uint256 i; i < tokenIds.length; ++i) {
            uint256 tokenId = tokenIds[i];
            if (!_pending.contains(tokenId)) continue;
            address account = stakerOf[tokenId];
            (,,,,, int24 lower, int24 upper,,,,,) = nft.positions(tokenId);
            _checkpointInitialRewards(tokenId, lower, upper, account);
            _tryPayInitialRewards(account);
        }
    }

    function _tryPayInitialRewards(address account) private {
        uint256 amount = initialRewardCredits[account];
        if (amount == 0) return;
        // Isolate token failure (including false returns after token state writes)
        // in a subcall, with bounded gas so it cannot prevent checkpoint progress.
        try this.transferInitialRewards{gas: INITIAL_REWARDS_PAYOUT_GAS}(account, amount) {
            delete initialRewardCredits[account];
            totalInitialRewardsCredits = totalInitialRewardsCredits.sub(amount);
            totalInitialRewardsPaid = totalInitialRewardsPaid.add(amount);
            emit ClaimInitialRewards(account, amount);
        } catch {
            emit InitialRewardsPayoutFailed(account, amount);
        }
    }

    /// @dev Only the gauge may enter this isolated transfer subcall.
    function transferInitialRewards(address account, uint256 amount) external {
        require(msg.sender == address(this), "SELF");
        IERC20(initialRewardToken).safeTransfer(account, amount);
    }

    /// @inheritdoc ICLPrivateGauge
    function pendingPositions() external view override returns (uint256) {
        return _pending.length();
    }

    /// @inheritdoc ICLPrivateGauge
    function pendingTokenIds(uint256 offset, uint256 limit) external view override returns (uint256[] memory ids) {
        uint256 length = _pending.length();
        if (offset >= length) return new uint256[](0);
        uint256 count = length.sub(offset);
        if (count > limit) count = limit;
        ids = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            ids[i] = _pending.at(offset.add(i));
        }
    }

    /// @inheritdoc ICLPrivateGauge
    function unusedInitialRewards() public view override returns (uint256) {
        if ((phase != Phase.Transition && phase != Phase.IRS) || _pending.length() != 0) return 0;
        return totalInitialRewardsFunded.sub(totalInitialRewardsPaid).sub(totalInitialRewardsCredits)
            .sub(totalInitialRewardsRefunded);
    }

    /// @inheritdoc ICLPrivateGauge
    function recoverUnusedInitialRewards() external override nonReentrant returns (uint256 amount) {
        require((phase == Phase.Transition || phase == Phase.IRS) && _pending.length() == 0, "PENDING");
        amount = unusedInitialRewards();
        if (amount != 0) {
            totalInitialRewardsRefunded = totalInitialRewardsRefunded.add(amount);
            IERC20(initialRewardToken).safeTransfer(initialRewardFunder, amount);
            emit InitialRewardsRefunded(initialRewardFunder, amount);
        }
    }

    /// @inheritdoc ICLPrivateGauge
    function finishIrsTransition() external override onlyTeam nonReentrant {
        _finishIrsTransition();
    }

    function _finishIrsTransition() private {
        require(phase == Phase.Transition && _pending.length() == 0, "PENDING");
        // Critical: timestamp must advance while the rate is still zero, before
        // any IRS rate is installed, or paused time could receive retroactive IRS.
        pool.updateRewardsGrowthGlobal();
        phase = Phase.IRS;
        uint256 amount = queuedIRS;
        // A tiny queued donation must not prevent permanent IRS activation.
        // Leave sub-rate funding queued for the next normal notification.
        if (amount >= ProtocolTimeLibrary.epochNext(block.timestamp).sub(block.timestamp)) {
            delete queuedIRS;
            _scheduleIRS(address(this), amount);
        }
        emit IrsTransitionFinished(amount);
    }

    /// @inheritdoc ICLPrivateGauge
    function transitionToIRS(uint256[] calldata tokenIds) external override onlyTeam nonReentrant {
        _beginIrsTransition();
        _checkpointTransition(tokenIds);
        _finishIrsTransition();
    }

    function _claimFees() internal {
        if (!isPool) return;

        (uint256 claimed0, uint256 claimed1) = pool.collectFees();
        if (claimed0 > 0 || claimed1 > 0) {
            uint256 _fees0 = fees0 + claimed0;
            uint256 _fees1 = fees1 + claimed1;
            address _token0 = token0;
            address _token1 = token1;
            if (_fees0 > ProtocolTimeLibrary.WEEK) {
                fees0 = 0;
                IERC20(_token0).safeIncreaseAllowance(feesVotingReward, _fees0);
                IReward(feesVotingReward).notifyRewardAmount(_token0, _fees0);
            } else {
                fees0 = _fees0;
            }
            if (_fees1 > ProtocolTimeLibrary.WEEK) {
                fees1 = 0;
                IERC20(_token1).safeIncreaseAllowance(feesVotingReward, _fees1);
                IReward(feesVotingReward).notifyRewardAmount(_token1, _fees1);
            } else {
                fees1 = _fees1;
            }

            emit ClaimFees(msg.sender, claimed0, claimed1);
        }
    }
}
