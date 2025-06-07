// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/StdStorage.sol";
import { TestBaseCompoundingPToken } from "../TestBaseCompoundingPToken.sol";
import { BasePToken } from "contracts/market/token/BasePToken.sol";
import { PluginDelegable } from "contracts/libraries/PluginDelegable.sol";
import { AuraPToken } from "contracts/market/token/AuraPToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

contract CompoundingPTokenDeploymentTest is TestBaseCompoundingPToken {
    using stdStorage for StdStorage;

    event NewMarketManager(address oldMarketManager, address newMarketManager);

    function test_compoundingPTokenDeployment_fail_whenCentralRegistryIsInvalid()
        public
    {
        vm.expectRevert(
            PluginDelegable.PluginDelegable__InvalidCentralRegistry.selector
        );
        new AuraPToken(
            ICentralRegistry(address(0)),
            balRETH,
            address(marketManagerIsolated),
            109,
            _REWARDER,
            _AURA_BOOSTER
        );
    }

    function test_compoundingPTokenDeployment_fail_whenMarketManagerIsNotSet()
        public
    {
        vm.expectRevert(BasePToken.BasePToken__InvalidMarketManager.selector);
        new AuraPToken(
            ICentralRegistry(address(centralRegistry)),
            balRETH,
            address(1),
            109,
            _REWARDER,
            _AURA_BOOSTER
        );
    }

    function test_compoundingPTokenDeployment_fail_whenUnderlyingTotalSupplyExceedsMaximum()
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
        new AuraPToken(
            ICentralRegistry(address(centralRegistry)),
            balRETH,
            address(marketManagerIsolated),
            109,
            _REWARDER,
            _AURA_BOOSTER
        );
    }

    function test_compoundingPTokenDeployment_success() public {
        pBALRETH = new AuraPToken(
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
