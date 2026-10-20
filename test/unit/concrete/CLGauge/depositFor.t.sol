pragma solidity ^0.7.6;
pragma abicoder v2;

import "./CLGauge.t.sol";

contract DepositForTest is CLGaugeTest {
    using stdStorage for StdStorage;

    CLPool public pool;
    CLGauge public gauge;

    function setUp() public override {
        super.setUp();
        pool = CLPool(poolFactory.createPool(address(token0), address(token1), TICK_SPACING_60, encodePriceSqrt(1, 1)));
        gauge = CLGauge(voter.createGauge(address(poolFactory), address(pool)));
        vm.prank(users.feeManager);
        customUnstakedFeeModule.setCustomFee(address(pool), 420);
        vm.startPrank(users.alice);
    }

    function _mintApproved() private returns (uint256 tokenId) {
        tokenId = nftCallee.mintNewFullRangePositionForUserWith60TickSpacing(TOKEN_1 * 10, TOKEN_1 * 10, users.alice);
        nft.approve(address(gauge), tokenId);
    }

    function test_DepositForRecipientClaimsAndWithdraws() public {
        uint256 tokenId = _mintApproved();
        (,,,,,,, uint128 liquidity,,,,) = nft.positions(tokenId);
        vm.expectEmit(true, true, true, false, address(gauge));
        emit Deposit(users.charlie, tokenId, liquidity);
        gauge.deposit(tokenId, users.charlie);
        assertEq(nft.ownerOf(tokenId), address(gauge));
        assertTrue(gauge.stakedContains(users.charlie, tokenId));
        assertEq(gauge.stakedLength(users.alice), 0);
        assertEqUint(pool.stakedLiquidity(), liquidity);

        vm.expectRevert(bytes("NA"));
        gauge.getReward(tokenId);
        vm.expectRevert(bytes("NA"));
        gauge.withdraw(tokenId);

        addRewardToGauge(address(voter), address(gauge), TOKEN_1);
        skip(2 days);
        uint256 beforeReward = rewardToken.balanceOf(users.charlie);
        vm.startPrank(users.charlie);
        gauge.getReward(tokenId);
        assertGt(rewardToken.balanceOf(users.charlie), beforeReward);
        gauge.withdraw(tokenId);
        assertEq(nft.ownerOf(tokenId), users.charlie);
        assertEq(gauge.stakedLength(users.charlie), 0);
        assertEqUint(pool.stakedLiquidity(), 0);
    }

    function test_RevertIf_DepositForZeroRecipient() public {
        uint256 tokenId = _mintApproved();
        vm.expectRevert(bytes("ZA"));
        gauge.deposit(tokenId, address(0));
        assertEq(nft.ownerOf(tokenId), users.alice);
    }

    function test_RevertIf_DepositForCallerNotOwnerEvenWhenApproved() public {
        uint256 tokenId = _mintApproved();
        nft.setApprovalForAll(users.charlie, true);
        vm.startPrank(users.charlie);
        vm.expectRevert(bytes("NA"));
        gauge.deposit(tokenId, users.charlie);
    }

    function test_RevertIf_DepositForKilledGauge() public {
        uint256 tokenId = _mintApproved();
        stdstore.target(address(voter)).sig(voter.isAlive.selector).with_key(address(gauge)).checked_write(false);
        vm.expectRevert(bytes("GK"));
        gauge.deposit(tokenId, users.charlie);
    }

    function test_DepositForPaysExistingFeesToDonor() public {
        uint256 tokenId = _mintApproved();
        clCallee.swapExact0For1(address(pool), 1e18, users.alice, MIN_SQRT_RATIO + 1);
        clCallee.swapExact1For0(address(pool), 1e18, users.alice, MAX_SQRT_RATIO - 1);
        uint256 before0 = token0.balanceOf(users.alice);
        uint256 before1 = token1.balanceOf(users.alice);
        uint256 recipient0 = token0.balanceOf(users.charlie);
        uint256 recipient1 = token1.balanceOf(users.charlie);
        gauge.deposit(tokenId, users.charlie);
        assertGt(token0.balanceOf(users.alice), before0);
        assertGt(token1.balanceOf(users.alice), before1);
        assertEq(token0.balanceOf(users.charlie), recipient0);
        assertEq(token1.balanceOf(users.charlie), recipient1);
    }
}
