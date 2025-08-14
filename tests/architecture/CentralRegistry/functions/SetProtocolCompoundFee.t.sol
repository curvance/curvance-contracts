// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract SetProtocolCompoundFeeTest is TestBaseMarketIsolated {
    function test_setProtocolCompoundFee_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.setProtocolCompoundFee(100);
    }

    function test_setProtocolCompoundFee_fail_whenParametersMisconfigured()
        public
    {
        vm.expectRevert(
            CentralRegistry.CentralRegistry__InvalidParameter.selector
        );
        centralRegistry.setProtocolCompoundFee(501);

        centralRegistry.setProtocolCompoundFee(500);
    }

    function test_setProtocolCompoundFee_success() public {
        centralRegistry.setProtocolCompoundFee(100);
        assertEq(centralRegistry.protocolCompoundFee(), 100);
        uint256 newProtocolHarvestFee =
            centralRegistry.protocolYieldFee() + 100;
        assertEq(centralRegistry.protocolHarvestFee(), newProtocolHarvestFee);
    }
}
