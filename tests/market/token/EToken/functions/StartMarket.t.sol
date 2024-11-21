// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseEToken } from "../TestBaseEToken.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { EToken } from "contracts/market/token/EToken.sol";

contract ETokenStartMarketTest is TestBaseEToken {
    function test_eTokenStartMarket_fail_whenCallerIsNotMarketManager()
        public
    {
        vm.expectRevert(EToken.EToken__Unauthorized.selector);
        eUSDC.startMarket(address(0));
    }

    function test_eTokenStartMarket_fail_whenInterestRateModelLinkedToWrongToken()
        public
    {
        eUSDC.setInterestRateModel(
            address(interestRateModels[block.chainid][_DAI_ADDRESS])
        );

        vm.prank(address(marketManager));

        vm.expectRevert(EToken.EToken__Unauthorized.selector);
        eUSDC.startMarket(user1);
    }

    function test_eTokenStartMarket_fail_whenInitializerIsZeroAddress()
        public
    {
        vm.prank(address(marketManager));

        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        eUSDC.startMarket(address(0));
    }

    function test_eTokenStartMarket_success() public {
        vm.prank(user1);
        SafeTransferLib.safeApprove(_USDC_ADDRESS, address(eUSDC), 1e18);

        uint256 totalSupply = eUSDC.totalSupply();

        vm.prank(address(marketManager));
        eUSDC.startMarket(user1);

        assertEq(eUSDC.totalSupply(), totalSupply + 42069);
    }
}
