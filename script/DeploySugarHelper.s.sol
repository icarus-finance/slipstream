// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.7.6;

import "forge-std/StdJson.sol";
import "forge-std/Script.sol";

import {SugarHelper} from "contracts/periphery/SugarHelper.sol";

contract DeploySugarHelper is Script {
    using stdJson for string;

    uint256 public deployPrivateKey = vm.envUint("PRIVATE_KEY_DEPLOY");
    address public deployerAddress = vm.rememberKey(deployPrivateKey);
    string public outputFilename = vm.envString("OUTPUT_FILENAME");
    string public jsonOutput;

    // Loaded addresses from DeployCL output (sanity + explicit dependency)
    address public poolFactory;
    address public positionManager;
    address public gaugeFactory;

    SugarHelper public sugarHelper;

    function run() public {
        string memory root = vm.projectRoot();
        string memory path = concat(root, "/script/constants/output/DeployCL-");
        path = concat(path, outputFilename);
        jsonOutput = vm.readFile(path);

        poolFactory = abi.decode(vm.parseJson(jsonOutput, ".PoolFactory"), (address));
        positionManager = abi.decode(vm.parseJson(jsonOutput, ".NonfungiblePositionManager"), (address));
        gaugeFactory = abi.decode(vm.parseJson(jsonOutput, ".GaugeFactory"), (address));

        require(poolFactory != address(0));
        require(positionManager != address(0));
        require(gaugeFactory != address(0));

        vm.startBroadcast(deployerAddress);
        sugarHelper = new SugarHelper();
        vm.stopBroadcast();

        vm.writeJson(vm.serializeAddress("", "SugarHelper", address(sugarHelper)), path);
    }

    function concat(string memory a, string memory b) internal pure returns (string memory) {
        return string(abi.encodePacked(a, b));
    }
}
