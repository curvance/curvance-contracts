// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseEToken } from "../TestBaseEToken.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";

contract ETokenStartMarketTest is TestBaseEToken {
    function test_eTokenStartMarket_fail_whenCallerIsNotMarketManager()
        public
    {
        vm.expectRevert(BaseCToken.BaseCToken__Unauthorized.selector);
        eUSDC.startMarket(address(0));
    }

    function test_eTokenStartMarket_fail_whenInterestRateModelLinkedToWrongToken()
        public
    {
        eUSDC.setInterestRateModel(
            address(interestRateModels[block.chainid][_DAI_ADDRESS])
        );

        vm.prank(address(marketManagerIsolated));

        vm.expectRevert(BaseCToken.BaseCToken__Unauthorized.selector);
        eUSDC.startMarket(user1);
    }

    function test_eTokenStartMarket_fail_whenInitializerIsZeroAddress()
        public
    {
        vm.prank(address(marketManagerIsolated));

        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        eUSDC.startMarket(address(0));
    }

    function test_eTokenStartMarket_success() public {
        _prepareUSDC(address(user1), 1000e6);

        vm.startPrank(user1);
        SafeTransferLib.safeApprove(_USDC_ADDRESS, address(eUSDC), 1e18);
        vm.stopPrank();

        uint256 totalSupply = eUSDC.totalSupply();

        vm.prank(address(marketManagerIsolated));
        eUSDC.startMarket(user1);

        assertEq(eUSDC.totalSupply(), totalSupply + 77777);
    }
}
