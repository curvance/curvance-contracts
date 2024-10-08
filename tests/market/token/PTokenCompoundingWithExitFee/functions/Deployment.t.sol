// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/StdStorage.sol";
import { TestBasePTokenCompoundingWithExitFee } from "../TestBasePTokenCompoundingWithExitFee.sol";
import { PTokenBase } from "contracts/market/token/PTokenBase.sol";
import { Delegable } from "contracts/libraries/Delegable.sol";
import { MockAuraPTokenWithExitFee } from "contracts/mocks/MockAuraPTokenWithExitFee.sol";
import { PTokenCompoundingWithExitFee } from "contracts/market/token/PTokenCompoundingWithExitFee.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

contract PTokenCompoundingWithExitFeeDeploymentTest is
    TestBasePTokenCompoundingWithExitFee
{
    using stdStorage for StdStorage;

    event NewMarketManager(address oldMarketManager, address newMarketManager);

    function test_pTokenCompoundingWithExitFeeDeployment_fail_whenCentralRegistryIsInvalid()
        public
    {
        vm.expectRevert(Delegable.Delegable__InvalidCentralRegistry.selector);
        new MockAuraPTokenWithExitFee(
            ICentralRegistry(address(0)),
            balRETH,
            address(marketManager),
            109,
            _REWARDER,
            _AURA_BOOSTER,
            200
        );
    }

    function test_pTokenCompoundingWithExitFeeDeployment_fail_whenMarketManagerIsNotSet()
        public
    {
        vm.expectRevert(PTokenBase.PTokenBase__InvalidMarketManager.selector);
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

    function test_pTokenCompoundingWithExitFeeDeployment_fail_whenUnderlyingTotalSupplyExceedsMaximum()
        public
    {
        stdstore
            .target(_BAL_WETH_RETH_ADDRESS)
            .sig(IERC20.totalSupply.selector)
            .checked_write(type(uint232).max);

        vm.expectRevert(
            PTokenBase
                .PTokenBase__UnderlyingAssetTotalSupplyExceedsMaximum
                .selector
        );
        new MockAuraPTokenWithExitFee(
            ICentralRegistry(address(centralRegistry)),
            balRETH,
            address(marketManager),
            109,
            _REWARDER,
            _AURA_BOOSTER,
            200
        );
    }

    function test_pTokenCompoundingWithExitFeeDeployment_fail_whenExitFeeExceedsMaximum()
        public
    {
        vm.expectRevert(
            PTokenCompoundingWithExitFee
                .PTokenCompoundingWithExitFee__InvalidExitFee
                .selector
        );
        new MockAuraPTokenWithExitFee(
            ICentralRegistry(address(centralRegistry)),
            balRETH,
            address(marketManager),
            109,
            _REWARDER,
            _AURA_BOOSTER,
            201
        );
    }

    function test_pTokenCompoundingWithExitFeeDeployment_success() public {
        pBALRETHWithExitFee = new MockAuraPTokenWithExitFee(
            ICentralRegistry(address(centralRegistry)),
            balRETH,
            address(marketManager),
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
            address(marketManager)
        );
        assertEq(
            pBALRETHWithExitFee.name(),
            "Curvance collateralized Balancer rETH Stable Pool"
        );
        assertEq(pBALRETHWithExitFee.exitFee(), 0.02e18);
    }
}
