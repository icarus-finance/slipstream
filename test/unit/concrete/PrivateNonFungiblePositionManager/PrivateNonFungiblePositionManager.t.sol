// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import "../../../BaseFixture.sol";
import {CLPrivateFactory} from "contracts/core/CLPrivateFactory.sol";
import {CLPrivatePool} from "contracts/core/CLPrivatePool.sol";
import {PrivateNonFungiblePositionManager} from "contracts/periphery/PrivateNonFungiblePositionManager.sol";

/// @dev Deliberately small trusted executor fixture; production must authenticate its users.
contract PrivateManagerProxyFixture {
    PrivateNonFungiblePositionManager public manager;

    constructor(PrivateNonFungiblePositionManager _manager, IERC20 token0, IERC20 token1) {
        manager = _manager;
        token0.approve(address(_manager), type(uint256).max);
        token1.approve(address(_manager), type(uint256).max);
    }

    function mint(INonfungiblePositionManager.MintParams calldata params) external returns (uint256 id) {
        (id,,,) = manager.mint(params);
    }

    function increase(INonfungiblePositionManager.IncreaseLiquidityParams calldata params) external {
        manager.increaseLiquidity(params);
    }

    function stake(CLGauge gauge, uint256 id) external {
        manager.approve(address(gauge), id);
        gauge.deposit(id);
    }

    function claim(CLGauge gauge, uint256 id) external {
        gauge.getReward(id);
    }

    function withdraw(CLGauge gauge, uint256 id) external {
        gauge.withdraw(id);
    }

    function mintAndStake(CLGauge gauge, INonfungiblePositionManager.MintParams calldata params)
        external
        returns (uint256 id)
    {
        (id,,,) = manager.mint(params);
        manager.approve(address(gauge), id);
        gauge.deposit(id);
    }

    function increaseAndRestake(CLGauge gauge, INonfungiblePositionManager.IncreaseLiquidityParams calldata params)
        external
    {
        gauge.withdraw(params.tokenId);
        manager.increaseLiquidity(params);
        manager.approve(address(gauge), params.tokenId);
        gauge.deposit(params.tokenId);
    }

    function decreaseAndRestake(CLGauge gauge, uint256 id, uint128 liquidity) external {
        gauge.withdraw(id);
        manager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: id, liquidity: liquidity, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
            })
        );
        manager.approve(address(gauge), id);
        gauge.deposit(id);
    }

    function exit(CLGauge gauge, uint256 id) external {
        gauge.withdraw(id);
        (,,,,,,, uint128 liquidity,,,,) = manager.positions(id);
        manager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: id, liquidity: liquidity, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
            })
        );
        manager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: id, recipient: address(this), amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
        );
        manager.burn(id);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return 0x150b7a02;
    }
}

