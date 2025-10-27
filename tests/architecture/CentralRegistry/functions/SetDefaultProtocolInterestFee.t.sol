// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract SetDefaultProtocolInterestFeeTest is TestBaseMarketIsolated {
    function setUp() public virtual override {
        super.setUp();
    }

    function test_setDefaultProtocolInterestFee_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.setDefaultProtocolInterestFee(100);
    }

    function test_setDefaultProtocolInterestFee_fail_whenValueTooHigh() public {
        vm.expectRevert(
            CentralRegistry.CentralRegistry__InvalidParameter.selector
        );
        centralRegistry.setDefaultProtocolInterestFee(6001);
    }

    function test_setDefaultProtocolInterestFee_success() public {
        centralRegistry.setDefaultProtocolInterestFee(5000);
        assertEq(centralRegistry.defaultProtocolInterestFee(), 5000);
    }
}
