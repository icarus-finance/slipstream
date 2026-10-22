// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import "../../../BaseFixture.sol";
import {CLPrivateFactory} from "contracts/core/CLPrivateFactory.sol";
import {PrivateNonFungiblePositionManager} from "contracts/periphery/PrivateNonFungiblePositionManager.sol";
import {CLPrivatePool} from "contracts/core/CLPrivatePool.sol";
import {RealClaimEscrow, RealEscrowArtifactDeployer} from "../CLGauge/claimAndLock.t.sol";

contract PrivatePoolGaugeIntegrationTest is BaseFixture {
    CLPrivateFactory internal privateFactory;
    CLPrivatePool internal privatePool;
    CLGaugeFactory internal privateGaugeFactory;
    PrivateNonFungiblePositionManager internal privateNft;
    CLGauge internal privateGauge;
    CLGauge internal publicGauge;

    function setUp() public virtual override {
        super.setUp();
        vm.startPrank(users.owner);
        privateGaugeFactory = new CLGaugeFactory(address(voter), address(gaugeImplementation));
        privateFactory = new CLPrivateFactory(
            address(voter), address(new CLPrivatePool()), address(privateGaugeFactory), address(gaugeImplementation)
        );
        privateNft = new PrivateNonFungiblePositionManager(
            users.owner, address(privateFactory), address(weth), address(nftDescriptor), "Private CL", "PCL"
        );
        privateFactory.setNonfungiblePositionManager(address(privateNft));
        privateFactory.setWhitelist(address(privateNft), true);
        privateGaugeFactory.setNonfungiblePositionManager(address(privateNft));
        factoryRegistry.approve(address(privateFactory), address(votingRewardsFactory), address(privateGaugeFactory));
        privateFactory.setWhitelist(users.owner, true);
        privatePool = CLPrivatePool(
            privateFactory.createPool(address(token0), address(token1), int24(100), encodePriceSqrt(1, 1))
        );
        privateGauge = CLGauge(voter.createGauge(address(privateFactory), address(privatePool)));
        address publicPool = poolFactory.createPool(address(token0), address(token1), int24(100), encodePriceSqrt(1, 1));
        publicGauge = CLGauge(voter.createGauge(address(poolFactory), publicPool));
        vm.stopPrank();
    }

    function _mint() internal returns (uint256 id, uint128 liquidity) {
        vm.prank(users.owner);
        privateNft.setPublicLiquidity(true);
        vm.startPrank(users.alice);
        token0.approve(address(privateNft), type(uint256).max);
        token1.approve(address(privateNft), type(uint256).max);
        (id, liquidity,,) = privateNft.mint(
            INonfungiblePositionManager.MintParams({
                token0: address(token0),
                token1: address(token1),
                tickSpacing: 100,
                tickLower: -100,
                tickUpper: 100,
                amount0Desired: TOKEN_1,
                amount1Desired: TOKEN_1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: users.alice,
                deadline: block.timestamp,
                sqrtPriceX96: 0
            })
        );
        privateNft.approve(address(privateGauge), id);
        vm.stopPrank();
        vm.prank(users.owner);
        privateNft.setPublicLiquidity(false);
    }

    function test_RegisteredPrivateAndPublicPoolsHaveDistinctWorkingGauges() public {
        assertTrue(factoryRegistry.isPoolFactoryApproved(address(privateFactory)));
        assertEq(voter.gauges(address(privatePool)), address(privateGauge));
        assertEq(voter.poolForGauge(address(privateGauge)), address(privatePool));
        assertEq(privatePool.gauge(), address(privateGauge));
        assertEq(privateGauge.rewardToken(), address(rewardToken));
        assertTrue(address(privateGauge) != address(publicGauge));
        assertTrue(voter.isAlive(address(privateGauge)));
        assertEq(address(privateGauge.nft()), address(privateNft));
    }

    function test_UnlistedOwnerCanDepositClaimAndExitWhenLiquidityIsPrivate() public {
        (uint256 id, uint128 liquidity) = _mint();
        assertFalse(privateFactory.isWhitelisted(users.alice));
        assertFalse(privateFactory.isWhitelisted(address(privateGauge)));
        assertTrue(privateFactory.isWhitelisted(address(privateNft)));
        vm.prank(users.alice);
        privateGauge.deposit(id);
        assertEq(uint256(privatePool.stakedLiquidity()), uint256(liquidity));
        addRewardToGauge(address(voter), address(privateGauge), TOKEN_1);
        skip(1 days);
        uint256 earned = privateGauge.earned(users.alice, id);
        assertGt(earned, 0);
        vm.prank(users.alice);
        privateGauge.getReward(id);
        assertEq(rewardToken.balanceOf(users.alice), earned);
        vm.prank(users.alice);
        privateGauge.withdraw(id);
        assertEq(privateNft.ownerOf(id), users.alice);
        assertEq(uint256(privatePool.stakedLiquidity()), 0);
        vm.startPrank(users.alice);
        privateNft.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: id, liquidity: liquidity, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
            })
        );
        (uint256 amount0, uint256 amount1) = privateNft.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: id, recipient: users.alice, amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
        );
        vm.stopPrank();
        assertGt(amount0, 0);
        assertGt(amount1, 0);
        assertEq(uint256(privatePool.liquidity()), 0);
    }

    function test_VoterClaimsUnchangedAndCannotClaimTwice() public {
        (uint256 id,) = _mint();
        vm.prank(users.alice);
        privateGauge.deposit(id);
        addRewardToGauge(address(voter), address(privateGauge), TOKEN_1);
        skip(2 days);
        uint256 earned = privateGauge.earned(users.alice, id);
        address[] memory gauges = new address[](1);
        gauges[0] = address(privateGauge);
        vm.startPrank(users.alice);
        voter.claimRewards(gauges);
        voter.claimRewards(gauges);
        vm.stopPrank();
        assertGt(earned, 0);
        assertEq(rewardToken.balanceOf(users.alice), earned);
    }

    function test_KilledGaugeStillAllowsExit() public {
        (uint256 id,) = _mint();
        vm.prank(users.alice);
        privateGauge.deposit(id);
        vm.prank(users.owner);
        voter.killGauge(address(privateGauge));
        vm.prank(users.alice);
        privateGauge.withdraw(id);
        assertEq(privateNft.ownerOf(id), users.alice);
    }

    function test_PublicLiquidityDoesNotOpenSwapsOrFlashOrCreation() public {
        _mint();
        vm.prank(users.owner);
        privateNft.setPublicLiquidity(true);
        vm.startPrank(users.alice);
        vm.expectRevert(bytes("NW"));
        privatePool.swap(users.alice, true, 1, 4295128740, "");
        vm.expectRevert(bytes("NW"));
        privatePool.flash(users.alice, 0, 0, "");
        vm.expectRevert(bytes("NW"));
        privateFactory.createPool(address(token0), address(token1), uint24(50));
        vm.stopPrank();
    }

    function test_NftManagerMustBeExplicitlyAllowedEvenWhenManagerLiquidityIsPublic() public {
        vm.startPrank(users.owner);
        privateNft.setPublicLiquidity(true);
        privateFactory.setWhitelist(address(privateNft), false);
        vm.stopPrank();
        vm.startPrank(users.alice);
        token0.approve(address(privateNft), type(uint256).max);
        token1.approve(address(privateNft), type(uint256).max);
        vm.expectRevert(bytes("NW"));
        privateNft.mint(
            INonfungiblePositionManager.MintParams({
                token0: address(token0),
                token1: address(token1),
                tickSpacing: 100,
                tickLower: -100,
                tickUpper: 100,
                amount0Desired: TOKEN_1,
                amount1Desired: TOKEN_1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: users.alice,
                deadline: block.timestamp,
                sqrtPriceX96: 0
            })
        );
        vm.stopPrank();
    }

    /// @dev Public manager mode deliberately permits direct additions by unlisted users.
    function test_PublicManagerModeAllowsUnlistedMintOrIncrease() public {
        vm.prank(users.owner);
        privateNft.setPublicLiquidity(true);
        assertTrue(privateNft.publicLiquidity());
        assertFalse(privateFactory.isWhitelisted(users.alice));
        vm.startPrank(users.alice);
        token0.approve(address(privateNft), type(uint256).max);
        token1.approve(address(privateNft), type(uint256).max);
        (uint256 id, uint128 initialLiquidity,,) = privateNft.mint(
            INonfungiblePositionManager.MintParams({
                token0: address(token0),
                token1: address(token1),
                tickSpacing: 100,
                tickLower: -100,
                tickUpper: 100,
                amount0Desired: TOKEN_1,
                amount1Desired: TOKEN_1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: users.bob,
                deadline: block.timestamp,
                sqrtPriceX96: 0
            })
        );
        // Even custody by another account does not restrict the public manager's liquidity additions.
        (uint128 added,,) = privateNft.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: id,
                amount0Desired: TOKEN_1,
                amount1Desired: TOKEN_1,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
        assertEq(privateNft.ownerOf(id), users.bob);
        assertGt(uint256(initialLiquidity), 0);
        assertGt(uint256(added), 0);
    }
}

/// @dev Runs the same lifecycle against the production core Voter and escrow artifacts.
contract PrivatePoolRealVoterIntegrationTest is PrivatePoolGaugeIntegrationTest, RealEscrowArtifactDeployer {
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
        RealClaimEscrow(address(escrow)).setVoterAndDistributor(address(voter), address(0));
    }
}