contract PrivateNonFungiblePositionManagerTest is BaseFixture {
    CLPrivateFactory internal privateFactory;
    CLPrivatePool internal privatePool;
    CLGaugeFactory internal privateGaugeFactory;
    PrivateNonFungiblePositionManager internal manager;
    PrivateManagerProxyFixture internal proxy;
    CLGauge internal privateGauge;

    function setUp() public override {
        super.setUp();
        vm.startPrank(users.owner);
        privateGaugeFactory = new CLGaugeFactory(address(voter), address(gaugeImplementation));
        privateFactory = new CLPrivateFactory(
            address(voter), address(new CLPrivatePool()), address(privateGaugeFactory), address(gaugeImplementation)
        );
        manager = new PrivateNonFungiblePositionManager(
            users.owner, address(privateFactory), address(weth), address(nftDescriptor), "Private CL", "PCL"
        );
        privateFactory.setNonfungiblePositionManager(address(manager));
        privateGaugeFactory.setNonfungiblePositionManager(address(manager));
        factoryRegistry.approve(address(privateFactory), address(votingRewardsFactory), address(privateGaugeFactory));
        privateFactory.setWhitelist(users.owner, true);
        privateFactory.setWhitelist(address(manager), true);
        privatePool = CLPrivatePool(
            privateFactory.createPool(address(token0), address(token1), int24(100), encodePriceSqrt(1, 1))
        );
        privateGauge = CLGauge(voter.createGauge(address(privateFactory), address(privatePool)));
        vm.stopPrank();
        proxy = new PrivateManagerProxyFixture(manager, IERC20(address(token0)), IERC20(address(token1)));
        deal(address(token0), address(proxy), TOKEN_1 * 100);
        deal(address(token1), address(proxy), TOKEN_1 * 100);
        vm.startPrank(users.alice);
        token0.approve(address(manager), type(uint256).max);
        token1.approve(address(manager), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(users.charlie);
        token0.approve(address(manager), type(uint256).max);
        token1.approve(address(manager), type(uint256).max);
        vm.stopPrank();
    }

    function _params(address recipient) internal view returns (INonfungiblePositionManager.MintParams memory) {
        return INonfungiblePositionManager.MintParams({
            token0: address(token0),
            token1: address(token1),
            tickSpacing: 100,
            tickLower: -100,
            tickUpper: 100,
            amount0Desired: TOKEN_1,
            amount1Desired: TOKEN_1,
            amount0Min: 0,
            amount1Min: 0,
            recipient: recipient,
            deadline: block.timestamp,
            sqrtPriceX96: 0
        });
    }

    function _increase(uint256 id) internal view returns (INonfungiblePositionManager.IncreaseLiquidityParams memory) {
        return INonfungiblePositionManager.IncreaseLiquidityParams({
            tokenId: id,
            amount0Desired: TOKEN_1,
            amount1Desired: TOKEN_1,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp
        });
    }

    function _whitelist(address account, bool allowed) internal {
        vm.prank(users.owner);
        privateFactory.setWhitelist(account, allowed);
    }

    function _public(bool allowed) internal {
        vm.prank(manager.owner());
        manager.setPublicLiquidity(allowed);
    }

    function _mintAlice() internal returns (uint256 id, uint128 liquidity) {
        _whitelist(users.alice, true);
        vm.prank(users.alice);
        (id, liquidity,,) = manager.mint(_params(users.alice));
    }

    function test_DefaultIsPrivateAndImmutableBindingsMatch() public {
        assertFalse(manager.publicLiquidity());
        assertEq(manager.owner(), users.owner);
        assertEq(manager.factory(), address(privateFactory));
        assertEq(manager.WETH9(), address(weth));
        assertEq(manager.tokenDescriptor(), address(nftDescriptor));
    }

    function test_UnlistedMintRevertsWithoutChangingBalancesOrSupply() public {
        uint256 balance0 = token0.balanceOf(users.alice);
        uint256 balance1 = token1.balanceOf(users.alice);
        vm.prank(users.alice);
        vm.expectRevert(bytes("NW"));
        manager.mint(_params(users.alice));
        assertEq(manager.totalSupply(), 0);
        assertEq(uint256(privatePool.liquidity()), 0);
        assertEq(token0.balanceOf(users.alice), balance0);
        assertEq(token1.balanceOf(users.alice), balance1);
    }

    function test_WhitelistedWalletMintsToUnlistedRecipient() public {
        _whitelist(users.alice, true);
        vm.prank(users.alice);
        (uint256 id, uint128 liquidity,,) = manager.mint(_params(users.bob));
        assertEq(manager.ownerOf(id), users.bob);
        assertGt(uint256(liquidity), 0);
        assertEq(uint256(privatePool.liquidity()), uint256(liquidity));
    }

    function test_WhitelistedRecipientDoesNotAuthorizeCaller() public {
        _whitelist(users.bob, true);
        vm.prank(users.alice);
        vm.expectRevert(bytes("NW"));
        manager.mint(_params(users.bob));
    }

    function test_ManagerMustRemainWhitelistedEvenInPublicMode() public {
        _public(true);
        _whitelist(address(manager), false);
        vm.prank(users.alice);
        vm.expectRevert(bytes("NW"));
        manager.mint(_params(users.alice));
    }

    function test_PublicToggleAllowsMintThenClosingBlocksNewMintButAllowsIncrease() public {
        _public(true);
        vm.startPrank(users.alice);
        (uint256 id,,,) = manager.mint(_params(users.alice));
        manager.increaseLiquidity(_increase(id));
        vm.stopPrank();
        _public(false);
        vm.startPrank(users.alice);
        vm.expectRevert(bytes("NW"));
        manager.mint(_params(users.alice));
        manager.increaseLiquidity(_increase(id));
        vm.stopPrank();
    }

    function test_OwnerOnlyPublicToggleAndOwnershipTransfer() public {
        vm.prank(users.alice);
        vm.expectRevert();
        manager.setPublicLiquidity(true);
        vm.prank(users.owner);
        manager.setOwner(users.bob);
        vm.prank(users.owner);
        vm.expectRevert();
        manager.setPublicLiquidity(true);
        vm.prank(users.bob);
        manager.setPublicLiquidity(true);
        assertTrue(manager.publicLiquidity());
        assertEq(privateFactory.owner(), users.owner);
    }

    function test_FactoryOwnerTransferDoesNotTransferManagerAdmin() public {
        vm.prank(users.owner);
        privateFactory.setOwner(users.bob);
        vm.prank(users.bob);
        vm.expectRevert();
        manager.setPublicLiquidity(true);
        _public(true);
        assertTrue(manager.publicLiquidity());
    }

    function test_WhitelistRevocationAllowsOwnerIncrease() public {
        (uint256 id, uint128 liquidity) = _mintAlice();
        _whitelist(users.alice, false);
        vm.prank(users.alice);
        manager.increaseLiquidity(_increase(id));
        (,,,,,,, uint128 afterLiquidity,,,,) = manager.positions(id);
        assertGt(uint256(afterLiquidity), uint256(liquidity));
    }

    function test_RevokingManagerBlocksLiquidityIncreaseAtPool() public {
        (uint256 id, uint128 liquidity) = _mintAlice();
        _whitelist(address(manager), false);
        vm.prank(users.alice);
        vm.expectRevert(bytes("NW"));
        manager.increaseLiquidity(_increase(id));
        (,,,,,,, uint128 afterLiquidity,,,,) = manager.positions(id);
        assertEq(uint256(afterLiquidity), uint256(liquidity));
    }

    function test_UnlistedApprovedAccountCanIncrease() public {
        (uint256 id,) = _mintAlice();
        vm.prank(users.alice);
        manager.approve(users.charlie, id);
        vm.prank(users.charlie);
        manager.increaseLiquidity(_increase(id));
    }

    function test_UnlistedNonownerCanDonateLiquidityAsInPublicManager() public {
        (uint256 id, uint128 liquidity) = _mintAlice();
        assertFalse(privateFactory.isWhitelisted(users.charlie));
        vm.prank(users.charlie);
        manager.increaseLiquidity(_increase(id));
        (,,,,,,, uint128 afterLiquidity,,,,) = manager.positions(id);
        assertGt(uint256(afterLiquidity), uint256(liquidity));
        assertEq(manager.ownerOf(id), users.alice);
    }

    function test_UnauthorizedMulticallCannotBypassMintGuard() public {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(manager.mint.selector, _params(users.alice));
        vm.prank(users.alice);
        vm.expectRevert(bytes("NW"));
        manager.multicall(calls);
        assertEq(manager.totalSupply(), 0);
    }

    function test_UnlistedNestedMulticallCanIncreaseExistingPosition() public {
        (uint256 id, uint128 initialLiquidity) = _mintAlice();
        _whitelist(users.alice, false);
        bytes[] memory inner = new bytes[](1);
        inner[0] = abi.encodeWithSelector(manager.increaseLiquidity.selector, _increase(id));
        bytes[] memory outer = new bytes[](1);
        outer[0] = abi.encodeWithSelector(manager.multicall.selector, inner);
        vm.prank(users.alice);
        manager.multicall(outer);
        (,,,,,,, uint128 liquidity,,,,) = manager.positions(id);
        assertGt(uint256(liquidity), uint256(initialLiquidity));
    }

    function test_WhitelistedMulticallMintAndIncrease() public {
        _whitelist(users.alice, true);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(manager.mint.selector, _params(users.alice));
        calls[1] = abi.encodeWithSelector(manager.increaseLiquidity.selector, _increase(1));
        vm.prank(users.alice);
        manager.multicall(calls);
        assertEq(manager.totalSupply(), 1);
        assertEq(manager.ownerOf(1), users.alice);
    }

    function test_UnauthorizedMintCannotCreatePoolUsingSqrtPrice() public {
        INonfungiblePositionManager.MintParams memory params = _params(users.alice);
        params.tickSpacing = 200;
        params.tickLower = -200;
        params.tickUpper = 200;
        params.sqrtPriceX96 = encodePriceSqrt(1, 1);
        vm.prank(users.alice);
        vm.expectRevert(bytes("NW"));
        manager.mint(params);
        assertEq(privateFactory.getPool(address(token0), address(token1), int24(200)), address(0));
    }

    function test_WhitelistedManagerCreatesPoolDuringAuthorizedMint() public {
        _whitelist(users.alice, true);
        INonfungiblePositionManager.MintParams memory params = _params(users.alice);
        params.tickSpacing = 200;
        params.tickLower = -200;
        params.tickUpper = 200;
        params.sqrtPriceX96 = encodePriceSqrt(1, 1);
        vm.prank(users.alice);
        manager.mint(params);
        assertTrue(privateFactory.getPool(address(token0), address(token1), int24(200)) != address(0));
    }

    function test_PublicLiquidityDoesNotOpenPoolCreationThroughMint() public {
        _public(true);
        INonfungiblePositionManager.MintParams memory params = _params(users.alice);
        params.tickSpacing = 200;
        params.tickLower = -200;
        params.tickUpper = 200;
        params.sqrtPriceX96 = encodePriceSqrt(1, 1);
        vm.prank(users.alice);
        vm.expectRevert(bytes("NW"));
        manager.mint(params);
        assertEq(privateFactory.getPool(address(token0), address(token1), int24(200)), address(0));
        assertEq(manager.totalSupply(), 0);
    }

    function test_ProxyMintStakeRevocationIncreaseDecreaseRestakeAndExit() public {
        _whitelist(address(proxy), true);
        vm.prank(users.alice);
        uint256 id = proxy.mintAndStake(privateGauge, _params(address(proxy)));
        assertEq(manager.ownerOf(id), address(privateGauge));
        (,,,,,,, uint128 initialLiquidity,,,,) = manager.positions(id);
        vm.prank(users.alice);
        vm.expectRevert(bytes("NW"));
        manager.mint(_params(users.alice));

        addRewardToGauge(address(voter), address(privateGauge), TOKEN_1);
        skip(1 days);
        _whitelist(address(proxy), false);
        vm.expectRevert(bytes("NW"));
        proxy.mint(_params(address(proxy)));
        proxy.claim(privateGauge, id);
        assertGt(rewardToken.balanceOf(address(proxy)), 0);

        proxy.increaseAndRestake(privateGauge, _increase(id));
        assertEq(manager.ownerOf(id), address(privateGauge));
        (,,,,,,, uint128 increasedLiquidity,,,,) = manager.positions(id);
        assertGt(uint256(increasedLiquidity), uint256(initialLiquidity));
        proxy.decreaseAndRestake(privateGauge, id, increasedLiquidity / 2);
        assertEq(manager.ownerOf(id), address(privateGauge));
        (,,,,,,, uint128 decreasedLiquidity,,,,) = manager.positions(id);
        assertEq(uint256(decreasedLiquidity), uint256(increasedLiquidity - increasedLiquidity / 2));

        uint256 before0 = token0.balanceOf(address(proxy));
        uint256 before1 = token1.balanceOf(address(proxy));
        proxy.exit(privateGauge, id);
        assertEq(manager.totalSupply(), 0);
        assertEq(uint256(privatePool.stakedLiquidity()), 0);
        assertEq(uint256(privatePool.liquidity()), 0);
        assertGt(token0.balanceOf(address(proxy)), before0);
        assertGt(token1.balanceOf(address(proxy)), before1);
    }

    function test_StakedProxyPositionCannotBeManipulatedByUser() public {
        _whitelist(address(proxy), true);
        uint256 id = proxy.mintAndStake(privateGauge, _params(address(proxy)));
        (,,,,,,, uint128 liquidity,,,,) = manager.positions(id);
        vm.startPrank(users.alice);
        vm.expectRevert();
        manager.increaseLiquidity(_increase(id));
        vm.expectRevert(bytes("NA"));
        privateGauge.withdraw(id);
        vm.expectRevert(bytes("NA"));
        privateGauge.getReward(id);
        vm.expectRevert();
        manager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: id, liquidity: liquidity, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
            })
        );
        vm.expectRevert();
        manager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: id, recipient: users.alice, amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
        );
        vm.expectRevert();
        manager.transferFrom(address(privateGauge), users.alice, id);
        vm.expectRevert();
        manager.approve(users.alice, id);
        vm.expectRevert();
        manager.burn(id);
        vm.stopPrank();
        assertEq(manager.ownerOf(id), address(privateGauge));
        (,,,,,,, uint128 afterLiquidity,,,,) = manager.positions(id);
        assertEq(uint256(afterLiquidity), uint256(liquidity));
    }

    function test_ProxyCannotIncreaseWhileStakedEvenWhenWhitelisted() public {
        _whitelist(address(proxy), true);
        uint256 id = proxy.mintAndStake(privateGauge, _params(address(proxy)));
        vm.expectRevert();
        proxy.increase(_increase(id));
    }

    function test_WhitelistTxOriginDoesNotAuthorizeProxy() public {
        _whitelist(users.alice, true);
        vm.prank(users.alice, users.alice);
        vm.expectRevert(bytes("NW"));
        proxy.mint(_params(address(proxy)));
    }

    function test_RevokedWalletAndManagerCanStillExitCollectAndBurn() public {
        (uint256 id, uint128 liquidity) = _mintAlice();
        _whitelist(users.alice, false);
        _whitelist(address(manager), false);
        uint256 before0 = token0.balanceOf(users.alice);
        uint256 before1 = token1.balanceOf(users.alice);
        vm.startPrank(users.alice);
        manager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: id, liquidity: liquidity, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
            })
        );
        manager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: id, recipient: users.alice, amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
        );
        manager.burn(id);
        vm.stopPrank();
        assertGt(token0.balanceOf(users.alice), before0);
        assertGt(token1.balanceOf(users.alice), before1);
        assertEq(manager.totalSupply(), 0);
        assertEq(manager.userPositions(users.alice, address(privatePool)).length, 0);
    }

    function test_UnlistedOwnerCanTransferAndApproveNft() public {
        (uint256 id,) = _mintAlice();
        _whitelist(users.alice, false);
        vm.prank(users.alice);
        manager.approve(users.charlie, id);
        vm.prank(users.charlie);
        manager.transferFrom(users.alice, users.bob, id);
        assertEq(manager.ownerOf(id), users.bob);
        assertEq(manager.userPositions(users.alice, address(privatePool)).length, 0);
        assertEq(manager.userPositions(users.bob, address(privatePool)).length, 1);
    }

    function test_PublicModeRetainsOwnerAuthorizationForExits() public {
        (uint256 id, uint128 liquidity) = _mintAlice();
        _public(true);
        vm.startPrank(users.charlie);
        vm.expectRevert();
        manager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: id, liquidity: liquidity, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
            })
        );
        vm.expectRevert();
        manager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: id, recipient: users.charlie, amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
        );
        vm.expectRevert();
        manager.burn(id);
        vm.stopPrank();
    }

    function test_PublicModeDoesNotOpenFactoryCreationToWallets() public {
        _public(true);
        vm.prank(users.alice);
        vm.expectRevert(bytes("NW"));
        privateFactory.createPool(address(token0), address(token1), int24(200), encodePriceSqrt(1, 1));
    }

    function test_CallbackAuthenticationUnchanged() public {
        vm.prank(users.alice);
        vm.expectRevert();
        manager.uniswapV3MintCallback(1, 1, abi.encode(address(token0), address(token1), int24(100), users.alice));
    }

    function test_DeploymentFitsEip170RuntimeLimit() public {
        address target = address(manager);
        uint256 size;
        assembly { size := extcodesize(target) }
        assertLe(size, 24576);
    }

    function testFuzz_MintAuthorization(bool publicMode, bool callerAllowed, bool managerAllowed) public {
        _public(publicMode);
        _whitelist(users.alice, callerAllowed);
        _whitelist(address(manager), managerAllowed);
        vm.prank(users.alice);
        if ((!publicMode && !callerAllowed) || !managerAllowed) vm.expectRevert(bytes("NW"));
        manager.mint(_params(users.alice));
        assertEq(manager.totalSupply(), ((publicMode || callerAllowed) && managerAllowed) ? 1 : 0);
    }
}
