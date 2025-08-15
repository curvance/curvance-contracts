// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract TransferDaoPermissionsTest is TestBaseMarketIsolated {
    address public newDaoAddress = address(1000);

    event PermissionsTransferred(
        string indexed permissionsType,
        address previousOwner,
        address newOwner
    );

    function test_transferDaoPermissions_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.transferDaoPermissions(newDaoAddress);
    }

    function test_transferDaoPermissions_success() public {
        assertTrue(centralRegistry.hasDaoPermissions(address(this)));

        vm.expectEmit(true, true, true, true);
        emit PermissionsTransferred(
            "DAO Permissions",
            address(this),
            newDaoAddress
        );

        centralRegistry.transferDaoPermissions(newDaoAddress);

        assertEq(centralRegistry.daoAddress(), newDaoAddress);
        assertTrue(centralRegistry.hasDaoPermissions(newDaoAddress));
        assertTrue(centralRegistry.hasDaoPermissions(address(this)));
    }
}
