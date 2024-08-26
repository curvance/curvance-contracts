// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
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

contract RemoveMarketManagerTest is TestBaseMarket {
    using stdStorage for StdStorage;

    address public newMarket;

    event RemovedCurvanceContract(
        string indexed contractType,
        address removedAddress
    );

    function setUp() public virtual override {
        super.setUp();

        newMarket = address(new Market());
    }

    function test_removeMarketManager_fail_whenUnauthorized() public {
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
            CentralRegistry.CentralRegistry__ParametersMisconfigured.selector
        );
        centralRegistry.removeMarketManager(user1);

        stdstore
            .target(address(centralRegistry))
            .sig("isMarketManager(address)")
            .with_key(user1)
            .checked_write(true);

        vm.expectRevert(
            CentralRegistry.CentralRegistry__ParametersMisconfigured.selector
        );
        centralRegistry.removeMarketManager(user1);
    }

    function test_removeMarketManager_success() public {
        centralRegistry.addMarketManager(newMarket, 5000);

        vm.expectEmit(true, true, true, true);
        emit RemovedCurvanceContract("Market Manager", newMarket);

        centralRegistry.removeMarketManager(newMarket);
        assertFalse(centralRegistry.isMarketManager(newMarket));
    }
}
