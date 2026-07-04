// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {Script} from "forge-std/Script.sol";

import {IERC20} from "contracts/interfaces/IERC20.sol";
import {ICToken} from "contracts/interfaces/ICToken.sol";
import {ILendingOptimizer} from "contracts/interfaces/ILendingOptimizer.sol";

contract VerifyLendingOptimizerLaunch is Script {
    error VerifyLendingOptimizerLaunch__InvalidConfig();

    uint256 internal constant WAD = 1e18;

    struct Config {
        address optimizer;
        string expectedName;
        string expectedSymbol;
        address expectedUnderlying;
        address expectedCentralRegistry;
        uint256 expectedFeeBps;
        address[] expectedMarkets;
        uint256[] expectedAllocationCapsWad;
    }

    function run() external view {
        Config memory config = Config({
            optimizer: vm.envAddress("LENDING_OPTIMIZER_ADDRESS"),
            expectedName: vm.envString("LENDING_OPTIMIZER_NAME"),
            expectedSymbol: vm.envString("LENDING_OPTIMIZER_SYMBOL"),
            expectedUnderlying: vm.envAddress("LENDING_OPTIMIZER_UNDERLYING"),
            expectedCentralRegistry: vm.envAddress(
                "LENDING_OPTIMIZER_CENTRAL_REGISTRY"
            ),
            expectedFeeBps: vm.envUint("LENDING_OPTIMIZER_FEE_BPS"),
            expectedMarkets: vm.envAddress("LENDING_OPTIMIZER_MARKETS", ","),
            expectedAllocationCapsWad: vm.envUint(
                "LENDING_OPTIMIZER_ALLOCATION_CAPS_WAD", ","
            )
        });

        _verify(config);
    }

    function verify(Config calldata config) external view {
        _verify(config);
    }

    function _verify(Config memory config) internal view {
        _requireContract(config.optimizer);
        _requireContract(config.expectedUnderlying);
        _requireContract(config.expectedCentralRegistry);

        uint256 numExpectedMarkets = config.expectedMarkets.length;
        if (
            numExpectedMarkets == 0
                || numExpectedMarkets
                    != config.expectedAllocationCapsWad.length
        ) {
            revert VerifyLendingOptimizerLaunch__InvalidConfig();
        }

        ILendingOptimizer optimizer = ILendingOptimizer(config.optimizer);
        if (
            keccak256(bytes(IERC20(config.optimizer).name()))
                    != keccak256(bytes(config.expectedName))
                || keccak256(bytes(IERC20(config.optimizer).symbol()))
                    != keccak256(bytes(config.expectedSymbol))
                || optimizer.asset() != config.expectedUnderlying
                || address(optimizer.centralRegistry())
                    != config.expectedCentralRegistry
                || optimizer.fee() != config.expectedFeeBps
                || optimizer.numApprovedMarkets() != numExpectedMarkets
        ) {
            revert VerifyLendingOptimizerLaunch__InvalidConfig();
        }

        uint256 totalAllocationCaps;
        for (uint256 i; i < numExpectedMarkets; ++i) {
            address expectedMarket = config.expectedMarkets[i];
            _requireContract(expectedMarket);

            if (
                optimizer.approvedCTokensList(i) != expectedMarket
                    || optimizer.allocationCaps(expectedMarket)
                        != config.expectedAllocationCapsWad[i]
                    || ICToken(expectedMarket).asset()
                        != config.expectedUnderlying
            ) {
                revert VerifyLendingOptimizerLaunch__InvalidConfig();
            }

            totalAllocationCaps += config.expectedAllocationCapsWad[i];
        }

        if (totalAllocationCaps < WAD) {
            revert VerifyLendingOptimizerLaunch__InvalidConfig();
        }
    }

    function _requireContract(address target) internal view {
        if (target == address(0) || target.code.length == 0) {
            revert VerifyLendingOptimizerLaunch__InvalidConfig();
        }
    }
}
