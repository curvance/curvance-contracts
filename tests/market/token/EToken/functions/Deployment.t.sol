// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/StdStorage.sol";
import { TestBaseEToken } from "../TestBaseEToken.sol";
import { DynamicInterestRateModel } from "contracts/market/DynamicInterestRateModel.sol";
import { EToken } from "contracts/market/token/EToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { PluginDelegable } from "contracts/libraries/PluginDelegable.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

contract ETokenDeploymentTest is TestBaseEToken {
    using stdStorage for StdStorage;

    event NewInterestFactor(
        uint256 oldInterestFactor,
        uint256 newInterestFactor
    );

    DynamicInterestRateModel public interestRateModel;

    function setUp() public virtual override {
        super.setUp();
        interestRateModel = interestRateModels[block.chainid][_USDC_ADDRESS];
    }

    function test_eTokenDeployment_fail_whenCentralRegistryIsInvalid() public {
        vm.expectRevert(
            PluginDelegable.PluginDelegable__InvalidCentralRegistry.selector
        );
        new EToken(
            ICentralRegistry(address(0)),
            _USDC_ADDRESS,
            address(marketManager),
            address(interestRateModel)
        );
    }

    function test_eTokenDeployment_fail_whenMarketManagerIsNotSet() public {
        vm.expectRevert(
            EToken.EToken__MarketManagerIsNotLendingMarket.selector
        );
        new EToken(
            ICentralRegistry(address(centralRegistry)),
            _USDC_ADDRESS,
            address(1),
            address(interestRateModel)
        );
    }

    function test_eTokenDeployment_fail_whenInterestRateModelIsInvalid()
        public
    {
        vm.expectRevert();
        new EToken(
            ICentralRegistry(address(centralRegistry)),
            _USDC_ADDRESS,
            address(marketManager),
            address(0)
        );
    }

    function test_eTokenDeployment_fail_whenUnderlyingTotalSupplyExceedsMaximum()
        public
    {
        stdstore
            .target(_USDC_ADDRESS)
            .sig(IERC20.totalSupply.selector)
            .checked_write(type(uint232).max);


        vm.expectRevert(
           EToken.EToken__ValidationFailed.selector
        );
        new EToken(
            ICentralRegistry(address(centralRegistry)),
            _USDC_ADDRESS,
            address(marketManager),
            address(interestRateModel)
        );
    }

    function test_eTokenDeployment_success() public {
        vm.expectEmit(true, true, true, true);
        uint256 newInterestFactor = centralRegistry.protocolInterestFactor(
            address(marketManager)
        );
        emit NewInterestFactor(0, newInterestFactor);

        eUSDC = new EToken(
            ICentralRegistry(address(centralRegistry)),
            _USDC_ADDRESS,
            address(marketManager),
            address(interestRateModel)
        );

        assertEq(address(eUSDC.centralRegistry()), address(centralRegistry));
        assertEq(eUSDC.underlying(), _USDC_ADDRESS);
        assertEq(
            address(eUSDC.interestRateModel()),
            address(interestRateModel)
        );
        assertEq(address(eUSDC.marketManager()), address(marketManager));
    }
}
