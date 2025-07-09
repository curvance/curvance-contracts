// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/StdStorage.sol";
import { TestBaseStrategyCTokenWithExitFee } from "../TestBaseStrategyCTokenWithExitFee.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { PluginDelegable } from "contracts/libraries/PluginDelegable.sol";
import { MockAuraCTokenWithExitFee } from "contracts/mocks/MockAuraCTokenWithExitFee.sol";
import { StrategyCTokenWithExitFee } from "contracts/market/token/StrategyCTokenWithExitFee.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

contract StrategyCTokenWithExitFeeDeploymentTest is
    TestBaseStrategyCTokenWithExitFee
{
    using stdStorage for StdStorage;

    event NewMarketManager(address oldMarketManager, address newMarketManager);

    function test_strategyCTokenWithExitFeeDeployment_fail_whenCentralRegistryIsInvalid()
        public
    {
        vm.expectRevert(
            PluginDelegable.PluginDelegable__InvalidCentralRegistry.selector
        );
        new MockAuraCTokenWithExitFee(
            ICentralRegistry(address(0)),
            balRETH,
            address(marketManagerIsolated),
            109,
            _REWARDER,
            _AURA_BOOSTER,
            200,
            1 days
        );
    }

    function test_strategyCTokenWithExitFeeDeployment_fail_whenMarketManagerIsNotSet()
        public
    {
        vm.expectRevert(BaseCToken.BaseCToken__InvalidMarketManager.selector);
        new MockAuraCTokenWithExitFee(
            ICentralRegistry(address(centralRegistry)),
            balRETH,
            address(1),
            109,
            _REWARDER,
            _AURA_BOOSTER,
            200,
            1 days
        );
    }

    function test_strategyCTokenWithExitFeeDeployment_fail_whenUnderlyingTotalSupplyExceedsMaximum()
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
        new MockAuraCTokenWithExitFee(
            ICentralRegistry(address(centralRegistry)),
            balRETH,
            address(marketManagerIsolated),
            109,
            _REWARDER,
            _AURA_BOOSTER,
            200,
            1 days
        );
    }

    function test_strategyCTokenWithExitFeeDeployment_fail_whenExitFeeExceedsMaximum()
        public
    {
        vm.expectRevert(
            StrategyCTokenWithExitFee
                .StrategyCTokenWithExitFee__InvalidExitFee
                .selector
        );
        new MockAuraCTokenWithExitFee(
            ICentralRegistry(address(centralRegistry)),
            balRETH,
            address(marketManagerIsolated),
            109,
            _REWARDER,
            _AURA_BOOSTER,
            201,
            1 days
        );
    }

    function test_strategyCTokenWithExitFeeDeployment_success() public {
        strategyCBALRETHWithExitFee = new MockAuraCTokenWithExitFee(
            ICentralRegistry(address(centralRegistry)),
            balRETH,
            address(marketManagerIsolated),
            109,
            _REWARDER,
            _AURA_BOOSTER,
            200,
            1 days
        );

        assertEq(
            address(strategyCBALRETHWithExitFee.centralRegistry()),
            address(centralRegistry)
        );
        assertEq(strategyCBALRETHWithExitFee.asset(), _BAL_WETH_RETH_ADDRESS);
        assertEq(
            address(strategyCBALRETHWithExitFee.marketManager()),
            address(marketManagerIsolated)
        );
        assertEq(
            strategyCBALRETHWithExitFee.name(),
            "Curvance Balancer rETH Stable Pool"
        );
        assertEq(strategyCBALRETHWithExitFee.exitFee(), 0.02e18);
    }
}
