// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/StdStorage.sol";
import { TestBaseStrategyCTokenWithExitFee } from "../TestBaseStrategyCTokenWithExitFee.sol";
import { BasePToken } from "contracts/market/token/BasePToken.sol";
import { PluginDelegable } from "contracts/libraries/PluginDelegable.sol";
import { MockAuraPTokenWithExitFee } from "contracts/mocks/MockAuraPTokenWithExitFee.sol";
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
        new MockAuraPTokenWithExitFee(
            ICentralRegistry(address(0)),
            balRETH,
            address(marketManagerIsolated),
            109,
            _REWARDER,
            _AURA_BOOSTER,
            200
        );
    }

    function test_strategyCTokenWithExitFeeDeployment_fail_whenMarketManagerIsNotSet()
        public
    {
        vm.expectRevert(BasePToken.BasePToken__InvalidMarketManager.selector);
        new MockAuraPTokenWithExitFee(
            ICentralRegistry(address(centralRegistry)),
            balRETH,
            address(1),
            109,
            _REWARDER,
            _AURA_BOOSTER,
            200
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
            BasePToken
                .BasePToken__UnderlyingAssetTotalSupplyExceedsMaximum
                .selector
        );
        new MockAuraPTokenWithExitFee(
            ICentralRegistry(address(centralRegistry)),
            balRETH,
            address(marketManagerIsolated),
            109,
            _REWARDER,
            _AURA_BOOSTER,
            200
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
        new MockAuraPTokenWithExitFee(
            ICentralRegistry(address(centralRegistry)),
            balRETH,
            address(marketManagerIsolated),
            109,
            _REWARDER,
            _AURA_BOOSTER,
            201
        );
    }

    function test_strategyCTokenWithExitFeeDeployment_success() public {
        pBALRETHWithExitFee = new MockAuraPTokenWithExitFee(
            ICentralRegistry(address(centralRegistry)),
            balRETH,
            address(marketManagerIsolated),
            109,
            _REWARDER,
            _AURA_BOOSTER,
            200
        );

        assertEq(
            address(pBALRETHWithExitFee.centralRegistry()),
            address(centralRegistry)
        );
        assertEq(pBALRETHWithExitFee.underlying(), _BAL_WETH_RETH_ADDRESS);
        assertEq(
            address(pBALRETHWithExitFee.marketManager()),
            address(marketManagerIsolated)
        );
        assertEq(
            pBALRETHWithExitFee.name(),
            "Curvance Balancer rETH Stable Pool"
        );
        assertEq(pBALRETHWithExitFee.exitFee(), 0.02e18);
    }
}
