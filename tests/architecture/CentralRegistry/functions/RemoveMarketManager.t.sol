// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { stdStorage, StdStorage } from "forge-std/Test.sol";

contract Market {
    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        if (interfaceId == 0xffffffff) {
            return false;
        }
        return true;
    }
}

contract RemoveMarketManagerTest is TestBaseMarketIsolated {
    using stdStorage for StdStorage;

    address public newMarket;

    event PermissionsUpdated(
        string indexed permissionsType,
        address addressUpdated,
        bool isAdded
    );

    function setUp() public virtual override {
        super.setUp();

        newMarket = address(new Market());
    }

    function test_removeMarketManager_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.removeMarketManager(user1);
    }

    function test_removeMarketManager_fail_whenParametersMisconfigured()
        public
    {
        vm.expectRevert(
            CentralRegistry.CentralRegistry__InvalidParameter.selector
        );
        centralRegistry.removeMarketManager(user1);

        stdstore
            .target(address(centralRegistry))
            .sig("isMarketManager(address)")
            .with_key(user1)
            .checked_write(true);

        vm.expectRevert(
            CentralRegistry.CentralRegistry__InvalidParameter.selector
        );
        centralRegistry.removeMarketManager(user1);
    }

    function test_removeMarketManager_success() public {
        address replacementMarket = address(new Market());
        uint256 startingLength = centralRegistry.marketManagers().length;

        centralRegistry.addMarketManager(newMarket);
        centralRegistry.addMarketManager(replacementMarket);

        address[] memory marketManagers = centralRegistry.marketManagers();
        assertEq(marketManagers.length, startingLength + 2);
        assertEq(marketManagers[startingLength], newMarket);
        assertEq(marketManagers[startingLength + 1], replacementMarket);

        vm.expectEmit(true, true, true, true);
        emit PermissionsUpdated("Market Manager", newMarket, false);

        centralRegistry.removeMarketManager(newMarket);
        assertFalse(centralRegistry.isMarketManager(newMarket));
        assertTrue(centralRegistry.isMarketManager(replacementMarket));

        marketManagers = centralRegistry.marketManagers();
        assertEq(marketManagers.length, startingLength + 1);
        assertEq(marketManagers[startingLength], replacementMarket);

        for (uint256 i; i < marketManagers.length; ++i) {
            assertFalse(marketManagers[i] == newMarket);
        }
    }
}
