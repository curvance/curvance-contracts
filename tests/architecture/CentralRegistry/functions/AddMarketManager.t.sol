// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

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

    event PermissionsUpdated(
        string indexed permissionsType,
        address addressUpdated,
        bool isAdded
    );

    function setUp() public virtual override {
        super.setUp();
        newMarket = address(new Market());
    }

    function test_addMarketManager_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.addMarketManager(newMarket);
    }

    function test_addMarketManager_fail_whenMarketAlreadyAdded() public {
        centralRegistry.addMarketManager(newMarket);
        vm.expectRevert(
            CentralRegistry.CentralRegistry__InvalidParameter.selector
        );
        centralRegistry.addMarketManager(newMarket);
    }

    function test_addMarketManager_fail_whenNoSupportForERC165() public {
        vm.expectRevert(
            CentralRegistry.CentralRegistry__InvalidParameter.selector
        );
        centralRegistry.addMarketManager(user1);
    }

    function test_addMarketManager_success() public {
        address[] memory marketManagers = centralRegistry.marketManagers();

        assertFalse(centralRegistry.isMarketManager(newMarket));

        vm.expectEmit(true, true, true, true);
        emit PermissionsUpdated("Market Manager", newMarket, true);

        centralRegistry.addMarketManager(newMarket);

        assertTrue(centralRegistry.isMarketManager(newMarket));
        assertEq(
            centralRegistry.marketManagers().length,
            marketManagers.length + 1
        );
        assertEq(
            centralRegistry.marketManagers()[marketManagers.length],
            newMarket
        );
        assertEq(centralRegistry.defaultProtocolInterestFee(), 2000);
    }

    function testMarketManagerIntegration() public {
        // Setup an actual MarketManager.
        MarketManagerIsolated marketManager = 
        new MarketManagerIsolated(ICentralRegistry(address(centralRegistry)), 10e18, false);
        
        // Add market manager with actual implementation, 20% default interest rate.
        vm.prank(centralRegistry.emergencyCouncil());
        centralRegistry.addMarketManager(address(marketManager));
        
        // Verify market is registered correctly.
        assertTrue(centralRegistry.isMarketManager(address(marketManager)));
        assertEq(centralRegistry.defaultProtocolInterestFee(), 2000); // 20% interest fee
        
        // Verify market manager's central registry reference.
        assertEq(address(marketManager.centralRegistry()), address(centralRegistry));
    }
    
}
