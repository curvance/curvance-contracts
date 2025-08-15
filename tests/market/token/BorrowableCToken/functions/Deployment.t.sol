// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { DynamicIRM } from "contracts/market/DynamicIRM.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";

import { CentralRegistryLib } from "contracts/libraries/CentralRegistryLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

import { TestBaseBorrowableCToken } from "../TestBaseBorrowableCToken.sol";
import "forge-std/StdStorage.sol";

contract BorrowableCTokenDeploymentTest is TestBaseBorrowableCToken {
    using stdStorage for StdStorage;

    event NewInterestFee(uint256 oldInterestFee, uint256 newInterestFee);

    DynamicIRM public IRM;

    function setUp() public virtual override {
        super.setUp();
        IRM = IRMs[block.chainid][_USDC_ADDRESS];
    }

    function test_borrowableCTokenDeployment_fail_whenCentralRegistryIsInvalid() public {
        vm.expectRevert(
            CentralRegistryLib.CentralRegistryLib__InvalidCentralRegistry
                .selector
        );
        new BorrowableCToken(
            ICentralRegistry(address(0)),
            IERC20(_USDC_ADDRESS),
            address(marketManagerIsolated),
            address(IRM)
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
            address(IRM)
        );
    }

    function test_borrowableCTokenDeployment_fail_whenIRMIsInvalid()
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
            address(IRM)
        );
    }

    function test_borrowableCTokenDeployment_success() public {
        vm.expectEmit(true, true, true, true);
        uint256 newInterestFee = centralRegistry.protocolInterestFee(
            address(marketManagerIsolated)
        );
        emit NewInterestFee(0, newInterestFee);

        borrowableCUSDC = new BorrowableCToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(_USDC_ADDRESS),
            address(marketManagerIsolated),
            address(IRM)
        );

        assertEq(address(borrowableCUSDC.centralRegistry()), address(centralRegistry));
        assertEq(address(borrowableCUSDC.asset()), _USDC_ADDRESS);
        assertEq(
            address(borrowableCUSDC.IRM()),
            address(IRM)
        );
        assertEq(address(borrowableCUSDC.marketManager()), address(marketManagerIsolated));
    }
}
