// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.7.6;

import "forge-std/StdJson.sol";
import "forge-std/Script.sol";

import {SafeCast} from "contracts/core/libraries/SafeCast.sol";
import {CLPool} from "contracts/core/CLPool.sol";
import {CLFactory} from "contracts/core/CLFactory.sol";
import {NonfungibleTokenPositionDescriptor} from "contracts/periphery/NonfungibleTokenPositionDescriptor.sol";
import {NonfungiblePositionManager} from "contracts/periphery/NonfungiblePositionManager.sol";
import {CLGauge} from "contracts/gauge/CLGauge.sol";
import {CLGaugeFactory} from "contracts/gauge/CLGaugeFactory.sol";
import {CustomSwapFeeModule} from "contracts/core/fees/CustomSwapFeeModule.sol";
import {CustomUnstakedFeeModule} from "contracts/core/fees/CustomUnstakedFeeModule.sol";
import {MixedRouteQuoterV1} from "contracts/periphery/lens/MixedRouteQuoterV1.sol";
import {QuoterV2} from "contracts/periphery/lens/QuoterV2.sol";

contract DeployTestPool is Script {
    using stdJson for string;

    uint256 public deployPrivateKey = vm.envUint("PRIVATE_KEY_DEPLOY");
    address public deployerAddress = vm.rememberKey(deployPrivateKey);
    // string public constantsFilename = vm.envString("CONSTANTS_FILENAME");
    // string public outputFilename = vm.envString("OUTPUT_FILENAME");
    // string public jsonConstants;

    // // loaded variables
    // address public team;
    // address public weth;
    // address public voter;
    // // address public factoryRegistry;
    // address public poolFactoryOwner;
    // address public feeManager;
    // address public factoryV2;

    // // deployed contracts
    // CLPool public poolImplementation;
    // CLFactory public poolFactory;
    // NonfungibleTokenPositionDescriptor public nftDescriptor;
    // NonfungiblePositionManager public nft;
    // CLGauge public gaugeImplementation;
    // CLGaugeFactory public gaugeFactory;
    // CustomSwapFeeModule public swapFeeModule;
    // CustomUnstakedFeeModule public unstakedFeeModule;
    // MixedRouteQuoterV1 public mixedQuoter;
    // QuoterV2 public quoter;

    function encodePriceSqrt(uint256 reserve1, uint256 reserve0) public pure returns (uint160) {
        reserve1 = reserve1 * 2 ** 192;
        uint256 division = reserve1 / reserve0;
        uint256 sqrtX96 = sqrt(division);

        return SafeCast.toUint160(sqrtX96);
    }

    function getScaledExecutionPrice(int256 poolBalance1Delta, int256 poolBalance0Delta) public pure returns (int256) {
        return (poolBalance1Delta * 10 ** 39) / poolBalance0Delta * -1;
    }

    // @dev converts positive numbers to string
    function stringToUint(string memory s) public pure returns (uint256) {
        bytes memory b = bytes(s);
        uint256 result = 0;
        for (uint256 i = 0; i < b.length; i++) {
            uint256 c = uint256(uint8(b[i]));
            if (c >= 48 && c <= 57) {
                result = result * 10 + (c - 48);
            }
        }
        return result;
    }

    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    function run() public {
        address IRS = 0xD4719D14C9aD0661e8D7a347d68dE74ECE4426e9;
        address WETH = 0x4200000000000000000000000000000000000006;
        CLFactory poolFactory = CLFactory(0x5591e3f890725F0f3dbF47B63c81bbb91975483c);

        vm.startBroadcast(deployerAddress);

        CLPool pool = CLPool(
            poolFactory.createPool({tokenA: IRS, tokenB: WETH, tickSpacing: 50, sqrtPriceX96: encodePriceSqrt(1, 1)})
        );
        vm.stopBroadcast();
    }

    function concat(string memory a, string memory b) internal pure returns (string memory) {
        return string(abi.encodePacked(a, b));
    }
}
