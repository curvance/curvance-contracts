// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract SetProtocolYieldFeeTest is TestBaseMarketIsolated {
    function test_setProtocolYieldFee_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.setProtocolYieldFee(100);
    }

    function test_setProtocolYieldFee_fail_whenParametersMisconfigured()
        public
    {
        vm.expectRevert(
            CentralRegistry.CentralRegistry__InvalidParameter.selector
        );
        centralRegistry.setProtocolYieldFee(5001);

        centralRegistry.setProtocolYieldFee(5000);
    }

    function test_setProtocolYieldFee_success() public {
        centralRegistry.setProtocolYieldFee(100);
        uint256 newProtocolYieldFee = 100;
        assertEq(centralRegistry.protocolYieldFee(), newProtocolYieldFee);
        uint256 newProtocolHarvestFee = centralRegistry.protocolCompoundFee() +
            newProtocolYieldFee;
        assertEq(centralRegistry.protocolHarvestFee(), newProtocolHarvestFee);
    }
}
