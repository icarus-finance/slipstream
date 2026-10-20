pragma solidity ^0.7.6;
pragma abicoder v2;

import "test/BaseFixture.sol";
import {LiquidityStakeHelper} from "contracts/periphery/LiquidityStakeHelper.sol";

contract LiquidityStakeHelperTest is BaseFixture {
    using stdStorage for StdStorage;
    LiquidityStakeHelper public helper;
    CLPool public pool;
    CLGauge public gauge;

    function setUp() public override {
        super.setUp();
        pool = CLPool(poolFactory.createPool(address(token0), address(token1), TICK_SPACING_60, encodePriceSqrt(1, 1)));
        gauge = CLGauge(voter.createGauge(address(poolFactory), address(pool)));
        helper = new LiquidityStakeHelper(address(nft));
        vm.startPrank(users.alice);
        token0.approve(address(helper), type(uint256).max);
        token1.approve(address(helper), type(uint256).max);
    }

    function params() internal view returns (INonfungiblePositionManager.MintParams memory p) {
        p = INonfungiblePositionManager.MintParams({
            token0: address(token0),
            token1: address(token1),
            tickSpacing: TICK_SPACING_60,
            tickLower: -TICK_SPACING_60,
            tickUpper: TICK_SPACING_60,
            recipient: users.alice,
            amount0Desired: TOKEN_1,
            amount1Desired: TOKEN_1,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp,
            sqrtPriceX96: 0
        });
    }

    function test_MintStakeClaimAndWithdraw() public {
        (uint256 id, uint128 liquidity,,) = helper.mintAndStake(params(), 1);
        assertEq(nft.ownerOf(id), address(gauge));
        assertTrue(gauge.stakedContains(users.alice, id));
        assertEq(gauge.stakedLength(address(helper)), 0);
        assertEq(uint256(pool.stakedLiquidity()), uint256(liquidity));
        addRewardToGauge(address(voter), address(gauge), TOKEN_1);
        skip(1 days);
        vm.startPrank(users.alice);
        gauge.getReward(id);
        assertGt(rewardToken.balanceOf(users.alice), 0);
        gauge.withdraw(id);
        assertEq(nft.ownerOf(id), users.alice);
        assertEq(uint256(pool.stakedLiquidity()), 0);
    }

    function test_RefundsPreserveDonationsAndClearApprovals() public {
        token0.transfer(address(helper), 71);
        token1.transfer(address(helper), 89);
        INonfungiblePositionManager.MintParams memory p = params();
        p.amount1Desired = 2 * TOKEN_1;
        uint256 before0 = token0.balanceOf(users.alice);
        uint256 before1 = token1.balanceOf(users.alice);
        (,, uint256 used0, uint256 used1) = helper.mintAndStake(p, 1);
        assertEq(before0 - token0.balanceOf(users.alice), used0);
        assertEq(before1 - token1.balanceOf(users.alice), used1);
        assertEq(token0.balanceOf(address(helper)), 71);
        assertEq(token1.balanceOf(address(helper)), 89);
        assertEq(token0.allowance(address(helper), address(nft)), 0);
        assertEq(token1.allowance(address(helper), address(nft)), 0);
    }

    function test_RevertMinimumLiquidityRollsBack() public {
        uint256 before0 = token0.balanceOf(users.alice);
        vm.expectRevert(bytes("IL"));
        helper.mintAndStake(params(), type(uint128).max);
        assertEq(token0.balanceOf(users.alice), before0);
        assertEq(nft.balanceOf(address(gauge)), 0);
        assertEq(token0.allowance(address(helper), address(nft)), 0);
    }

    function test_RevertExpired() public {
        INonfungiblePositionManager.MintParams memory p = params();
        p.deadline = block.timestamp - 1;
        vm.expectRevert(bytes("Transaction too old"));
        helper.mintAndStake(p, 1);
    }

    function test_RevertDeadGauge() public {
        vm.stopPrank();
        stdstore.target(address(voter)).sig(voter.isAlive.selector).with_key(address(gauge)).checked_write(false);
        vm.startPrank(users.alice);
        vm.expectRevert(bytes("GK"));
        helper.mintAndStake(params(), 1);
    }

    function test_RevertMissingGauge() public {
        vm.stopPrank();
        stdstore.target(address(voter)).sig(voter.gauges.selector).with_key(address(pool)).checked_write(address(0));
        vm.startPrank(users.alice);
        vm.expectRevert(bytes("GK"));
        helper.mintAndStake(params(), 1);
    }

    function test_RevertMismatchedGauge() public {
        vm.mockCall(address(gauge), abi.encodeWithSignature("pool()"), abi.encode(address(1)));
        vm.expectRevert(bytes("GM"));
        helper.mintAndStake(params(), 1);
    }

    function test_OneSidedRange() public {
        INonfungiblePositionManager.MintParams memory p = params();
        p.tickLower = TICK_SPACING_60;
        p.tickUpper = 2 * TICK_SPACING_60;
        p.amount1Desired = 0;
        (uint256 id, uint128 liquidity, uint256 used0, uint256 used1) = helper.mintAndStake(p, 1);
        assertGt(uint256(liquidity), 0);
        assertGt(used0, 0);
        assertEq(used1, 0);
        assertTrue(gauge.stakedContains(users.alice, id));
        assertEq(uint256(pool.stakedLiquidity()), 0);
    }

    function test_MultiplePositionsAndRecipients() public {
        (uint256 id0,,,) = helper.mintAndStake(params(), 1);
        INonfungiblePositionManager.MintParams memory p = params();
        p.recipient = users.charlie;
        (uint256 id1,,,) = helper.mintAndStake(p, 1);
        (uint256 id2,,,) = helper.mintAndStake(p, 1);
        assertTrue(gauge.stakedContains(users.alice, id0));
        assertTrue(gauge.stakedContains(users.charlie, id1));
        assertTrue(gauge.stakedContains(users.charlie, id2));
        vm.expectRevert(bytes("NA"));
        gauge.withdraw(id1);
        vm.startPrank(users.charlie);
        gauge.withdraw(id1);
        assertEq(nft.ownerOf(id1), users.charlie);
    }

    function test_RevertShortTransferCannotUseDonation() public {
        token0.transfer(address(helper), TOKEN_1);
        uint256 balanceBefore = token0.balanceOf(users.alice);
        vm.mockCall(
            address(token0),
            abi.encodeWithSelector(token0.transferFrom.selector, users.alice, address(helper), TOKEN_1),
            abi.encode(true)
        );
        vm.expectRevert(bytes("FOT"));
        helper.mintAndStake(params(), 1);
        assertEq(token0.balanceOf(address(helper)), TOKEN_1);
        assertEq(token0.balanceOf(users.alice), balanceBefore);
        assertEq(nft.balanceOf(address(gauge)), 0);
    }

    function testFuzz_Accounting(uint96 desired0, uint96 desired1) public {
        INonfungiblePositionManager.MintParams memory p = params();
        p.amount0Desired = bound(uint256(desired0), 1e12, 10 * TOKEN_1);
        p.amount1Desired = bound(uint256(desired1), 1e12, 10 * TOKEN_1);
        uint256 before0 = token0.balanceOf(users.alice);
        uint256 before1 = token1.balanceOf(users.alice);
        (uint256 id, uint128 liquidity, uint256 used0, uint256 used1) = helper.mintAndStake(p, 1);
        assertEq(before0 - token0.balanceOf(users.alice), used0);
        assertEq(before1 - token1.balanceOf(users.alice), used1);
        assertEq(token0.balanceOf(address(helper)), 0);
        assertEq(token1.balanceOf(address(helper)), 0);
        assertEq(uint256(pool.stakedLiquidity()), uint256(liquidity));
        assertTrue(gauge.stakedContains(users.alice, id));
    }

    function test_RevertZeroRecipient() public {
        INonfungiblePositionManager.MintParams memory p = params();
        p.recipient = address(0);
        vm.expectRevert(bytes("ZA"));
        helper.mintAndStake(p, 1);
    }

    function test_RevertHelperRecipient() public {
        INonfungiblePositionManager.MintParams memory p = params();
        p.recipient = address(helper);
        vm.expectRevert(bytes("ZA"));
        helper.mintAndStake(p, 1);
    }

    function test_RevertMissingPool() public {
        INonfungiblePositionManager.MintParams memory p = params();
        p.tickSpacing = TICK_SPACING_10;
        vm.expectRevert(bytes("NP"));
        helper.mintAndStake(p, 1);
    }

    function test_RevertPoolInitializationRequested() public {
        INonfungiblePositionManager.MintParams memory p = params();
        p.sqrtPriceX96 = encodePriceSqrt(1, 1);
        vm.expectRevert(bytes("NEW"));
        helper.mintAndStake(p, 1);
    }

    function test_RevertTokenMinimumRollsBack() public {
        INonfungiblePositionManager.MintParams memory p = params();
        p.amount0Min = p.amount0Desired + 1;
        uint256 before0 = token0.balanceOf(users.alice);
        uint256 before1 = token1.balanceOf(users.alice);
        vm.expectRevert();
        helper.mintAndStake(p, 1);
        assertEq(token0.balanceOf(users.alice), before0);
        assertEq(token1.balanceOf(users.alice), before1);
        assertEq(nft.balanceOf(address(gauge)), 0);
        assertEq(uint256(pool.liquidity()), 0);
    }
}
