pragma solidity =0.7.6;
pragma abicoder v2;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CLPool} from "contracts/core/CLPool.sol";
import {CLPrivatePool} from "contracts/core/CLPrivatePool.sol";

// Harnesses seed accrued fees only; collection executes the production implementation.
contract PublicFeePoolHarness is CLPool {
    constructor(address first, address second) {
        token0 = first;
        token1 = second;
        gauge = msg.sender;
        slot0.unlocked = true;
    }

    function seed(uint128 first, uint128 second) external {
        gaugeFees = GaugeFees(first, second);
    }
}

contract PrivateFeePoolHarness is CLPrivatePool {
    constructor(address first, address second) {
        token0 = first;
        token1 = second;
        gauge = msg.sender;
        slot0.unlocked = true;
    }

    function seed(uint128 first, uint128 second) external {
        gaugeFees = GaugeFees(first, second);
    }
}

interface FeePoolHarness {
    function seed(uint128 first, uint128 second) external;
    function collectFees() external returns (uint128, uint128);
    function gaugeFees() external view returns (uint128, uint128);
}

abstract contract CollectFeesSentinelTestBase is Test {
    ERC20 internal first;
    ERC20 internal second;
    FeePoolHarness internal pool;

    event CollectFees(address indexed recipient, uint128 amount0, uint128 amount1);

    function _deploy() internal virtual returns (FeePoolHarness);

    function setUp() public {
        first = new ERC20("First", "F");
        second = new ERC20("Second", "S");
        pool = _deploy();
    }

    function _check(uint128 accrued0, uint128 accrued1) internal {
        pool.seed(accrued0, accrued1);
        deal(address(first), address(pool), accrued0);
        deal(address(second), address(pool), accrued1);
        uint128 expected0 = accrued0 > 1 ? accrued0 - 1 : 0;
        uint128 expected1 = accrued1 > 1 ? accrued1 - 1 : 0;
        uint256 before0 = first.balanceOf(address(this));
        uint256 before1 = second.balanceOf(address(this));
        vm.expectEmit(true, false, false, true, address(pool));
        emit CollectFees(address(this), expected0, expected1);
        (uint128 actual0, uint128 actual1) = pool.collectFees();
        assertEq(uint256(actual0), expected0);
        assertEq(uint256(actual1), expected1);
        assertEq(first.balanceOf(address(this)) - before0, actual0);
        assertEq(second.balanceOf(address(this)) - before1, actual1);
        (uint128 remaining0, uint128 remaining1) = pool.gaugeFees();
        assertEq(uint256(remaining0), accrued0 == 0 ? 0 : 1);
        assertEq(uint256(remaining1), accrued1 == 0 ? 0 : 1);
        assertEq(first.balanceOf(address(pool)), remaining0);
        assertEq(second.balanceOf(address(pool)), remaining1);

        // Repeated idle calls must neither report nor transfer the retained units.
        for (uint256 i; i < 3; i++) {
            (actual0, actual1) = pool.collectFees();
            assertEq(uint256(actual0), 0);
            assertEq(uint256(actual1), 0);
        }
        assertEq(first.balanceOf(address(this)) - before0, expected0);
        assertEq(second.balanceOf(address(this)) - before1, expected1);
    }

    function test_Empty() public {
        _check(0, 0);
    }

    function test_SentinelsOnly() public {
        _check(1, 1);
    }

    function test_SentinelAndFreshFees() public {
        _check(1, 1000000);
    }

    function test_FreshFeesAndSentinel() public {
        _check(1000000, 1);
    }

    function test_MinimumSweep() public {
        _check(2, 2);
    }

    function testFuzz_ReturnsActualTransfers(uint128 accrued0, uint128 accrued1) public {
        _check(accrued0, accrued1);
    }
}

contract PublicCollectFeesSentinelTest is CollectFeesSentinelTestBase {
    function _deploy() internal override returns (FeePoolHarness) {
        return FeePoolHarness(address(new PublicFeePoolHarness(address(first), address(second))));
    }
}

contract PrivateCollectFeesSentinelTest is CollectFeesSentinelTestBase {
    function _deploy() internal override returns (FeePoolHarness) {
        return FeePoolHarness(address(new PrivateFeePoolHarness(address(first), address(second))));
    }
}
