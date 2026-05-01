// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { ProtocolManager } from "contracts/architecture/ProtocolManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import {
    TestProtocolManagerUpdateTokenConfig
} from "tests/architecture/ProtocolManager/function/UpdateTokenConfig.t.sol";

/// @notice Regression coverage for overlapping ProtocolManager deployment policy.
/// @dev Demonstrates that period-limit accounting is local to each
///      ProtocolManager contract. If governance grants multiple config-authority
///      managers over the same market/token, cumulative same-period changes can
///      exceed the per-manager limit.
contract TestProtocolManagerOverlappingLimits is
    TestProtocolManagerUpdateTokenConfig
{
    function test_updateTokenConfig_overlappingManagersCanStackPeriodLimits() public {
        address[] memory managedAddresses = new address[](3);
        managedAddresses[0] = address(marketManagerIsolated);
        managedAddresses[1] = address(borrowableCUSDC_MONAD);
        managedAddresses[2] = address(borrowableCWMON);

        ProtocolManager.PeriodLimits[] memory limits =
            new ProtocolManager.PeriodLimits[](3);
        limits[0] = _getValidLimits();
        limits[1] = _getValidLimits();
        limits[2] = _getValidLimits();

        ProtocolManager secondManager = new ProtocolManager(
            ICentralRegistry(address(centralRegistry)),
            manager,
            _getDefaultPermsConfig(),
            managedAddresses,
            limits
        );
        centralRegistry.addMarketPermissions(address(secondManager));

        (,,, uint256 startingCollateralCap,) =
            _getCurrentConfig(address(borrowableCWMON));

        MarketManagerIsolated.TokenConfig memory firstConfig =
            _getValidTokenConfig(
                address(borrowableCWMON),
                0,
                0,
                0,
                1_000_000e18,
                0
            );
        vm.prank(manager);
        protocolManager.updateTokenConfig(address(marketManagerIsolated), firstConfig);

        MarketManagerIsolated.TokenConfig memory secondConfig =
            _getValidTokenConfig(
                address(borrowableCWMON),
                0,
                0,
                0,
                1_000_000e18,
                0
            );
        vm.prank(manager);
        secondManager.updateTokenConfig(address(marketManagerIsolated), secondConfig);

        (,,, uint256 finalCollateralCap,) =
            _getCurrentConfig(address(borrowableCWMON));

        assertEq(
            finalCollateralCap,
            startingCollateralCap + 2_000_000e18,
            "two managers each consumed an independent collateral-cap period limit"
        );
    }
}
