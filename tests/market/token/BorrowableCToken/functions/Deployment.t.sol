// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/StdStorage.sol";
import { TestBaseBorrowableCToken } from "../TestBaseBorrowableCToken.sol";
import { DynamicInterestRateModel } from "contracts/market/DynamicInterestRateModel.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { PluginDelegable } from "contracts/libraries/PluginDelegable.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";

contract BorrowableCTokenDeploymentTest is TestBaseBorrowableCToken {
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

    function test_borrowableCTokenDeployment_fail_whenCentralRegistryIsInvalid() public {
        vm.expectRevert(
            PluginDelegable.PluginDelegable__InvalidCentralRegistry.selector
        );
        new BorrowableCToken(
            ICentralRegistry(address(0)),
            IERC20(_USDC_ADDRESS),
            address(marketManagerIsolated),
            address(interestRateModel)
        );
    }

    function test_borrowableCTokenDeployment_fail_whenMarketManagerIsNotSet() public {
        vm.expectRevert(
            BaseCToken.BaseCToken__InvalidMarketManager.selector
        );
        new BorrowableCToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(_USDC_ADDRESS),
            address(1),
            address(interestRateModel)
        );
    }

    function test_borrowableCTokenDeployment_fail_whenInterestRateModelIsInvalid()
        public
    {
        vm.expectRevert();
        new BorrowableCToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(_USDC_ADDRESS),
            address(marketManagerIsolated),
            address(0)
        );
    }

    function test_borrowableCTokenDeployment_fail_whenUnderlyingTotalSupplyExceedsMaximum()
        public
    {
        stdstore
            .target(_USDC_ADDRESS)
            .sig(IERC20.totalSupply.selector)
            .checked_write(type(uint232).max);
        vm.expectRevert(
           BaseCToken.BaseCToken__UnsupportedAsset.selector
        );
        new BorrowableCToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(_USDC_ADDRESS),
            address(marketManagerIsolated),
            address(interestRateModel)
        );
    }

    function test_borrowableCTokenDeployment_success() public {
        vm.expectEmit(true, true, true, true);
        uint256 newInterestFactor = centralRegistry.protocolInterestFee(
            address(marketManagerIsolated)
        );
        emit NewInterestFactor(0, newInterestFactor);

        borrowableCUSDC = new BorrowableCToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(_USDC_ADDRESS),
            address(marketManagerIsolated),
            address(interestRateModel)
        );

        assertEq(address(borrowableCUSDC.centralRegistry()), address(centralRegistry));
        assertEq(address(borrowableCUSDC.asset()), _USDC_ADDRESS);
        assertEq(
            address(borrowableCUSDC.interestRateModel()),
            address(interestRateModel)
        );
        assertEq(address(borrowableCUSDC.marketManager()), address(marketManagerIsolated));
    }
}
