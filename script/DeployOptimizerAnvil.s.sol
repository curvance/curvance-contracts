// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { Script, console2 } from "forge-std/Script.sol";

import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { OptimizerReader } from "contracts/views/OptimizerReader.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

contract DeployOptimizerAnvil is Script {
    // Live Monad addresses.
    address constant CENTRAL_REGISTRY = 0x1310f352f1389969Ece6741671c4B919523912fF;
    address constant USDC = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;

    // Live cToken markets for USDC.
    address constant CUSDC_1 = 0x8EE9FC28B8Da872c38A496e9dDB9700bb7261774;
    address constant CUSDC_2 = 0x7C9d4f1695C6282Da5e5509Aa51fC9fb417C6f1d;
    address constant CUSDC_3 = 0x21aDBb60a5fB909e7F1fB48aACC4569615CD97b5;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerKey);

        OptimizerReader reader = new OptimizerReader(
            ICentralRegistry(CENTRAL_REGISTRY),
            new OptimizerReader.CollateralGuardConfig[](0),
            0
        );

        address[] memory cTokens = new address[](3);
        cTokens[0] = CUSDC_1;
        cTokens[1] = CUSDC_2;
        cTokens[2] = CUSDC_3;

        uint256[] memory caps = new uint256[](3);
        caps[0] = 5000; // 50%
        caps[1] = 5000; // 50%
        caps[2] = 5000; // 50%

        LendingOptimizer optimizer = new LendingOptimizer(
            IERC20(USDC),
            ICentralRegistry(CENTRAL_REGISTRY),
            cTokens,
            caps,
            0
        );

        vm.stopBroadcast();

        console2.log("OPTIMIZER_ADDRESS=%s", address(optimizer));
        console2.log("READER_ADDRESS=%s", address(reader));
    }
}
