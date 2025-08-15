// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { BPS } from "contracts/libraries/ConstantsLib.sol";

contract SetLockBoostMultiplierTest is TestBaseMarketIsolated {
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
            CentralRegistry.CentralRegistry__InvalidParameter.selector
        );
        centralRegistry.setLockBoostMultiplier(BPS);

        centralRegistry.setLockBoostMultiplier(0);
        centralRegistry.setLockBoostMultiplier(BPS + 1);
    }

    function test_setLockBoostMultiplier_success() public {
        centralRegistry.setLockBoostMultiplier(11000);
        assertEq(centralRegistry.lockBoostMultiplier(), 11000);
    }
}
