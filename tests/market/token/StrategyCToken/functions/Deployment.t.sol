// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { AuraCToken } from "contracts/market/token/AuraCToken.sol";
import { BaseCTokenWithYield } from "contracts/market/token/BaseCTokenWithYield.sol";

import { CentralRegistryLib } from "contracts/libraries/CentralRegistryLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

import { TestBaseStrategyCToken } from "../TestBaseStrategyCToken.sol";
import "forge-std/StdStorage.sol";

contract StrategyCTokenDeploymentTest is TestBaseStrategyCToken {
    using stdStorage for StdStorage;

    event NewMarketManager(address oldMarketManager, address newMarketManager);

    function test_strategyCTokenDeployment_fail_whenCentralRegistryIsInvalid()
        public
    {
        vm.expectRevert(
            CentralRegistryLib.CentralRegistryLib__InvalidCentralRegistry
                .selector
        );
        new AuraCToken(
            ICentralRegistry(address(0)),
            balRETH,
            address(marketManagerIsolated),
            109,
            _REWARDER,
            _AURA_BOOSTER,
            1 days
        );
    }

    function test_strategyCTokenDeployment_fail_whenMarketManagerIsNotSet()
        public
    {
        vm.expectRevert(BaseCToken.BaseCToken__InvalidMarketManager.selector);
        new AuraCToken(
            ICentralRegistry(address(centralRegistry)),
            balRETH,
            address(1),
            109,
            _REWARDER,
            _AURA_BOOSTER,
            1 days
        );
    }

    function test_strategyCTokenDeployment_fail_whenUnderlyingTotalSupplyExceedsMaximum()
        public
    {
        stdstore
            .target(_BAL_WETH_RETH_ADDRESS)
            .sig(IERC20.totalSupply.selector)
            .checked_write(type(uint232).max);

        vm.expectRevert(
            BaseCToken
                .BaseCToken__UnsupportedAsset
                .selector
        );
        new AuraCToken(
            ICentralRegistry(address(centralRegistry)),
            balRETH,
            address(marketManagerIsolated),
            109,
            _REWARDER,
            _AURA_BOOSTER,
            1 days
        );
    }

    function test_strategyCTokenDeployment_fail_vestingPeriodIs0() public {
        vm.expectRevert(
            BaseCTokenWithYield
                .BaseCTokenWithYield__InvalidVestingPeriod
                .selector
        );

        new AuraCToken(
            ICentralRegistry(address(centralRegistry)),
            balRETH,
            address(marketManagerIsolated),
            109,
            _REWARDER,
            _AURA_BOOSTER,
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

        new AuraCToken(
            ICentralRegistry(address(centralRegistry)),
            balRETH,
            address(marketManagerIsolated),
            109,
            _REWARDER,
            _AURA_BOOSTER,
            MAXIMUM_VESTING_PERIOD + 1
        );
    }

    function test_strategyCTokenDeployment_success() public {
        strategyCBALRETH = new AuraCToken(
            ICentralRegistry(address(centralRegistry)),
            balRETH,
            address(marketManagerIsolated),
            109,
            _REWARDER,
            _AURA_BOOSTER,
            1 days
        );

        assertEq(
            address(strategyCBALRETH.centralRegistry()),
            address(centralRegistry)
        );
        assertEq(strategyCBALRETH.asset(), _BAL_WETH_RETH_ADDRESS);
        assertEq(address(strategyCBALRETH.marketManager()), address(marketManagerIsolated));
        assertEq(strategyCBALRETH.name(), "Curvance Balancer rETH Stable Pool");
    }
}
