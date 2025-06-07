// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract Market {
    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        if (interfaceId == 0xffffffff) {
            return false;
        }
        return true;
    }
}

contract AddMarketManagerTest is TestBaseMarketIsolated {
    address public newMarket;

    event PermissionsUpdated(string indexed contractType, address newAddress);

    function setUp() public virtual override {
        super.setUp();
        newMarket = address(new Market());
    }

    function test_addMarketManager_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.addMarketManager(newMarket, 5000);
    }

    function test_addMarketManager_fail_whenMarketAlreadyAdded() public {
        centralRegistry.addMarketManager(newMarket, 5000);
        vm.expectRevert(
            CentralRegistry.CentralRegistry__ParametersMisconfigured.selector
        );
        centralRegistry.addMarketManager(newMarket, 5000);
    }

    function test_addMarketManager_fail_whenNoSupportForERC165() public {
        vm.expectRevert(
            CentralRegistry.CentralRegistry__ParametersMisconfigured.selector
        );
        centralRegistry.addMarketManager(user1, 5000);
    }

    function test_addMarketManager_fail_whenFeeTooHigh() public {
        vm.expectRevert(
            CentralRegistry.CentralRegistry__ParametersMisconfigured.selector
        );
        centralRegistry.addMarketManager(newMarket, 5001);
    }

    function test_addMarketManager_success() public {
        address[] memory marketManagers = centralRegistry.getMarketManagers();

        assertFalse(centralRegistry.isMarketManager(newMarket));

        vm.expectEmit(true, true, true, true);
        emit PermissionsUpdated("Market Manager", newMarket, true);

        centralRegistry.addMarketManager(newMarket, 5000);

        assertTrue(centralRegistry.isMarketManager(newMarket));
        assertEq(
            centralRegistry.getMarketManagers().length,
            marketManagers.length + 1
        );
        assertEq(
            centralRegistry.getMarketManagers()[marketManagers.length],
            newMarket
        );
        assertEq(
            centralRegistry.protocolInterestFee(newMarket),
            5000 * 1e14
        );
    }
}
