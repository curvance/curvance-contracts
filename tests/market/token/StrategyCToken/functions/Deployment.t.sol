// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/StdStorage.sol";
import { TestBaseStrategyCToken } from "../TestBaseStrategyCToken.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { PluginDelegable } from "contracts/libraries/PluginDelegable.sol";
import { AuraCToken } from "contracts/market/token/AuraCToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

contract StrategyCTokenDeploymentTest is TestBaseStrategyCToken {
    using stdStorage for StdStorage;

    event NewMarketManager(address oldMarketManager, address newMarketManager);

    function test_strategyCTokenDeployment_fail_whenCentralRegistryIsInvalid()
        public
    {
        vm.expectRevert(
            PluginDelegable.PluginDelegable__InvalidCentralRegistry.selector
        );
        new AuraCToken(
            ICentralRegistry(address(0)),
            balRETH,
            address(marketManagerIsolated),
            109,
            _REWARDER,
            _AURA_BOOSTER
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
            _AURA_BOOSTER
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
                .BaseCToken__UnderlyingAssetTotalSupplyExceedsMaximum
                .selector
        );
        new AuraCToken(
            ICentralRegistry(address(centralRegistry)),
            balRETH,
            address(marketManagerIsolated),
            109,
            _REWARDER,
            _AURA_BOOSTER
        );
    }

    function test_strategyCTokenDeployment_success() public {
        pBALRETH = new AuraCToken(
            ICentralRegistry(address(centralRegistry)),
            balRETH,
            address(marketManagerIsolated),
            109,
            _REWARDER,
            _AURA_BOOSTER
        );

        assertEq(
            address(pBALRETH.centralRegistry()),
            address(centralRegistry)
        );
        assertEq(pBALRETH.underlying(), _BAL_WETH_RETH_ADDRESS);
        assertEq(address(pBALRETH.marketManager()), address(marketManagerIsolated));
        assertEq(pBALRETH.name(), "Curvance Balancer rETH Stable Pool");
    }
}
