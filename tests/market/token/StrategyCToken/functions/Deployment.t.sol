// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { PendleLPCToken } from "contracts/market/token/PendleLPCToken.sol";
import { BaseCTokenWithYield } from "contracts/market/token/BaseCTokenWithYield.sol";
import { IPendleRouter } from "contracts/interfaces/external/pendle/IPendleRouter.sol";
import { CentralRegistryLib } from "contracts/libraries/CentralRegistryLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

import { TestBaseStrategyCToken } from "../TestBaseStrategyCToken.sol";
import "forge-std/StdStorage.sol";

contract StrategyCTokenDeploymentTest is TestBaseStrategyCToken {
    using stdStorage for StdStorage;

    address internal _PENDLE_ROUTER = 0x888888888889758F76e7103c6CbF23ABbF58F946;

    event NewMarketManager(address oldMarketManager, address newMarketManager);

    function test_strategyCTokenDeployment_fail_whenCentralRegistryIsInvalid()
        public
    {
        vm.expectRevert(
            CentralRegistryLib.CentralRegistryLib__InvalidCentralRegistry
                .selector
        );
        
         new PendleLPCToken(
            ICentralRegistry(address(0)),
            IERC20(LP_wstETH_24Dec2025),
            address(marketManagerIsolated),
            IPendleRouter(_PENDLE_ROUTER),
            1 days
        );
    }

    function test_strategyCTokenDeployment_fail_whenMarketManagerIsNotSet()
        public
    {
        vm.expectRevert(BaseCToken.BaseCToken__InvalidMarketManager.selector);
         new PendleLPCToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(LP_wstETH_24Dec2025),
            address(1),
            IPendleRouter(_PENDLE_ROUTER),
            1 days
        );
    }

    function test_strategyCTokenDeployment_fail_vestingPeriodIs0() public {
        vm.expectRevert(
            BaseCTokenWithYield
                .BaseCTokenWithYield__InvalidVestingPeriod
                .selector
        );

         new PendleLPCToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(LP_wstETH_24Dec2025),
            address(marketManagerIsolated),
            IPendleRouter(_PENDLE_ROUTER),
            0
        );
    }

    function test_strategyCTokenDeployment_fail_vestingPeriodIsAboveMaximumVestingPeriod() public {
        // Pulled from internal constant inside `BaseCTokenWithYield`.
        uint256 MAXIMUM_VESTING_PERIOD = 3 days;

        vm.expectRevert(
            BaseCTokenWithYield
                .BaseCTokenWithYield__InvalidVestingPeriod
                .selector
        );

         new PendleLPCToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(LP_wstETH_24Dec2025),
            address(marketManagerIsolated),
            IPendleRouter(_PENDLE_ROUTER),
            MAXIMUM_VESTING_PERIOD + 1
        );
    }

    function test_strategyCTokenDeployment_success() public {
         new PendleLPCToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(LP_wstETH_24Dec2025),
            address(marketManagerIsolated),
            IPendleRouter(_PENDLE_ROUTER),
            1 days
        );

        assertEq(
            address(pendleStrategyCTokenSTETH.centralRegistry()),
            address(centralRegistry)
        );
        assertEq(pendleStrategyCTokenSTETH.asset(), address(LP_wstETH_24Dec2025));
        assertEq(address(pendleStrategyCTokenSTETH.marketManager()), address(marketManagerIsolated));
        assertEq(pendleStrategyCTokenSTETH.name(), "Curvance Pendle Market");
    }
}
