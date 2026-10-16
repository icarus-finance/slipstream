// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import "../../../BaseFixture.sol";
import {PrivateSwapFeeModule} from "contracts/core/fees/PrivateSwapFeeModule.sol";
import {CLPrivateFactory} from "contracts/core/CLPrivateFactory.sol";
import {TickMath} from "contracts/core/libraries/TickMath.sol";
import {CLPrivatePool} from "contracts/core/CLPrivatePool.sol";

contract CLPrivatePoolTest is BaseFixture {
    CLPrivateFactory internal privateFactory;
    CLPrivatePool internal pool;
    uint128 internal constant LIQUIDITY = 1e18;

    function setUp() public override {
        super.setUp();
        vm.startPrank(users.owner);
        privateFactory = new CLPrivateFactory(
            address(voter), address(new CLPrivatePool()), address(gaugeFactory), address(gaugeImplementation)
        );
        privateFactory.setWhitelist(users.owner, true);
        privateFactory.setWhitelist(address(clCallee), true);
        pool = CLPrivatePool(
            privateFactory.createPool(address(token0), address(token1), int24(100), encodePriceSqrt(1, 1))
        );
        vm.stopPrank();
        vm.prank(users.alice);
        clCallee.mint(address(pool), users.alice, -1000, 1000, LIQUIDITY);
    }

    function _allowCallee(bool allowed) internal {
        vm.prank(users.owner);
        privateFactory.setWhitelist(address(clCallee), allowed);
    }

    function _assertNoFees() internal {
        assertEq(uint256(pool.fee()), 0);
        assertEq(pool.feeGrowthGlobal0X128(), 0);
        assertEq(pool.feeGrowthGlobal1X128(), 0);
        (uint128 fee0, uint128 fee1) = pool.gaugeFees();
        assertEq(uint256(fee0), 0);
        assertEq(uint256(fee1), 0);
    }

    bool internal underpay;
    bool internal probeReentrancy;
    bool internal reentrancyChecked;

    function _prepareCallbacks() internal {
        vm.prank(users.owner);
        privateFactory.setWhitelist(address(this), true);
        deal(address(token0), address(this), 1e20);
        deal(address(token1), address(this), 1e20);
    }

    function uniswapV3MintCallback(uint256 amount0, uint256 amount1, bytes calldata) external {
        require(msg.sender == address(pool));
        if (probeReentrancy) _probeReentrancy();
        if (!underpay) {
            token0.transfer(msg.sender, amount0);
            token1.transfer(msg.sender, amount1);
        }
    }

    function uniswapV3SwapCallback(int256 amount0, int256 amount1, bytes calldata) external {
        require(msg.sender == address(pool));
        if (probeReentrancy) _probeReentrancy();
        if (!underpay) {
            if (amount0 > 0) token0.transfer(msg.sender, uint256(amount0));
            if (amount1 > 0) token1.transfer(msg.sender, uint256(amount1));
        }
    }

    function uniswapV3FlashCallback(uint256, uint256, bytes calldata) external {
        require(msg.sender == address(pool));
        _probeReentrancy();
    }

    function _probeReentrancy() internal {
        vm.expectRevert(bytes("LOK"));
        pool.flash(address(this), 0, 0, "");
        vm.expectRevert(bytes("LOK"));
        pool.mint(address(this), -1000, 1000, 1, "");
        vm.expectRevert(bytes("LOK"));
        pool.swap(address(this), true, 1, TickMath.MIN_SQRT_RATIO + 1, "");
        reentrancyChecked = true;
    }

    function test_WhitelistDoesNotBypassMintPayment() public {
        _prepareCallbacks();
        underpay = true;
        vm.expectRevert(bytes("M0"));
        pool.mint(address(this), -1000, 1000, 1e12, "");
        assertEq(uint256(pool.liquidity()), LIQUIDITY);
    }

    function test_WhitelistDoesNotBypassSwapPayment() public {
        _prepareCallbacks();
        underpay = true;
        vm.expectRevert(bytes("IIA"));
        pool.swap(address(this), true, 1e12, TickMath.MIN_SQRT_RATIO + 1, "");
        vm.expectRevert(bytes("IIA"));
        pool.swap(address(this), false, 1e12, TickMath.MAX_SQRT_RATIO - 1, "");
        (uint160 price,,,,,) = pool.slot0();
        assertEq(uint256(price), encodePriceSqrt(1, 1));
    }

    function test_WhitelistedCallbacksCannotReenterAnyRestrictedOperation() public {
        _prepareCallbacks();
        probeReentrancy = true;
        pool.mint(address(this), -1000, 1000, 1e12, "");
        assertTrue(reentrancyChecked);
        reentrancyChecked = false;
        pool.swap(address(this), true, 1e12, TickMath.MIN_SQRT_RATIO + 1, "");
        assertTrue(reentrancyChecked);
        reentrancyChecked = false;
        pool.flash(address(this), 0, 0, "");
        assertTrue(reentrancyChecked);
    }

    function test_ImplementationFitsEip170RuntimeLimit() public {
        address implementation = privateFactory.poolImplementation();
        uint256 size;
        assembly { size := extcodesize(implementation) }
        assertLe(size, 24576);
    }

    function test_InitializedStateAndCannotReinitialize() public {
        assertEq(pool.factory(), address(privateFactory));
        assertEq(pool.token0(), address(token0));
        assertEq(pool.token1(), address(token1));
        assertEq(int256(pool.tickSpacing()), 100);
        assertEq(uint256(pool.liquidity()), LIQUIDITY);
        vm.expectRevert();
        pool.initialize(
            address(privateFactory),
            address(token0),
            address(token1),
            100,
            address(0),
            address(0),
            encodePriceSqrt(1, 1)
        );
    }

    function test_WhitelistedWalletCannotUseUnapprovedForwarder() public {
        _allowCallee(false);
        vm.prank(users.owner);
        privateFactory.setWhitelist(users.alice, true);
        vm.prank(users.alice);
        vm.expectRevert(bytes("NW"));
        clCallee.swapExact0For1(address(pool), 1e12, users.alice, TickMath.MIN_SQRT_RATIO + 1);
    }

    function test_WhitelistDoesNotGrantGaugeOrNftAuthority() public {
        vm.startPrank(users.owner);
        vm.expectRevert(bytes("NG"));
        pool.collectFees();
        vm.expectRevert(bytes("NNFT"));
        pool.burn(-1000, 1000, 1, users.alice);
        vm.stopPrank();
    }

    function test_RejectsUnapprovedDirectSwap() public {
        vm.prank(users.alice);
        vm.expectRevert(bytes("NW"));
        pool.swap(users.alice, true, 1, TickMath.MIN_SQRT_RATIO + 1, "");
    }

    function test_RejectsUnapprovedDirectMint() public {
        vm.prank(users.alice);
        vm.expectRevert(bytes("NW"));
        pool.mint(users.alice, -1000, 1000, 1, "");
    }

    function test_RejectsUnapprovedDirectFlash() public {
        vm.prank(users.alice);
        vm.expectRevert(bytes("NW"));
        pool.flash(users.alice, 1, 1, "");
    }

    function test_RevocationBlocksAllRestrictedOperationsAndReapprovalRestores() public {
        _allowCallee(false);
        vm.startPrank(users.alice);
        vm.expectRevert(bytes("NW"));
        clCallee.swapExact0For1(address(pool), 1e10, users.alice, TickMath.MIN_SQRT_RATIO + 1);
        vm.expectRevert(bytes("NW"));
        clCallee.flash(address(pool), users.alice, 1, 1, 1, 1);
        vm.expectRevert(bytes("NW"));
        clCallee.mint(address(pool), users.alice, -1000, 1000, 1e10);
        vm.stopPrank();
        _allowCallee(true);
        vm.startPrank(users.alice);
        clCallee.swapExact0For1(address(pool), 1e10, users.alice, TickMath.MIN_SQRT_RATIO + 1);
        clCallee.flash(address(pool), users.alice, 1, 1, 1, 1);
        clCallee.mint(address(pool), users.alice, -1000, 1000, 1e10);
        vm.stopPrank();
    }

    function test_BurnAndCollectRemainAvailableWithoutWhitelist() public {
        _allowCallee(false);
        uint256 before0 = token0.balanceOf(users.alice);
        uint256 before1 = token1.balanceOf(users.alice);
        vm.startPrank(users.alice);
        (uint256 burned0, uint256 burned1) = pool.burn(-1000, 1000, LIQUIDITY);
        pool.collect(users.alice, -1000, 1000, type(uint128).max, type(uint128).max);
        vm.stopPrank();
        assertEq(uint256(pool.liquidity()), 0);
        assertEq(token0.balanceOf(users.alice) - before0, burned0);
        assertEq(token1.balanceOf(users.alice) - before1, burned1);
    }

    function test_ZeroFeeExactInputBothDirections() public {
        vm.startPrank(users.alice);
        clCallee.swapExact0For1(address(pool), 1e12, users.alice, TickMath.MIN_SQRT_RATIO + 1);
        clCallee.swapExact1For0(address(pool), 1e12, users.alice, TickMath.MAX_SQRT_RATIO - 1);
        vm.stopPrank();
        _assertNoFees();
    }

    function test_ZeroFeeExactOutputBothDirections() public {
        vm.startPrank(users.alice);
        uint256 before1 = token1.balanceOf(users.alice);
        clCallee.swap0ForExact1(address(pool), 1e12, users.alice, TickMath.MIN_SQRT_RATIO + 1);
        assertEq(token1.balanceOf(users.alice) - before1, 1e12);
        uint256 before0 = token0.balanceOf(users.alice);
        clCallee.swap1ForExact0(address(pool), 1e12, users.alice, TickMath.MAX_SQRT_RATIO - 1);
        assertEq(token0.balanceOf(users.alice) - before0, 1e12);
        vm.stopPrank();
        _assertNoFees();
    }

    function test_ZeroFeeFlashRepaysPrincipalOnly() public {
        uint256 before0 = token0.balanceOf(address(pool));
        uint256 before1 = token1.balanceOf(address(pool));
        vm.prank(users.alice);
        clCallee.flash(address(pool), users.alice, 1e12, 2e12, 1e12, 2e12);
        assertEq(token0.balanceOf(address(pool)), before0);
        assertEq(token1.balanceOf(address(pool)), before1);
        _assertNoFees();
    }

    function test_ZeroFeeFlashStillRequiresFullRepayment() public {
        vm.startPrank(users.alice);
        vm.expectRevert(bytes("F0"));
        clCallee.flash(address(pool), users.alice, 100, 0, 99, 0);
        vm.expectRevert(bytes("F1"));
        clCallee.flash(address(pool), users.alice, 0, 100, 0, 99);
        vm.stopPrank();
    }

    function test_SetFeeAppliesToExistingPoolSwapAndFlash() public {
        PrivateSwapFeeModule module = PrivateSwapFeeModule(privateFactory.swapFeeModule());
        vm.prank(users.owner);
        module.setCustomFee(address(pool), 3000);
        assertEq(uint256(pool.fee()), 3000);
        vm.startPrank(users.alice);
        clCallee.swapExact0For1(address(pool), 1e12, users.alice, TickMath.MIN_SQRT_RATIO + 1);
        assertGt(pool.feeGrowthGlobal0X128(), 0);
        vm.expectRevert(bytes("F0"));
        clCallee.flash(address(pool), users.alice, 1000, 0, 1000, 0);
        clCallee.flash(address(pool), users.alice, 1000, 1000, 1003, 1003);
        vm.stopPrank();
        assertGt(pool.feeGrowthGlobal1X128(), 0);
    }

    function test_ImmediateCallerPolicyDoesNotCheckRecipientOrOrigin() public {
        assertFalse(privateFactory.isWhitelisted(users.alice));
        assertFalse(privateFactory.isWhitelisted(users.bob));
        uint256 before1 = token1.balanceOf(users.bob);
        vm.prank(users.alice);
        clCallee.swapExact0For1(address(pool), 1e12, users.bob, TickMath.MIN_SQRT_RATIO + 1);
        assertGt(token1.balanceOf(users.bob), before1);
    }

    function test_UnrestrictedObservationGrowth() public {
        vm.prank(users.bob);
        pool.increaseObservationCardinalityNext(8);
        (,,,, uint16 cardinalityNext,) = pool.slot0();
        assertEq(uint256(cardinalityNext), 8);
    }

    function testFuzz_ZeroFeeSwapConservesTokens(uint96 rawAmount, bool zeroForOne, bool exactInput) public {
        uint256 amount = bound(uint256(rawAmount), 1000, 1e15);
        ERC20 input = zeroForOne ? token0 : token1;
        ERC20 output = zeroForOne ? token1 : token0;
        uint256 beforeUserInput = input.balanceOf(users.alice);
        uint256 beforeUserOutput = output.balanceOf(users.alice);
        uint256 beforePoolInput = input.balanceOf(address(pool));
        uint256 beforePoolOutput = output.balanceOf(address(pool));
        vm.startPrank(users.alice);
        if (zeroForOne) {
            if (exactInput) clCallee.swapExact0For1(address(pool), amount, users.alice, TickMath.MIN_SQRT_RATIO + 1);
            else clCallee.swap0ForExact1(address(pool), amount, users.alice, TickMath.MIN_SQRT_RATIO + 1);
        } else {
            if (exactInput) clCallee.swapExact1For0(address(pool), amount, users.alice, TickMath.MAX_SQRT_RATIO - 1);
            else clCallee.swap1ForExact0(address(pool), amount, users.alice, TickMath.MAX_SQRT_RATIO - 1);
        }
        vm.stopPrank();
        uint256 paid = beforeUserInput - input.balanceOf(users.alice);
        uint256 received = output.balanceOf(users.alice) - beforeUserOutput;
        assertEq(input.balanceOf(address(pool)) - beforePoolInput, paid);
        assertEq(beforePoolOutput - output.balanceOf(address(pool)), received);
        assertEq(exactInput ? paid : received, amount);
        _assertNoFees();
    }
}
