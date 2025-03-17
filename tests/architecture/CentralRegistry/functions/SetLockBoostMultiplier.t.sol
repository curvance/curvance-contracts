// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { DENOMINATOR } from "contracts/libraries/Constants.sol";

contract SetLockBoostMultiplierTest is TestBaseMarket {
    function test_setLockBoostMultiplier_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.setLockBoostMultiplier(100);
    }

    function test_setLockBoostMultiplier_fail_whenParametersMisconfigured()
        public
    {
        vm.expectRevert(
            CentralRegistry.CentralRegistry__ParametersMisconfigured.selector
        );
        centralRegistry.setLockBoostMultiplier(DENOMINATOR);

        centralRegistry.setLockBoostMultiplier(0);
        centralRegistry.setLockBoostMultiplier(DENOMINATOR + 1);
    }

    function test_setLockBoostMultiplier_success() public {
        centralRegistry.setLockBoostMultiplier(11000);
        assertEq(centralRegistry.lockBoostMultiplier(), 11000);
    }
}
