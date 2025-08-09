// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

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
        centralRegistry.addMarketManager(newMarket, 5000);
    }

    function test_addMarketManager_fail_whenMarketAlreadyAdded() public {
        centralRegistry.addMarketManager(newMarket, 5000);
        vm.expectRevert(
            CentralRegistry.CentralRegistry__InvalidParameter.selector
        );
        centralRegistry.addMarketManager(newMarket, 5000);
    }

    function test_addMarketManager_fail_whenNoSupportForERC165() public {
        vm.expectRevert(
            CentralRegistry.CentralRegistry__InvalidParameter.selector
        );
        centralRegistry.addMarketManager(user1, 5000);
    }

    function test_addMarketManager_fail_whenFeeTooHigh() public {
        vm.expectRevert(
            CentralRegistry.CentralRegistry__InvalidParameter.selector
        );
        centralRegistry.addMarketManager(newMarket, 5001);
    }

    function test_addMarketManager_success() public {
        address[] memory marketManagers = centralRegistry.marketManagers();

        assertFalse(centralRegistry.isMarketManager(newMarket));

        vm.expectEmit(true, true, true, true);
        emit PermissionsUpdated("Market Manager", newMarket, true);

        centralRegistry.addMarketManager(newMarket, 5000);

        assertTrue(centralRegistry.isMarketManager(newMarket));
        assertEq(
            centralRegistry.marketManagers().length,
            marketManagers.length + 1
        );
        assertEq(
            centralRegistry.marketManagers()[marketManagers.length],
            newMarket
        );
        assertEq(
            centralRegistry.protocolInterestFee(newMarket),
            5000 * 1e14
        );
    }

    function testMarketManagerIntegration() public {
        // Setup an actual MarketManager.
        MarketManagerIsolated marketManager = new MarketManagerIsolated(ICentralRegistry(address(centralRegistry)));
        
        // Add market manager with actual implementation
        vm.prank(centralRegistry.emergencyCouncil());
        centralRegistry.addMarketManager(address(marketManager), 1000); // 10% interest fee
        
        // Verify market is registered correctly
        assertTrue(centralRegistry.isMarketManager(address(marketManager)));
        assertEq(centralRegistry.protocolInterestFee(address(marketManager)), 1000 * 1e14);
        
        // Verify market manager's central registry reference
        assertEq(address(marketManager.centralRegistry()), address(centralRegistry));
    }
    
}
