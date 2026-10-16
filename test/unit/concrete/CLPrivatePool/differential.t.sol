// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import "../../../BaseFixture.sol";
import {PrivateSwapFeeModule} from "contracts/core/fees/PrivateSwapFeeModule.sol";
import {CLPrivateFactory} from "contracts/core/CLPrivateFactory.sol";
import {CLPrivatePool} from "contracts/core/CLPrivatePool.sol";
import {TickMath} from "contracts/core/libraries/TickMath.sol";

contract DifferentialFeeModule {
    uint24 internal fee;

    constructor(uint24 value) {
        fee = value;
    }

    function getFee(address) external view returns (uint24) {
        return fee;
    }
}

/// @dev Compare the fork against the unchanged public AMM using identical operations and fee settings.
contract PrivatePoolDifferentialTest is BaseFixture {
    CLPrivateFactory internal privateFactory;
    CLPool internal original;
    CLPrivatePool internal restricted;

    function setUp() public override {
        super.setUp();
        vm.startPrank(users.owner);
        privateFactory = new CLPrivateFactory(
            address(voter), address(new CLPrivatePool()), address(gaugeFactory), address(gaugeImplementation)
        );
        privateFactory.setWhitelist(users.owner, true);
        privateFactory.setWhitelist(address(clCallee), true);
        original = CLPool(poolFactory.createPool(address(token0), address(token1), int24(100), encodePriceSqrt(1, 1)));
        restricted = CLPrivatePool(
            privateFactory.createPool(address(token0), address(token1), int24(100), encodePriceSqrt(1, 1))
        );
        vm.stopPrank();
        deal(address(token0), users.alice, 1e30);
        deal(address(token1), users.alice, 1e30);
    }

    function _configure(uint24 fee, uint128 liquidity) internal {
        if (fee == 420) fee = 0; // Custom module zero-fee sentinel.
        DifferentialFeeModule module = new DifferentialFeeModule(fee);
        vm.prank(users.feeManager);
        poolFactory.setSwapFeeModule(address(module));
        PrivateSwapFeeModule privateModule = PrivateSwapFeeModule(privateFactory.swapFeeModule());
        vm.prank(users.owner);
        privateModule.setCustomFee(address(restricted), fee);
        vm.startPrank(users.alice);
        _mintBoth(-2000, -1000, liquidity);
        _mintBoth(-1000, 1000, liquidity);
        _mintBoth(1000, 2000, liquidity);
        vm.stopPrank();
        _assertSame();
    }

    function _mintBoth(int24 lower, int24 upper, uint128 liquidity) internal {
        clCallee.mint(address(original), users.alice, lower, upper, liquidity);
        clCallee.mint(address(restricted), users.alice, lower, upper, liquidity);
    }

    function _assertSame() internal {
        (bool okA, bytes memory a) = address(original).staticcall(abi.encodeWithSignature("slot0()"));
        (bool okB, bytes memory b) = address(restricted).staticcall(abi.encodeWithSignature("slot0()"));
        assertTrue(okA && okB);
        assertEq(keccak256(a), keccak256(b));
        assertEq(uint256(original.liquidity()), uint256(restricted.liquidity()));
        assertEq(original.feeGrowthGlobal0X128(), restricted.feeGrowthGlobal0X128());
        assertEq(original.feeGrowthGlobal1X128(), restricted.feeGrowthGlobal1X128());
        assertEq(token0.balanceOf(address(original)), token0.balanceOf(address(restricted)));
        assertEq(token1.balanceOf(address(original)), token1.balanceOf(address(restricted)));
        (uint128 a0, uint128 a1) = original.gaugeFees();
        (uint128 b0, uint128 b1) = restricted.gaugeFees();
        assertEq(uint256(a0), uint256(b0));
        assertEq(uint256(a1), uint256(b1));
    }

    function _swapBoth(uint256 amount, bool zeroForOne, bool exactOutput) internal {
        vm.startPrank(users.alice);
        if (zeroForOne && exactOutput) {
            clCallee.swap0ForExact1(address(original), amount, users.alice, TickMath.getSqrtRatioAtTick(-1900));
            clCallee.swap0ForExact1(address(restricted), amount, users.alice, TickMath.getSqrtRatioAtTick(-1900));
        } else if (zeroForOne) {
            clCallee.swapExact0For1(address(original), amount, users.alice, TickMath.getSqrtRatioAtTick(-1900));
            clCallee.swapExact0For1(address(restricted), amount, users.alice, TickMath.getSqrtRatioAtTick(-1900));
        } else if (exactOutput) {
            clCallee.swap1ForExact0(address(original), amount, users.alice, TickMath.getSqrtRatioAtTick(1900));
            clCallee.swap1ForExact0(address(restricted), amount, users.alice, TickMath.getSqrtRatioAtTick(1900));
        } else {
            clCallee.swapExact1For0(address(original), amount, users.alice, TickMath.getSqrtRatioAtTick(1900));
            clCallee.swapExact1For0(address(restricted), amount, users.alice, TickMath.getSqrtRatioAtTick(1900));
        }
        vm.stopPrank();
        _assertSame();
    }

    function testFuzz_SwapMathMatchesOriginal(
        uint24 fee,
        uint128 liquidity,
        uint96 amount,
        bool direction,
        bool exactOutput
    ) public {
        fee = uint24(bound(uint256(fee), 0, 30000));
        liquidity = uint128(bound(uint256(liquidity), 1e16, 1e22));
        amount = uint96(bound(uint256(amount), 1, uint256(liquidity) / 5));
        _configure(fee, liquidity);
        _swapBoth(amount, direction, exactOutput);
        skip(5);
        _swapBoth(amount / 2 + 1, !direction, !exactOutput);
    }

    function test_ZeroFeeCrossesInitializedTicksBothDirections() public {
        _configure(0, 1e18);
        _swapBoth(1e18, false, false);
        (, int24 tick,,,,) = restricted.slot0();
        assertGt(int256(tick), 1000);
        _swapBoth(1e18, true, false);
        (, tick,,,,) = restricted.slot0();
        assertLt(int256(tick), -1000);
        assertEq(restricted.feeGrowthGlobal0X128(), 0);
        assertEq(restricted.feeGrowthGlobal1X128(), 0);
    }

    function testFuzz_BurnCollectMatchesOriginalAfterSwap(uint24 fee, uint128 amount) public {
        _configure(uint24(bound(uint256(fee), 0, 30000)), 1e18);
        _swapBoth(1e16, true, false);
        amount = uint128(bound(uint256(amount), 1, 1e18));
        vm.startPrank(users.alice);
        (uint256 a0, uint256 a1) = original.burn(-1000, 1000, amount);
        (uint256 b0, uint256 b1) = restricted.burn(-1000, 1000, amount);
        assertEq(a0, b0);
        assertEq(a1, b1);
        original.collect(users.alice, -1000, 1000, type(uint128).max, type(uint128).max);
        restricted.collect(users.alice, -1000, 1000, type(uint128).max, type(uint128).max);
        vm.stopPrank();
        _assertSame();
    }
}
