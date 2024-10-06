// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/StdStorage.sol";
import { TestBaseCompoundingWithExitFeePToken } from "../TestBaseCompoundingWithExitFeePToken.sol";
import { BasePToken } from "contracts/market/token/BasePToken.sol";
import { Delegable } from "contracts/libraries/Delegable.sol";
import { MockAuraPTokenWithExitFee } from "contracts/mocks/MockAuraPTokenWithExitFee.sol";
import { CompoundingWithExitFeePToken } from "contracts/market/token/CompoundingWithExitFeePToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

contract CompoundingWithExitFeePTokenDeploymentTest is
    TestBaseCompoundingWithExitFeePToken
{
    using stdStorage for StdStorage;

    event NewMarketManager(address oldMarketManager, address newMarketManager);

    function test_CompoundingWithExitFeePTokenDeployment_fail_whenCentralRegistryIsInvalid()
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

    function test_CompoundingWithExitFeePTokenDeployment_fail_whenMarketManagerIsNotSet()
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

    function test_CompoundingWithExitFeePTokenDeployment_fail_whenUnderlyingTotalSupplyExceedsMaximum()
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
            address(marketManager),
            109,
            _REWARDER,
            _AURA_BOOSTER,
            200
        );
    }

    function test_CompoundingWithExitFeePTokenDeployment_fail_whenExitFeeExceedsMaximum()
        public
    {
        vm.expectRevert(
            CompoundingWithExitFeePToken
                .CompoundingWithExitFeePToken__InvalidExitFee
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

    function test_CompoundingWithExitFeePTokenDeployment_success() public {
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
