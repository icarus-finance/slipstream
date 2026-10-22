pragma solidity ^0.7.6;
pragma abicoder v2;

import "../../../BaseFixture.sol";
import {PrivateSwapFeeModule} from "contracts/core/fees/PrivateSwapFeeModule.sol";
import {CLPrivateFactory} from "contracts/core/CLPrivateFactory.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {CLPrivatePool} from "contracts/core/CLPrivatePool.sol";

contract PrivateFeeModuleStub {
    uint24 public fee;
    bool public failing;

    function configure(uint24 value, bool fail) external {
        fee = value;
        failing = fail;
    }

    function getFee(address) external view returns (uint24) {
        require(!failing);
        return fee;
    }
}

contract CLPrivateFactoryTest is BaseFixture {
    CLPrivateFactory privateFactory;
    CLPrivatePool privateImplementation;
    uint160 constant PRICE = 79228162514264337593543950336;

    function setUp() public override {
        super.setUp();
        vm.startPrank(users.owner);
        privateImplementation = new CLPrivatePool();
        privateFactory = new CLPrivateFactory(
            address(voter), address(privateImplementation), address(gaugeFactory), address(gaugeImplementation)
        );
        vm.stopPrank();
    }

    function authorize(address account) internal {
        vm.prank(users.owner);
        privateFactory.setWhitelist(account, true);
    }

    function create(int24 spacing) internal returns (address) {
        authorize(address(this));
        return privateFactory.createPool(address(token1), address(token0), spacing, PRICE);
    }

    function test_DefaultStateAndEveryInitialSpacingCreatesAtZero() public {
        assertFalse(privateFactory.isWhitelisted(users.owner));
        assertEq(privateFactory.owner(), users.owner);
        assertEq(privateFactory.swapFeeManager(), users.owner);
        assertEq(privateFactory.unstakedFeeManager(), users.owner);
        assertEq(address(privateFactory.voter()), address(voter));
        assertEq(address(privateFactory.factoryRegistry()), address(factoryRegistry));
        assertEq(privateFactory.poolImplementation(), address(privateImplementation));
        assertEq(privateFactory.gaugeImplementation(), address(gaugeImplementation));
        assertEq(privateFactory.gaugeFactory(), address(gaugeFactory));
        assertTrue(privateFactory.swapFeeModule() != address(0));
        assertEq(address(PrivateSwapFeeModule(privateFactory.swapFeeModule()).factory()), address(privateFactory));
        int24[] memory spacings = privateFactory.tickSpacings();
        assertEq(spacings.length, 5);
        for (uint256 i; i < spacings.length; i++) {
            assertGt(uint256(privateFactory.tickSpacingToFee(spacings[i])), 0);
            address pool = create(spacings[i]);
            assertEq(uint256(privateFactory.getSwapFee(pool)), 0);
            assertEq(privateFactory.allPools(i), pool);
            assertTrue(privateFactory.isPool(pool));
            assertTrue(privateFactory.isPair(pool));
            assertEq(privateFactory.getPool(address(token0), address(token1), spacings[i]), pool);
            assertEq(privateFactory.getPool(address(token1), address(token0), uint24(spacings[i])), pool);
            assertEq(CLPrivatePool(pool).factory(), address(privateFactory));
            assertEq(CLPrivatePool(pool).token0(), address(token0));
            assertEq(CLPrivatePool(pool).token1(), address(token1));
        }
        assertEq(privateFactory.allPoolsLength(), 5);
    }

    function test_BothCreationOverloadsRequireWhitelistEvenOwner() public {
        vm.expectRevert(bytes("NW"));
        privateFactory.createPool(address(token0), address(token1), int24(1), PRICE);
        vm.expectRevert(bytes("NW"));
        vm.prank(users.owner);
        privateFactory.createPool(address(token0), address(token1), uint24(1));
        authorize(address(this));
        address pool = privateFactory.createPool(address(token0), address(token1), uint24(1));
        (uint160 price,,,,,) = CLPrivatePool(pool).slot0();
        assertEq(uint256(price), uint256(PRICE));
    }

    function test_RevocationBlocksBothCreationOverloads() public {
        authorize(address(this));
        vm.prank(users.owner);
        privateFactory.setWhitelist(address(this), false);
        vm.expectRevert(bytes("NW"));
        privateFactory.createPool(address(token0), address(token1), uint24(1));
        vm.expectRevert(bytes("NW"));
        privateFactory.createPool(address(token0), address(token1), int24(1), PRICE);
    }

    function test_OnlyOwnerCanConfigurePermissions() public {
        vm.expectRevert();
        privateFactory.setWhitelist(users.alice, true);
        vm.startPrank(users.owner);
        vm.expectRevert();
        privateFactory.setWhitelist(address(0), true);
        privateFactory.setOwner(users.alice);
        vm.expectRevert();
        privateFactory.setWhitelist(users.bob, true);
        vm.stopPrank();
        vm.prank(users.alice);
        privateFactory.setWhitelist(users.bob, true);
        assertTrue(privateFactory.isWhitelisted(users.bob));
    }

    function test_CreateRejectsInvalidTokensSpacingPriceAndDuplicates() public {
        authorize(address(this));
        vm.expectRevert();
        privateFactory.createPool(address(token0), address(token0), int24(1), PRICE);
        vm.expectRevert();
        privateFactory.createPool(address(0), address(token0), int24(1), PRICE);
        vm.expectRevert();
        privateFactory.createPool(address(token0), address(token1), int24(2), PRICE);
        vm.expectRevert();
        privateFactory.createPool(address(token0), address(token1), int24(1), 0);
        create(1);
        vm.expectRevert();
        privateFactory.createPool(address(token1), address(token0), uint24(1));
        assertEq(privateFactory.allPoolsLength(), 1);
    }

    function test_SpacingEnabledOnlyOnceAndModuleDefaultsToZero() public {
        vm.startPrank(users.owner);
        privateFactory.enableTickSpacing(2, 100);
        vm.expectRevert();
        privateFactory.enableTickSpacing(2, 100);
        vm.expectRevert();
        privateFactory.enableTickSpacing(1, 100);
        vm.stopPrank();
        assertEq(uint256(privateFactory.getSwapFee(create(2))), 0);
    }

    function test_EnableSpacingAuthorizationAndBounds() public {
        vm.expectRevert();
        privateFactory.enableTickSpacing(2, 100);
        vm.startPrank(users.owner);
        vm.expectRevert();
        privateFactory.enableTickSpacing(0, 100);
        vm.expectRevert();
        privateFactory.enableTickSpacing(-1, 100);
        vm.expectRevert();
        privateFactory.enableTickSpacing(16384, 100);
        vm.expectRevert();
        privateFactory.enableTickSpacing(2, 100001);
        privateFactory.enableTickSpacing(16383, 100000);
        vm.stopPrank();
        assertEq(uint256(privateFactory.tickSpacingToFee(16383)), 100000);
    }

    function test_FeeSetterAuthorizationBoundsAndExistingPool() public {
        address pool = create(1);
        PrivateSwapFeeModule module = PrivateSwapFeeModule(privateFactory.swapFeeModule());
        vm.expectRevert();
        module.setCustomFee(pool, 100);
        vm.startPrank(users.owner);
        vm.expectRevert();
        module.setCustomFee(users.alice, 100);
        vm.expectRevert();
        module.setCustomFee(pool, 30001);
        privateFactory.setSwapFeeManager(users.feeManager);
        vm.expectRevert();
        module.setCustomFee(pool, 100);
        vm.stopPrank();
        vm.prank(users.feeManager);
        module.setCustomFee(pool, 30000);
        assertEq(uint256(privateFactory.getSwapFee(pool)), 30000);
        vm.prank(users.feeManager);
        module.setCustomFee(pool, 0);
        assertEq(uint256(privateFactory.getSwapFee(pool)), 0);
        assertEq(uint256(privateFactory.tickSpacingToFee(1)), 100);
    }

    function test_FeeModulePriorityAndFallback() public {
        address pool = create(1);
        PrivateFeeModuleStub module = new PrivateFeeModuleStub();
        vm.startPrank(users.owner);
        privateFactory.setSwapFeeModule(address(module));
        vm.stopPrank();
        module.configure(1000, false);
        assertEq(uint256(privateFactory.getSwapFee(pool)), 1000);
        module.configure(0, false);
        assertEq(uint256(privateFactory.getSwapFee(pool)), 0);
        module.configure(100001, false);
        assertEq(uint256(privateFactory.getSwapFee(pool)), 100);
        module.configure(1000, true);
        assertEq(uint256(privateFactory.getSwapFee(pool)), 100);
    }

    function test_ReplacingWithPublicModuleRestoresSpacingDefaults() public {
        address pool = create(1);
        CustomSwapFeeModule module = new CustomSwapFeeModule(address(privateFactory));
        vm.startPrank(users.owner);
        privateFactory.setSwapFeeModule(address(module));
        assertEq(uint256(privateFactory.getSwapFee(pool)), 100);
        module.setCustomFee(pool, 3000);
        assertEq(uint256(privateFactory.getSwapFee(pool)), 3000);
        module.setCustomFee(pool, uint24(module.ZERO_FEE_INDICATOR()));
        assertEq(uint256(privateFactory.getSwapFee(pool)), 0);
        module.setCustomFee(pool, 0);
        assertEq(uint256(privateFactory.getSwapFee(pool)), 100);
        vm.stopPrank();
    }

    function test_NftSetOnceAndUnstakedFeeRolesPreserved() public {
        vm.expectRevert();
        privateFactory.setNonfungiblePositionManager(address(nft));
        vm.startPrank(users.owner);
        vm.expectRevert();
        privateFactory.setNonfungiblePositionManager(address(0));
        privateFactory.setNonfungiblePositionManager(address(nft));
        vm.expectRevert();
        privateFactory.setNonfungiblePositionManager(users.alice);
        privateFactory.setDefaultUnstakedFee(500000);
        vm.expectRevert();
        privateFactory.setDefaultUnstakedFee(500001);
        privateFactory.setUnstakedFeeManager(users.feeManager);
        vm.expectRevert();
        privateFactory.setDefaultUnstakedFee(0);
        vm.stopPrank();
        address pool = create(1);
        assertEq(CLPrivatePool(pool).nft(), address(nft));
        assertEq(uint256(privateFactory.getUnstakedFee(pool)), 500000);
        vm.prank(users.feeManager);
        privateFactory.setDefaultUnstakedFee(0);
        assertEq(uint256(privateFactory.getUnstakedFee(pool)), 0);
    }

    event WhitelistUpdated(address indexed account, bool allowed);

    function test_PermissionAndFeeEvents() public {
        address pool = create(1);
        PrivateSwapFeeModule module = PrivateSwapFeeModule(privateFactory.swapFeeModule());
        vm.startPrank(users.owner);
        vm.expectEmit(true, false, false, true, address(privateFactory));
        emit WhitelistUpdated(users.alice, true);
        privateFactory.setWhitelist(users.alice, true);
        vm.expectEmit(true, false, false, true, address(privateFactory));
        emit WhitelistUpdated(users.alice, false);
        privateFactory.setWhitelist(users.alice, false);
        vm.expectEmit(true, true, false, true, address(module));
        emit SetCustomFee(pool, 999);
        module.setCustomFee(pool, 999);
        vm.expectEmit(true, true, false, true, address(module));
        emit SetCustomFee(pool, 0);
        module.setCustomFee(pool, 0);
        vm.stopPrank();
    }

    function test_RoleTransfersRejectUnauthorizedAndZero() public {
        vm.expectRevert();
        privateFactory.setOwner(users.alice);
        vm.expectRevert();
        privateFactory.setSwapFeeManager(users.alice);
        vm.expectRevert();
        privateFactory.setUnstakedFeeManager(users.alice);
        vm.startPrank(users.owner);
        vm.expectRevert();
        privateFactory.setOwner(address(0));
        vm.expectRevert();
        privateFactory.setSwapFeeManager(address(0));
        vm.expectRevert();
        privateFactory.setUnstakedFeeManager(address(0));
        privateFactory.setOwner(users.alice);
        // Owner rotation deliberately does not transfer the independently managed fee roles.
        privateFactory.setSwapFeeManager(users.bob);
        privateFactory.setUnstakedFeeManager(users.charlie);
        vm.expectRevert();
        privateFactory.setSwapFeeManager(users.alice);
        vm.expectRevert();
        privateFactory.setUnstakedFeeManager(users.alice);
        vm.stopPrank();
        assertEq(privateFactory.owner(), users.alice);
        assertEq(privateFactory.swapFeeManager(), users.bob);
        assertEq(privateFactory.unstakedFeeManager(), users.charlie);
        vm.prank(users.bob);
        privateFactory.setSwapFeeManager(users.alice);
        vm.prank(users.charlie);
        privateFactory.setUnstakedFeeManager(users.alice);
    }

    function test_ModuleSettersKeepIndependentAuthorization() public {
        vm.expectRevert();
        privateFactory.setSwapFeeModule(users.alice);
        vm.expectRevert();
        privateFactory.setUnstakedFeeModule(users.alice);
        vm.startPrank(users.owner);
        vm.expectRevert();
        privateFactory.setSwapFeeModule(address(0));
        vm.expectRevert();
        privateFactory.setUnstakedFeeModule(address(0));
        privateFactory.setSwapFeeManager(users.alice);
        privateFactory.setUnstakedFeeManager(users.bob);
        vm.expectRevert();
        privateFactory.setSwapFeeModule(users.charlie);
        vm.expectRevert();
        privateFactory.setUnstakedFeeModule(users.charlie);
        vm.stopPrank();
        vm.prank(users.alice);
        privateFactory.setSwapFeeModule(users.charlie);
        vm.prank(users.bob);
        privateFactory.setUnstakedFeeModule(users.charlie);
        assertEq(privateFactory.swapFeeModule(), users.charlie);
        assertEq(privateFactory.unstakedFeeModule(), users.charlie);
    }

    function test_UnstakedModulePriorityAndFallback() public {
        address pool = create(1);
        assertEq(uint256(privateFactory.getUnstakedFee(pool)), 100000);
        PrivateFeeModuleStub module = new PrivateFeeModuleStub();
        vm.prank(users.owner);
        privateFactory.setUnstakedFeeModule(address(module));
        module.configure(1000000, false);
        assertEq(uint256(privateFactory.getUnstakedFee(pool)), 1000000);
        module.configure(0, false);
        assertEq(uint256(privateFactory.getUnstakedFee(pool)), 0);
        module.configure(1000001, false);
        assertEq(uint256(privateFactory.getUnstakedFee(pool)), 100000);
        module.configure(0, true);
        assertEq(uint256(privateFactory.getUnstakedFee(pool)), 100000);
    }

    function test_PoolAddressMatchesDeterministicPredictionAndCannotReinitialize() public {
        bytes32 salt = keccak256(abi.encode(address(token0), address(token1), int24(1)));
        address predicted =
            Clones.predictDeterministicAddress(address(privateImplementation), salt, address(privateFactory));
        address pool = create(1);
        assertEq(pool, predicted);
        vm.expectRevert();
        CLPrivatePool(pool)
            .initialize(address(privateFactory), address(token0), address(token1), 1, users.alice, users.bob, PRICE);
    }

    function testFuzz_WhitelistIndependentAccounts(address account) public {
        vm.assume(account != address(0) && account != users.owner);
        vm.startPrank(users.owner);
        privateFactory.setWhitelist(account, true);
        assertTrue(privateFactory.isWhitelisted(account));
        assertFalse(privateFactory.isWhitelisted(users.owner));
        privateFactory.setWhitelist(account, false);
        assertFalse(privateFactory.isWhitelisted(account));
        vm.stopPrank();
    }

    function testFuzz_PerPoolFeeRoundTrip(uint24 fee) public {
        fee = uint24(bound(uint256(fee), 0, 30000));
        address pool = create(1);
        PrivateSwapFeeModule module = PrivateSwapFeeModule(privateFactory.swapFeeModule());
        vm.startPrank(users.owner);
        module.setCustomFee(pool, fee);
        assertEq(uint256(module.customFee(pool)), uint256(fee));
        assertEq(uint256(privateFactory.getSwapFee(pool)), fee == 420 ? 0 : uint256(fee));
        module.setCustomFee(pool, 0);
        vm.stopPrank();
        assertEq(uint256(privateFactory.getSwapFee(pool)), 0);
        assertEq(uint256(privateFactory.tickSpacingToFee(1)), 100);
    }

    function test_OverridesArePerPoolAndNewSpacingsStillDefaultToZero() public {
        address first = create(1);
        address second = create(50);
        PrivateSwapFeeModule module = PrivateSwapFeeModule(privateFactory.swapFeeModule());
        vm.startPrank(users.owner);
        module.setCustomFee(first, 3000);
        privateFactory.enableTickSpacing(25, 10000);
        vm.stopPrank();
        address third = create(25);
        address sameSpacing = privateFactory.createPool(address(token0), address(rewardToken), int24(1), PRICE);
        assertEq(uint256(privateFactory.getSwapFee(sameSpacing)), 0);
        assertEq(uint256(privateFactory.getSwapFee(first)), 3000);
        assertEq(uint256(privateFactory.getSwapFee(second)), 0);
        assertEq(uint256(privateFactory.getSwapFee(third)), 0);
        // No pool call is needed to return the unset default.
        assertEq(uint256(module.getFee(address(0))), 0);
        uint24 zeroIndicator = uint24(module.ZERO_FEE_INDICATOR());
        vm.prank(users.owner);
        module.setCustomFee(first, zeroIndicator);
        assertEq(uint256(privateFactory.getSwapFee(first)), 0);
    }

    function test_ZeroSpacingFeeStillRejectedLikePublicFactory() public {
        vm.prank(users.owner);
        vm.expectRevert();
        privateFactory.enableTickSpacing(25, 0);
    }
}
